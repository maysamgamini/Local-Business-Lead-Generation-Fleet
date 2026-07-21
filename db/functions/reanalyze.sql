-- reanalyze.sql — operator-triggered fresh re-analysis of a single lead (Ops Console feature #2).
-- Re-opens the lead's analyzer work items (website/reviews/phone/social/ads/competitors) + the assessment work
-- item to 'pending' so the workers re-scrape FRESH (the 30-day evidence cache only applies at
-- discovery time, so a direct reopen always re-runs) and the scorer re-scores. Mirrors the
-- reopen shape used by advance_lead_revision / requeue_stale_assessments (state->pending,
-- available_at=now(), requested_version bumped, retry counters reset).
--
-- Guards:
--   * phone_probe is NEVER reopened here (it places a real outbound call — surprise cost);
--     callers who want a re-probe must request it explicitly elsewhere.
--   * only services ENABLED in service_config are reopened (no worker => would hang).
--   * only non-running items are touched (never disrupts in-flight work).
-- Read/EXECUTE-safe: the console calls this via a single Postgres node; no direct DML by workers.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.requeue_lead_analysis(
  p_campaign_lead_id uuid,
  p_services text[] DEFAULT ARRAY['website','reviews','phone','social','ads','competitors'])
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_rev bigint; v_reopened int; v_exists boolean;
BEGIN
  SELECT true INTO v_exists FROM campaign_leads WHERE id = p_campaign_lead_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown_lead' USING ERRCODE = 'P0001';
  END IF;

  -- Bump the watermark so the assessment trails and is guaranteed to re-score.
  UPDATE campaign_leads SET lead_revision = lead_revision + 1
   WHERE id = p_campaign_lead_id
   RETURNING lead_revision INTO v_rev;

  -- Reopen the requested analyzer work items (enabled services only, phone_probe excluded,
  -- non-running only) so the workers re-scrape fresh evidence.
  UPDATE work_items w
     SET state = 'pending', available_at = now(),
         requested_version = GREATEST(w.requested_version, v_rev),
         retryable_failure_count = 0, error_code = NULL
   WHERE w.campaign_lead_id = p_campaign_lead_id
     AND w.scope_type = 'lead'
     AND w.service = ANY (p_services)
     AND w.service <> 'phone_probe'
     AND w.state IN ('done','dead','skipped_prerequisite','skipped_gate','skipped_budget',
                     'failed_retryable','pending','blocked')
     AND EXISTS (SELECT 1 FROM service_config sc WHERE sc.service = w.service AND sc.enabled);
  GET DIAGNOSTICS v_reopened = ROW_COUNT;

  -- Reopen the assessment so a re-score runs even if the re-scrape yields identical evidence.
  UPDATE work_items w
     SET state = 'pending', available_at = now(),
         requested_version = GREATEST(w.requested_version, v_rev),
         retryable_failure_count = 0, error_code = NULL
   WHERE w.campaign_lead_id = p_campaign_lead_id
     AND w.scope_type = 'lead' AND w.service = 'assessment'
     AND w.state IN ('done','dead','failed_retryable','pending','blocked');

  RETURN jsonb_build_object('ok', true, 'lead_id', p_campaign_lead_id,
    'lead_revision', v_rev, 'analyzers_reopened', v_reopened);
END $$;
