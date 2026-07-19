-- complete_work_items.sql (T018)
-- Per-service completion family + fail/defer. Every function: universal fence
-- (state+token+lease), ONE transaction for all result writes, version-coalescing
-- rerun rule. A zero-row fence raises and the entire write rolls back — a stale
-- worker leaves no trace.

-- ---------------------------------------------------------------------------
-- Internal: finish the work item under the version rule + finalize the run.
-- Returns 'done' or 'pending' (rerun coalesced).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@._finish_work_item(
  p_w @@SCHEMA@@.work_items, p_run_status text, p_run jsonb)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_state text; v_cur bigint;
BEGIN
  SELECT requested_version INTO v_cur FROM work_items WHERE id = p_w.id;
  v_state := CASE WHEN v_cur > p_w.processing_version THEN 'pending' ELSE 'done' END;

  UPDATE work_items SET
    state = v_state,
    completed_version = CASE WHEN v_state = 'done' THEN processing_version ELSE completed_version END,
    completed_at      = CASE WHEN v_state = 'done' THEN now() ELSE NULL END,
    available_at      = CASE WHEN v_state = 'pending' THEN now() ELSE available_at END,
    claim_token = NULL, worker_id = NULL, lease_expires_at = NULL,
    error_code = NULL, error_detail = NULL
  WHERE id = p_w.id;

  UPDATE service_runs SET
    status = p_run_status, completed_at = now(),
    workflow_version = coalesce(p_run->>'workflow_version', workflow_version),
    prompt_version   = coalesce(p_run->>'prompt_version', prompt_version),
    model_provider   = coalesce(p_run->>'model_provider', model_provider),
    model_name       = coalesce(p_run->>'model_name', model_name),
    tool_call_count  = coalesce((p_run->>'tool_call_count')::int, tool_call_count),
    input_hash       = coalesce(p_run->>'input_hash', input_hash),
    output_hash      = coalesce(p_run->>'output_hash', output_hash),
    actual_cost      = coalesce((p_run->>'actual_cost')::numeric, actual_cost)
  WHERE work_item_id = p_w.id AND work_attempt = p_w.execution_attempt_count;

  RETURN v_state;
END $$;

-- ---------------------------------------------------------------------------
-- complete_analysis_work_item: website | reviews | phone (and assets in v2).
-- Payload: { run:{...}, evidence:[ evidence-item-shape... ], cause_type:text }
-- Unblocks phone when website+reviews are terminal (dependency resolution).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@.complete_analysis_work_item(
  p_work_item_id uuid, p_claim_token uuid, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  w work_items; lead campaign_leads; run_id uuid;
  item jsonb; ins record; v_new_evidence int := 0; v_rev bigint; v_state text;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  IF w.service NOT IN ('website','reviews','phone','social') THEN
    RAISE EXCEPTION 'invalid_transition' USING ERRCODE = 'P0001',
      DETAIL = 'complete_analysis called for service ' || w.service;
  END IF;
  IF jsonb_typeof(coalesce(p_payload->'evidence','[]'::jsonb)) <> 'array'
     OR pg_column_size(p_payload) > 2*1024*1024 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO lead FROM campaign_leads WHERE id = w.campaign_lead_id;
  SELECT id INTO run_id FROM service_runs
   WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;

  FOR item IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'evidence','[]')) LOOP
    SELECT * INTO ins FROM _insert_evidence(lead.business_id, w.campaign_id, w.service, run_id, item);
    IF ins.inserted THEN v_new_evidence := v_new_evidence + 1; END IF;
  END LOOP;

  IF v_new_evidence > 0 THEN
    v_rev := advance_lead_revision(w.campaign_lead_id,
               coalesce(p_payload->>'cause_type', w.service || '_evidence'));
    PERFORM _emit_event('evidence.added','dependency', true, w.campaign_lead_id, v_rev,
      jsonb_build_object('service', w.service, 'new_items', v_new_evidence),
      'evidence.added:' || w.id || ':' || w.execution_attempt_count);
  END IF;

  v_state := _finish_work_item(w, 'succeeded', p_payload->'run');

  -- Dependency resolution: phone unblocks when website + reviews are terminal
  IF w.service IN ('website','reviews') THEN
    UPDATE work_items p SET state = 'pending', available_at = now()
     WHERE p.campaign_lead_id = w.campaign_lead_id AND p.service = 'phone'
       AND p.state = 'blocked'
       AND NOT EXISTS (SELECT 1 FROM work_items s
             WHERE s.campaign_lead_id = w.campaign_lead_id
               AND s.service IN ('website','reviews')
               AND s.state NOT IN ('done','dead','skipped_gate','skipped_budget',
                                   'skipped_prerequisite','canceled'));
  END IF;

  RETURN jsonb_build_object('result', v_state, 'new_evidence', v_new_evidence);
END $$;

-- ---------------------------------------------------------------------------
-- complete_scorer_work_item: assessment + components + publication rule +
-- classification/hot flow + enrichment gate resolution + score_log + events.
-- Payload: { run:{}, assessment:{fits..., opportunity, contactability,
--   confidence, completeness, best_angle, scoring_version},
--   components:[{product, feature_key, observed_value, transformed_value,
--                weight, points, evidence_id?}...],
--   classification:{value, reason}, hot_candidate:bool,
--   open_critic:bool, critic_type:text,
--   enrichment_gate_passed:bool, analysis_terminal:bool }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@.complete_scorer_work_item(
  p_work_item_id uuid, p_claim_token uuid, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  w work_items; lead campaign_leads; c campaigns;
  a jsonb; v_assess_id uuid; v_prev uuid; v_is_current boolean;
  v_class text; v_state text; comp jsonb; v_run_id uuid;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  IF w.service <> 'assessment' THEN
    RAISE EXCEPTION 'invalid_transition' USING ERRCODE = 'P0001';
  END IF;
  a := p_payload->'assessment';
  IF a IS NULL THEN RAISE EXCEPTION 'invalid_payload' USING ERRCODE = 'P0001'; END IF;

  SELECT * INTO lead FROM campaign_leads WHERE id = w.campaign_lead_id FOR UPDATE;
  SELECT * INTO c FROM campaigns WHERE id = w.campaign_id;
  SELECT id INTO v_run_id FROM service_runs
   WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;

  -- Publication rule: pointer moves ONLY when we scored the current revision
  v_is_current := (w.processing_version = lead.lead_revision);

  IF v_is_current THEN
    UPDATE lead_assessments SET is_current = false, superseded_at = now()
     WHERE campaign_lead_id = lead.id AND is_current = true
     RETURNING id INTO v_prev;
  END IF;

  INSERT INTO lead_assessments
    (campaign_lead_id, scoring_version, fit_web_seo, fit_voice_ai, fit_ads_video,
     fit_consulting, opportunity_score, contactability_score, evidence_confidence,
     completeness, best_angle, evidence_watermark, is_current)
  VALUES (lead.id, a->>'scoring_version',
     (a->>'fit_web_seo')::numeric,  (a->>'fit_voice_ai')::numeric,
     (a->>'fit_ads_video')::numeric,(a->>'fit_consulting')::numeric,
     (a->>'opportunity')::numeric,  (a->>'contactability')::numeric,
     (a->>'confidence')::numeric,   (a->>'completeness')::numeric,
     a->>'best_angle', w.processing_version, v_is_current)
  RETURNING id INTO v_assess_id;

  FOR comp IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'components','[]')) LOOP
    INSERT INTO score_components
      (assessment_id, product, feature_key, observed_value, transformed_value,
       weight, points, evidence_id)
    VALUES (v_assess_id, comp->>'product', comp->>'feature_key',
       comp->'observed_value', (comp->>'transformed_value')::numeric,
       (comp->>'weight')::numeric, (comp->>'points')::numeric,
       (comp->>'evidence_id')::uuid);
  END LOOP;

  IF v_is_current THEN
    v_class := p_payload->'classification'->>'value';
    -- Hot is enforced, not trusted: requires resolved critic + full AND-gate
    IF v_class = 'hot' AND (lead.critic_state IS DISTINCT FROM 'resolved'
        OR (a->>'contactability')::numeric < 60
        OR (a->>'opportunity')::numeric   < 75
        OR (a->>'confidence')::numeric    < 60) THEN
      RAISE EXCEPTION 'invalid_transition' USING ERRCODE = 'P0001',
        DETAIL = 'hot requires resolved critic + AND-gate';
    END IF;

    UPDATE campaign_leads SET
      latest_assessment_id = v_assess_id,
      classification = v_class,
      classification_reason = p_payload->'classification'->>'reason',
      classified_at = now(),
      hot_candidate = coalesce((p_payload->>'hot_candidate')::boolean, hot_candidate),
      critic_state = CASE
        WHEN coalesce((p_payload->>'open_critic')::boolean, false)
             AND critic_state IS NULL THEN 'pending'
        ELSE critic_state END
    WHERE id = lead.id;

    IF coalesce((p_payload->>'open_critic')::boolean, false) AND lead.critic_state IS NULL THEN
      INSERT INTO critic_reviews (campaign_lead_id, assessment_id, critic_type, input_version)
      VALUES (lead.id, v_assess_id, coalesce(p_payload->>'critic_type','hot_lead'), lead.lead_revision);
    END IF;

    UPDATE businesses SET latest_assessment_id = v_assess_id,
      latest_summary = jsonb_build_object(
        'fits', jsonb_build_object(
          'web_seo', a->>'fit_web_seo', 'voice_ai', a->>'fit_voice_ai',
          'ads_video', a->>'fit_ads_video', 'consulting', a->>'fit_consulting'),
        'opportunity', a->>'opportunity', 'classification', v_class,
        'best_angle', a->>'best_angle', 'scored_at', now()),
      last_updated = now()
    WHERE id = lead.business_id;

    INSERT INTO score_log (campaign_lead_id, previous_assessment_id,
                           current_assessment_id, change_reason)
    VALUES (lead.id, v_prev, v_assess_id,
            coalesce(p_payload->>'change_reason','recompute'));

    PERFORM _emit_event('assessment.published','state_change', true, lead.id,
      w.processing_version,
      jsonb_build_object('assessment_id', v_assess_id, 'classification', v_class,
                         'opportunity', a->>'opportunity'),
      'assessment.published:' || v_assess_id);

    IF v_class = 'hot' AND coalesce(lead.classification,'') <> 'hot' THEN
      PERFORM _emit_event('lead.hot','notification', false, lead.id,
        w.processing_version,
        jsonb_build_object('assessment_id', v_assess_id, 'best_angle', a->>'best_angle'),
        'lead.hot:' || lead.id);
    END IF;

    -- Enrichment gate resolution (blocked -> pending | waiting_approval | skipped_gate)
    IF coalesce((p_payload->>'enrichment_gate_passed')::boolean, false) THEN
      UPDATE work_items SET
        state = CASE WHEN c.requires_approval AND c.approval_status <> 'approved'
                     THEN 'waiting_approval' ELSE 'pending' END,
        available_at = now()
      WHERE campaign_lead_id = lead.id AND service = 'enrichment' AND state IN ('blocked','waiting_approval');
    ELSIF coalesce((p_payload->>'analysis_terminal')::boolean, false) THEN
      UPDATE work_items SET state = 'skipped_gate'
      WHERE campaign_lead_id = lead.id AND service = 'enrichment' AND state IN ('blocked','waiting_approval');
    END IF;

    -- Social-activity gate: a warm/hot lead is worth the paid social scrape, so open
    -- the 'social' work item (blocked -> pending). Non-warm terminal analysis skips it.
    -- No approval branch: social is public-data enrichment, not contact spending.
    IF v_class IN ('warm','hot') THEN
      UPDATE work_items SET state = 'pending', available_at = now()
      WHERE campaign_lead_id = lead.id AND service = 'social' AND state = 'blocked';
    ELSIF coalesce((p_payload->>'analysis_terminal')::boolean, false) THEN
      UPDATE work_items SET state = 'skipped_gate'
      WHERE campaign_lead_id = lead.id AND service = 'social' AND state = 'blocked';
    END IF;
  END IF;

  v_state := _finish_work_item(w, 'succeeded', p_payload->'run');
  RETURN jsonb_build_object('result', v_state, 'assessment_id', v_assess_id,
                            'published', v_is_current);
END $$;

-- ---------------------------------------------------------------------------
-- complete_enrichment_work_item: contacts + verifications + findings, with
-- 5-level suppression enforcement BEFORE storing outreach-usable channels.
-- Payload: { run:{}, contacts:[{full_name, linkedin_url, role:{business_id?,
--   title, role_type, relevant_products, confidence, source_evidence_id},
--   channels:[{channel, value, value_normalized,
--              verification:{method,status,expires_at,idempotency_key}}],
--   role_verification:{method,status,source_url,expires_at,idempotency_key},
--   identity_verification:{...}}], not_found:bool }
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@.complete_enrichment_work_item(
  p_work_item_id uuid, p_claim_token uuid, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  w work_items; lead campaign_leads; v_run_id uuid;
  ct jsonb; ch jsonb; v_contact uuid; v_link uuid; v_channel uuid;
  v_stored int := 0; v_suppressed int := 0; v_state text; v_rev bigint;
  v_domain text;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  IF w.service <> 'enrichment' THEN
    RAISE EXCEPTION 'invalid_transition' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO lead FROM campaign_leads WHERE id = w.campaign_lead_id;
  SELECT website_domain INTO v_domain FROM businesses WHERE id = lead.business_id;
  SELECT id INTO v_run_id FROM service_runs
   WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;

  -- business/domain-level suppression: nothing outreach-usable may be stored
  IF EXISTS (SELECT 1 FROM suppressions s WHERE
       (s.level = 'business' AND s.value = lead.business_id::text) OR
       (s.level = 'domain'   AND s.value = v_domain)) THEN
    v_suppressed := -1;  -- whole business suppressed
  ELSE
    FOR ct IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'contacts','[]')) LOOP
      INSERT INTO contacts (full_name, linkedin_url)
      VALUES (ct->>'full_name', ct->>'linkedin_url')
      RETURNING id INTO v_contact;

      IF EXISTS (SELECT 1 FROM suppressions s
                  WHERE s.level = 'contact' AND lower(s.value) = lower(ct->>'full_name')) THEN
        v_suppressed := v_suppressed + 1; CONTINUE;
      END IF;

      INSERT INTO contact_business_links
        (contact_id, business_id, title, role_type, relevant_products,
         confidence, source_evidence_id)
      VALUES (v_contact, lead.business_id, ct->'role'->>'title',
        coalesce(ct->'role'->>'role_type','other'),
        coalesce((SELECT array_agg(x) FROM jsonb_array_elements_text(
          coalesce(ct->'role'->'relevant_products','[]')) x), '{}'),
        (ct->'role'->>'confidence')::numeric,
        (ct->'role'->>'source_evidence_id')::uuid)
      ON CONFLICT (contact_id, business_id, role_type) DO UPDATE SET active = true
      RETURNING id INTO v_link;

      IF ct ? 'role_verification' THEN
        INSERT INTO contact_role_verifications
          (contact_business_link_id, method, status, source_url, expires_at, idempotency_key)
        VALUES (v_link, ct->'role_verification'->>'method',
          ct->'role_verification'->>'status', ct->'role_verification'->>'source_url',
          (ct->'role_verification'->>'expires_at')::timestamptz,
          ct->'role_verification'->>'idempotency_key')
        ON CONFLICT (idempotency_key) DO NOTHING;
      END IF;
      IF ct ? 'identity_verification' THEN
        INSERT INTO contact_identity_verifications
          (contact_id, method, status, expires_at, idempotency_key)
        VALUES (v_contact, ct->'identity_verification'->>'method',
          ct->'identity_verification'->>'status',
          (ct->'identity_verification'->>'expires_at')::timestamptz,
          ct->'identity_verification'->>'idempotency_key')
        ON CONFLICT (idempotency_key) DO NOTHING;
      END IF;

      FOR ch IN SELECT * FROM jsonb_array_elements(coalesce(ct->'channels','[]')) LOOP
        -- email/phone-level suppression checked BEFORE storage (SC-006)
        IF EXISTS (SELECT 1 FROM suppressions s
                    WHERE s.level = ch->>'channel'
                      AND s.value = ch->>'value_normalized') THEN
          v_suppressed := v_suppressed + 1; CONTINUE;
        END IF;
        INSERT INTO contact_channels (contact_id, channel, value, value_normalized)
        VALUES (v_contact, ch->>'channel', ch->>'value', ch->>'value_normalized')
        ON CONFLICT (contact_id, channel, value_normalized) DO UPDATE SET value = EXCLUDED.value
        RETURNING id INTO v_channel;
        IF ch ? 'verification' THEN
          INSERT INTO contact_channel_verifications
            (contact_channel_id, method, status, expires_at, idempotency_key)
          VALUES (v_channel, ch->'verification'->>'method', ch->'verification'->>'status',
            (ch->'verification'->>'expires_at')::timestamptz,
            ch->'verification'->>'idempotency_key')
          ON CONFLICT (idempotency_key) DO NOTHING;
        END IF;
        INSERT INTO campaign_contact_findings
          (campaign_lead_id, contact_business_link_id, contact_channel_id, service_run_id)
        VALUES (lead.id, v_link, v_channel, v_run_id);
        v_stored := v_stored + 1;
      END LOOP;

      IF NOT (ct ? 'channels') OR jsonb_array_length(coalesce(ct->'channels','[]')) = 0 THEN
        INSERT INTO campaign_contact_findings
          (campaign_lead_id, contact_business_link_id, service_run_id)
        VALUES (lead.id, v_link, v_run_id);
      END IF;
    END LOOP;
  END IF;

  IF v_stored > 0 OR coalesce((p_payload->>'not_found')::boolean,false) THEN
    v_rev := advance_lead_revision(w.campaign_lead_id, 'contact_verification');
  END IF;

  v_state := _finish_work_item(w, 'succeeded', p_payload->'run');
  RETURN jsonb_build_object('result', v_state, 'channels_stored', v_stored,
    'suppressed', v_suppressed, 'not_found', coalesce((p_payload->>'not_found')::boolean,false));
END $$;

-- ---------------------------------------------------------------------------
-- fail / defer
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@.fail_work_item(
  p_work_item_id uuid, p_claim_token uuid, p_error_code text, p_detail text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE w work_items;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  UPDATE work_items SET
    state = 'failed_retryable',
    retryable_failure_count = retryable_failure_count + 1,
    available_at = now() + make_interval(secs => 60 * power(2, w.retryable_failure_count)::int),
    claim_token = NULL, worker_id = NULL, lease_expires_at = NULL,
    error_code = p_error_code, error_detail = left(p_detail, 4000)
  WHERE id = w.id;
  UPDATE service_runs SET status = 'failed', completed_at = now(), error_code = p_error_code
   WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;
  RETURN 'failed_retryable';
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.defer_work_item(
  p_work_item_id uuid, p_claim_token uuid, p_retry_at timestamptz, p_cause text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE w work_items;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  UPDATE work_items SET
    state = 'pending',
    provider_deferral_count = provider_deferral_count + 1,   -- NEVER the failure counter
    available_at = greatest(p_retry_at, now() + interval '5 seconds'),
    claim_token = NULL, worker_id = NULL, lease_expires_at = NULL,
    error_code = NULL, error_detail = 'deferred: ' || coalesce(p_cause,'provider')
  WHERE id = w.id;
  UPDATE service_runs SET status = 'deferred', completed_at = now()
   WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;
  RETURN 'deferred';
END $$;
