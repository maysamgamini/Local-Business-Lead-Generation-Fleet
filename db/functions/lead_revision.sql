-- lead_revision.sql (T020)
-- advance_lead_revision(): monotonic watermark + impact-routed requested_version
-- bumps. Callers invoke ONLY on effective change (new evidence insert, new
-- verification event, contact finding, suppression, critic resolution) —
-- _insert_evidence's `inserted` flag is the effective-change detector for
-- evidence paths; idempotent replays therefore no-op upstream.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.advance_lead_revision(
  p_campaign_lead_id uuid, p_cause_type text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_new_rev bigint;
BEGIN
  UPDATE campaign_leads
     SET lead_revision = lead_revision + 1
   WHERE id = p_campaign_lead_id
   RETURNING lead_revision INTO v_new_rev;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown_lead' USING ERRCODE = 'P0001';
  END IF;

  -- Route requested_version bumps ONLY to services mapped for this cause.
  -- Self-requeue is excluded by seed discipline (a cause never maps to its
  -- own producing service). done -> pending reopen happens here too.
  UPDATE work_items w
     SET requested_version = GREATEST(w.requested_version, v_new_rev),
         state = CASE
                   WHEN w.state = 'done'
                        AND GREATEST(w.requested_version, v_new_rev) > w.completed_version
                     THEN 'pending'
                   ELSE w.state
                 END,
         available_at = CASE
                   WHEN w.state = 'done'
                        AND GREATEST(w.requested_version, v_new_rev) > w.completed_version
                     THEN now()
                   ELSE w.available_at
                 END
   WHERE w.campaign_lead_id = p_campaign_lead_id
     AND w.scope_type = 'lead'
     AND w.state IN ('pending','blocked','done','failed_retryable','waiting_approval','running')
     AND EXISTS (SELECT 1 FROM revision_impact_rules r
                  WHERE r.cause_type = p_cause_type
                    AND r.affected_service = w.service
                    AND r.enabled);

  RETURN v_new_rev;
END $$;
