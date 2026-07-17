-- finalization.sql (T025)
-- begin/complete/abort_campaign_finalization with the campaign_state_revision
-- fence + deadline-policy resolution. The Sweeper is the only caller.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.begin_campaign_finalization(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  c campaigns; v_token uuid;
  v_nonterminal int; v_stale int; v_open_critics int; v_undelivered int; v_recon int;
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF c.status NOT IN ('analyzing','awaiting_approval') THEN
    RETURN jsonb_build_object('status','not_finalizable','campaign_status', c.status);
  END IF;

  -- deadline resolutions BEFORE the readiness checks
  IF c.requires_approval AND c.approval_status = 'pending'
     AND c.approval_deadline_at IS NOT NULL AND c.approval_deadline_at <= now() THEN
    UPDATE campaigns SET approval_status = 'expired' WHERE id = c.id;
    UPDATE work_items SET state = 'skipped_gate'
     WHERE campaign_id = c.id AND service = 'enrichment'
       AND state IN ('waiting_approval','blocked','pending');
  END IF;
  IF c.critic_deadline_at <= now() THEN
    UPDATE critic_reviews cr SET state = 'resolved',
      resolution = 'deadline: shipped contested', resolved_at = now()
     FROM campaign_leads cl
    WHERE cr.campaign_lead_id = cl.id AND cl.campaign_id = c.id
      AND cr.state IN ('open','reverifying');
    UPDATE campaign_leads SET critic_state = 'resolved', contested = true
     WHERE campaign_id = c.id AND critic_state IN ('pending','reverifying');
  END IF;

  -- readiness checks
  SELECT count(*) INTO v_nonterminal FROM work_items
   WHERE campaign_id = c.id AND state NOT IN
     ('done','dead','skipped_gate','skipped_budget','skipped_prerequisite','canceled');
  SELECT count(*) INTO v_stale FROM campaign_leads cl
   WHERE cl.campaign_id = c.id
     AND cl.lead_revision > 0
     AND NOT EXISTS (SELECT 1 FROM lead_assessments a
           WHERE a.campaign_lead_id = cl.id AND a.is_current = true
             AND a.evidence_watermark >= cl.lead_revision);
  SELECT count(*) INTO v_open_critics FROM critic_reviews cr
    JOIN campaign_leads cl ON cl.id = cr.campaign_lead_id
   WHERE cl.campaign_id = c.id AND cr.state IN ('open','reverifying');
  SELECT count(*) INTO v_undelivered FROM outbox_deliveries d
    JOIN outbox_events e ON e.id = d.event_id
   WHERE e.blocks_finalization
     AND d.state IN ('pending','running')
     AND (e.aggregate_id = c.id OR e.aggregate_id IN
          (SELECT id FROM campaign_leads WHERE campaign_id = c.id));
  SELECT count(*) INTO v_recon FROM budget_transactions
   WHERE campaign_id = c.id
     AND ((state = 'reserved' AND expires_at > now())
          OR (reconciliation_status = 'reconciliation_required'
              AND c.reconciliation_deadline_at > now()));

  IF v_nonterminal > 0 OR v_stale > 0 OR v_open_critics > 0
     OR v_undelivered > 0 OR v_recon > 0 THEN
    RETURN jsonb_build_object('status','not_ready',
      'nonterminal_work', v_nonterminal, 'stale_assessments', v_stale,
      'open_critics', v_open_critics, 'blocking_deliveries', v_undelivered,
      'open_money', v_recon);
  END IF;

  v_token := gen_random_uuid();
  UPDATE campaigns SET status = 'finalizing', finalization_token = v_token
   WHERE id = c.id;
  PERFORM _emit_event('campaign.finalizing','state_change', false, c.id,
    c.campaign_state_revision, '{}'::jsonb,
    'campaign.finalizing:' || c.id || ':' || c.campaign_state_revision);
  RETURN jsonb_build_object('status','ready','finalization_token', v_token,
    'state_revision', c.campaign_state_revision);
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.complete_campaign_finalization(
  p_campaign_id uuid, p_token uuid, p_state_revision bigint, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE c campaigns; v_dead int; v_leads int; v_conf numeric; v_quality text;
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF c.status <> 'finalizing' OR c.finalization_token IS DISTINCT FROM p_token
     OR c.campaign_state_revision IS DISTINCT FROM p_state_revision THEN
    -- fence failed: a score-affecting mutation happened during finalization
    UPDATE campaigns SET status = 'analyzing', finalization_token = NULL
     WHERE id = p_campaign_id AND status = 'finalizing';
    RETURN jsonb_build_object('status','aborted_state_drift');
  END IF;

  SELECT count(*) FILTER (WHERE state = 'dead'), count(*) INTO v_dead, v_leads
    FROM work_items WHERE campaign_id = c.id AND scope_type = 'lead';
  SELECT avg(a.evidence_confidence) INTO v_conf
    FROM lead_assessments a JOIN campaign_leads cl ON cl.id = a.campaign_lead_id
   WHERE cl.campaign_id = c.id AND a.is_current;

  v_quality := CASE
    WHEN v_leads = 0 THEN 'healthy'
    WHEN v_dead::numeric / GREATEST(v_leads,1) > 0.35 OR coalesce(v_conf,0) < 25 THEN 'unusable'
    WHEN v_dead::numeric / GREATEST(v_leads,1) > 0.20 OR coalesce(v_conf,100) < 40 THEN 'degraded'
    WHEN v_dead > 0 THEN 'partial'
    ELSE 'healthy' END;

  UPDATE campaigns SET
    status = 'complete', completed_at = now(),
    completion_reason = coalesce(p_payload->>'completion_reason','finished'),
    quality_state = v_quality,
    digest_url = p_payload->>'digest_url',
    sheet_snapshot_url = p_payload->>'sheet_snapshot_url',
    finalization_token = NULL
  WHERE id = c.id;

  PERFORM _emit_event('campaign.completed','state_change', false, c.id,
    c.campaign_state_revision,
    jsonb_build_object('quality_state', v_quality,
                       'completion_reason', coalesce(p_payload->>'completion_reason','finished')),
    'campaign.completed:' || c.id);
  RETURN jsonb_build_object('status','complete','quality_state', v_quality);
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.abort_campaign_finalization(
  p_campaign_id uuid, p_token uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
BEGIN
  UPDATE campaigns SET status = 'analyzing', finalization_token = NULL
   WHERE id = p_campaign_id AND status = 'finalizing'
     AND finalization_token = p_token;
  IF NOT FOUND THEN RETURN jsonb_build_object('status','no_op'); END IF;
  RETURN jsonb_build_object('status','aborted','reason', p_reason);
END $$;
