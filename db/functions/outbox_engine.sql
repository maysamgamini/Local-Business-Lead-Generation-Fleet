-- outbox_engine.sql (T022)
-- Event Relay's claim/complete/fail for outbox_deliveries — same lease + fence
-- discipline as work items. Consumption receipts commit with the completion.
-- At-least-once; consumers idempotent on event_id.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.claim_outbox_deliveries(
  p_destination text, p_worker_id text, p_batch integer DEFAULT 10)
RETURNS TABLE (delivery_id uuid, claim_token uuid, event_id uuid,
               event_type text, event_class text, aggregate_id uuid,
               effective_revision bigint, payload jsonb, attempt_count integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
BEGIN
  RETURN QUERY
  WITH picked AS (
    SELECT d.id FROM outbox_deliveries d
     WHERE d.destination = p_destination AND d.state = 'pending'
       AND d.available_at <= now()
     ORDER BY d.available_at
     LIMIT LEAST(p_batch, 50)
     FOR UPDATE SKIP LOCKED
  ), claimed AS (
    UPDATE outbox_deliveries d SET
      state = 'running', claimed_at = now(),
      lease_expires_at = now() + interval '3 minutes',
      claim_token = gen_random_uuid(),
      attempt_count = d.attempt_count + 1
    FROM picked p WHERE d.id = p.id
    RETURNING d.id, d.claim_token, d.event_id, d.attempt_count
  )
  SELECT c.id, c.claim_token, e.id, e.event_type, e.event_class,
         e.aggregate_id, e.effective_revision, e.payload, c.attempt_count
    FROM claimed c JOIN outbox_events e ON e.id = c.event_id;
END $$;

-- Completion records the consumption receipt in the SAME transaction.
CREATE OR REPLACE FUNCTION @@SCHEMA@@.complete_outbox_delivery(
  p_delivery_id uuid, p_claim_token uuid, p_result_hash text DEFAULT NULL,
  p_consumer_version text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE d outbox_deliveries;
BEGIN
  SELECT * INTO d FROM outbox_deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND OR d.state <> 'running'
     OR d.claim_token IS DISTINCT FROM p_claim_token
     OR d.lease_expires_at <= now() THEN
    RAISE EXCEPTION 'fence_violation' USING ERRCODE = 'P0001',
      DETAIL = 'outbox delivery ownership lost — discard side effects if possible';
  END IF;
  UPDATE outbox_deliveries SET state = 'delivered', delivered_at = now(),
    claim_token = NULL, lease_expires_at = NULL
  WHERE id = d.id;
  INSERT INTO event_consumptions (event_id, destination, consumer_version, result_hash)
  VALUES (d.event_id, d.destination, p_consumer_version, p_result_hash)
  ON CONFLICT (event_id, destination) DO NOTHING;
  RETURN 'delivered';
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.fail_outbox_delivery(
  p_delivery_id uuid, p_claim_token uuid, p_error text,
  p_dead_threshold integer DEFAULT 6)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE d outbox_deliveries; v_state text;
BEGIN
  SELECT * INTO d FROM outbox_deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND OR d.state <> 'running'
     OR d.claim_token IS DISTINCT FROM p_claim_token THEN
    RAISE EXCEPTION 'fence_violation' USING ERRCODE = 'P0001';
  END IF;
  v_state := CASE WHEN d.attempt_count >= p_dead_threshold THEN 'dead_letter' ELSE 'pending' END;
  UPDATE outbox_deliveries SET
    state = v_state,
    available_at = now() + make_interval(secs => 30 * power(2, d.attempt_count)::int),
    claim_token = NULL, lease_expires_at = NULL,
    last_error = left(p_error, 2000)
  WHERE id = d.id;
  RETURN v_state;
END $$;
