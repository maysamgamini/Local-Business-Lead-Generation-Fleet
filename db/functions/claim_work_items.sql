-- claim_work_items.sql (T017)
-- The concurrency semaphore + batch claim + service_run creation, and
-- renew_lease(). LIMIT alone caps batches, not concurrency: the service_config
-- row lock serializes slot computation (review round 5, finding 1).

CREATE OR REPLACE FUNCTION @@SCHEMA@@.claim_work_items(
  p_service text, p_worker_id text)
RETURNS TABLE (work_item_id uuid, claim_token uuid, service_run_id uuid,
               processing_version bigint, scope_type text,
               campaign_id uuid, campaign_lead_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  cfg service_config;
  v_running integer;
  v_slots integer;
BEGIN
  -- Serialization point: one claimer computes slots at a time per service.
  SELECT * INTO cfg FROM service_config WHERE service = p_service FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown_service' USING ERRCODE = 'P0001', DETAIL = p_service;
  END IF;

  SELECT count(*) INTO v_running FROM work_items w
   WHERE w.service = p_service AND w.state = 'running'
     AND w.lease_expires_at > now();

  v_slots := LEAST(cfg.claim_batch_size, cfg.max_concurrency - v_running);
  IF v_slots <= 0 THEN RETURN; END IF;

  RETURN QUERY
  WITH picked AS (
    SELECT w.id FROM work_items w
     WHERE w.service = p_service AND w.state = 'pending'
       AND w.available_at <= now()
     ORDER BY w.priority DESC, w.created_at
     LIMIT v_slots
     FOR UPDATE SKIP LOCKED
  ), claimed AS (
    UPDATE work_items w
       SET state = 'running',
           claimed_at = now(),
           lease_expires_at = now() + make_interval(secs => cfg.lease_ttl_s),
           claim_token = gen_random_uuid(),
           worker_id = p_worker_id,
           processing_version = w.requested_version,
           execution_attempt_count = w.execution_attempt_count + 1
      FROM picked p WHERE w.id = p.id
     RETURNING w.id, w.claim_token, w.requested_version, w.scope_type,
               w.campaign_id, w.campaign_lead_id, w.execution_attempt_count
  ), runs AS (
    INSERT INTO service_runs (work_item_id, work_attempt, service, input_version)
    SELECT c.id, c.execution_attempt_count, p_service, c.requested_version
      FROM claimed c
    RETURNING service_runs.id, service_runs.work_item_id
  )
  SELECT c.id, c.claim_token, r.id, c.requested_version,
         c.scope_type, c.campaign_id, c.campaign_lead_id
    FROM claimed c JOIN runs r ON r.work_item_id = c.id;
END $$;

-- Fenced lease renewal: post-expiry renewal fails; worker must discard.
CREATE OR REPLACE FUNCTION @@SCHEMA@@.renew_lease(
  p_work_item_id uuid, p_claim_token uuid)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_new timestamptz; v_ttl integer;
BEGIN
  SELECT sc.lease_ttl_s INTO v_ttl
    FROM work_items w JOIN service_config sc ON sc.service = w.service
   WHERE w.id = p_work_item_id;

  UPDATE work_items
     SET lease_expires_at = now() + make_interval(secs => coalesce(v_ttl, 600))
   WHERE id = p_work_item_id
     AND state = 'running'
     AND claim_token = p_claim_token
     AND lease_expires_at > now()
   RETURNING lease_expires_at INTO v_new;
  IF v_new IS NULL THEN
    RAISE EXCEPTION 'fence_violation' USING ERRCODE = 'P0001',
      DETAIL = 'renew after lease expiry or ownership loss — discard result';
  END IF;
  RETURN v_new;
END $$;
