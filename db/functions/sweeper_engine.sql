-- sweeper_engine.sql (T019)
-- reap_expired_leases(), requeue_retryable_work(), requeue_stale_assessments().
-- The Sweeper is an observer with a mop: it never completes work, it only
-- returns it to claimable states. Fencing already guarantees zombies can't commit.

-- Expired leases: work items, outbox deliveries, provider permits.
CREATE OR REPLACE FUNCTION @@SCHEMA@@.reap_expired_leases()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_items int; v_deliveries int; v_permits int;
BEGIN
  UPDATE work_items SET
    state = 'failed_retryable',
    retryable_failure_count = retryable_failure_count + 1,
    available_at = now() + make_interval(secs => 60 * power(2, retryable_failure_count)::int),
    claim_token = NULL, worker_id = NULL, lease_expires_at = NULL,
    error_code = 'lease_expired'
  WHERE state = 'running' AND lease_expires_at <= now();
  GET DIAGNOSTICS v_items = ROW_COUNT;
  -- mark orphaned runs discarded
  UPDATE service_runs r SET status = 'discarded', completed_at = now()
   WHERE r.status = 'running'
     AND EXISTS (SELECT 1 FROM work_items w
                  WHERE w.id = r.work_item_id AND w.state <> 'running');

  UPDATE outbox_deliveries SET
    state = 'pending', claim_token = NULL, lease_expires_at = NULL,
    available_at = now() + make_interval(secs => 30 * power(2, attempt_count)::int)
  WHERE state = 'running' AND lease_expires_at <= now();
  GET DIAGNOSTICS v_deliveries = ROW_COUNT;

  UPDATE provider_permits SET state = 'expired'
  WHERE state = 'active' AND expires_at <= now();
  GET DIAGNOSTICS v_permits = ROW_COUNT;

  RETURN jsonb_build_object('work_items', v_items,
    'deliveries', v_deliveries, 'permits', v_permits);
END $$;

-- Explicit retry transition: failed_retryable -> pending when due; threshold -> dead.
CREATE OR REPLACE FUNCTION @@SCHEMA@@.requeue_retryable_work(
  p_dead_threshold integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_requeued int; v_dead int; r record;
BEGIN
  UPDATE work_items SET state = 'pending'
  WHERE state = 'failed_retryable'
    AND retryable_failure_count < p_dead_threshold
    AND available_at <= now();
  GET DIAGNOSTICS v_requeued = ROW_COUNT;

  v_dead := 0;
  FOR r IN SELECT id, campaign_id, campaign_lead_id, service, error_code
             FROM work_items
            WHERE state = 'failed_retryable'
              AND retryable_failure_count >= p_dead_threshold
            FOR UPDATE SKIP LOCKED LOOP
    UPDATE work_items SET state = 'dead' WHERE id = r.id;
    PERFORM _emit_event('workitem.dead','notification', false,
      coalesce(r.campaign_lead_id, r.campaign_id), NULL,
      jsonb_build_object('work_item_id', r.id, 'service', r.service,
                         'error_code', r.error_code),
      'workitem.dead:' || r.id);
    v_dead := v_dead + 1;
  END LOOP;

  RETURN jsonb_build_object('requeued', v_requeued, 'dead', v_dead);
END $$;

-- Disabled-service cleanup: any nonterminal work item whose service is disabled in
-- service_config (no worker shipped yet) is marked terminal (skipped_prerequisite),
-- so a campaign can finalize without it. Idempotent; safety-net for items created
-- before a service was disabled (commit_discovery_results gates new ones at creation).
CREATE OR REPLACE FUNCTION @@SCHEMA@@.skip_disabled_service_work()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_n int;
BEGIN
  UPDATE work_items wi SET state = 'skipped_prerequisite'
  FROM service_config sc
  WHERE sc.service = wi.service AND sc.enabled = false
    AND wi.state NOT IN
      ('done','dead','skipped_gate','skipped_budget','skipped_prerequisite','canceled');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- Assessments behind the watermark: reopen assessment work per lead where the
-- current assessment (or none) is older than lead_revision. A 'done' assessment
-- reopens when its completed_version trails; a 'dead' assessment revives only when
-- GENUINELY NEW evidence arrived since its last attempt (lead_revision >
-- requested_version) — bounded against a dead<->pending loop for an item that keeps
-- failing on the same revision — and gets a fresh retry budget (counters reset,
-- but never execution_attempt_count: that is the service_runs key).
CREATE OR REPLACE FUNCTION @@SCHEMA@@.requeue_stale_assessments()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_n int;
BEGIN
  UPDATE work_items w SET
    requested_version = GREATEST(w.requested_version, cl.lead_revision),
    state = CASE WHEN w.state IN ('done','dead') THEN 'pending' ELSE w.state END,
    available_at = CASE WHEN w.state IN ('done','dead') THEN now() ELSE w.available_at END,
    retryable_failure_count = CASE WHEN w.state = 'dead' THEN 0 ELSE w.retryable_failure_count END,
    error_code = CASE WHEN w.state = 'dead' THEN NULL ELSE w.error_code END
  FROM campaign_leads cl
  WHERE cl.id = w.campaign_lead_id
    AND w.service = 'assessment'
    AND w.completed_version < cl.lead_revision
    AND (
      (w.state IN ('done','pending','failed_retryable') AND w.requested_version < cl.lead_revision)
      OR (w.state = 'dead' AND w.requested_version < cl.lead_revision)
    );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
