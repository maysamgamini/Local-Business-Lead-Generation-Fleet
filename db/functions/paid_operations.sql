-- paid_operations.sql (T021)
-- authorize_paid_operation / authorize_enrichment_operation (atomic max-billable
-- budget + leased permit, both-or-neither), settle (actual<=maximum, no overrun
-- path), release, renew_provider_permit, reconcile_expired_reservations.
-- Lock order everywhere: campaign row -> provider row (deadlock-consistent).

-- Internal: recompute budget_state; flip paid-tier work to skipped_budget on
-- exhaustion; emit budget.state_changed on transitions.
CREATE OR REPLACE FUNCTION @@SCHEMA@@._recompute_budget_state(p_campaign_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE c campaigns; v_avail numeric; v_new text;
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id;  -- caller holds the lock
  SELECT c.budget_cap_usd
       - coalesce(sum(actual_usd) FILTER (WHERE state = 'settled'), 0)
       - coalesce(sum(maximum_billable_usd) FILTER (WHERE state = 'reserved'), 0)
    INTO v_avail FROM budget_transactions WHERE campaign_id = p_campaign_id;
  v_new := CASE WHEN v_avail <= 0 THEN 'exhausted'
                WHEN v_avail < 0.2 * c.budget_cap_usd THEN 'near_limit'
                ELSE 'within_budget' END;
  IF v_new <> c.budget_state THEN
    UPDATE campaigns SET budget_state = v_new WHERE id = p_campaign_id;
    PERFORM _emit_event('budget.state_changed','notification', false, p_campaign_id, NULL,
      jsonb_build_object('budget_state', v_new, 'available_usd', round(v_avail,2)),
      'budget.state:' || p_campaign_id || ':' || v_new || ':' || to_char(now(),'YYYYMMDDHH24MI'));
    IF v_new = 'exhausted' THEN
      UPDATE work_items SET state = 'skipped_budget'
       WHERE campaign_id = p_campaign_id AND service = 'enrichment'
         AND state IN ('blocked','pending','waiting_approval');
    END IF;
  END IF;
  RETURN v_new;
END $$;

-- Internal: budget + permit under locks. Returns jsonb status object.
CREATE OR REPLACE FUNCTION @@SCHEMA@@._authorize_locked(
  p_campaign_id uuid, p_business_id uuid, p_service_run_id uuid, p_service text,
  p_provider text, p_scope text, p_operation text,
  p_max numeric, p_idem text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  c campaigns; pl provider_limits; v_avail numeric;
  v_auth uuid; v_permit uuid; v_token uuid; v_expires timestamptz;
  v_active int; v_elapsed numeric; v_tokens numeric;
BEGIN
  -- idempotent replay: same key returns the existing authorization
  SELECT id INTO v_auth FROM budget_transactions WHERE idempotency_key = p_idem;
  IF v_auth IS NOT NULL THEN
    SELECT p2.id, p2.permit_token, p2.expires_at INTO v_permit, v_token, v_expires
      FROM provider_permits p2 WHERE p2.service_run_id = p_service_run_id
        AND p2.state = 'active' ORDER BY p2.acquired_at DESC LIMIT 1;
    RETURN jsonb_build_object('status','authorized','authorization_id',v_auth,
      'permit_id',v_permit,'permit_token',v_token,'permit_expires_at',v_expires,'replay',true);
  END IF;

  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF c.status IN ('complete','failed','canceled') THEN
    RETURN jsonb_build_object('status','campaign_terminal');
  END IF;
  SELECT c.budget_cap_usd
       - coalesce(sum(actual_usd) FILTER (WHERE state = 'settled'), 0)
       - coalesce(sum(maximum_billable_usd) FILTER (WHERE state = 'reserved'), 0)
    INTO v_avail FROM budget_transactions WHERE campaign_id = p_campaign_id;
  IF p_max > v_avail THEN
    PERFORM _recompute_budget_state(p_campaign_id);
    RETURN jsonb_build_object('status','insufficient_budget','available_usd',round(v_avail,2));
  END IF;

  SELECT * INTO pl FROM provider_limits
   WHERE provider = p_provider AND credential_scope = p_scope FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown_provider' USING ERRCODE = 'P0001',
      DETAIL = p_provider || '/' || p_scope;
  END IF;
  IF pl.cooldown_until IS NOT NULL AND pl.cooldown_until > now() THEN
    RETURN jsonb_build_object('status','retry_at','retry_at', pl.cooldown_until);
  END IF;
  -- token bucket refill (rpm per 60s, capped at rpm)
  v_elapsed := extract(epoch FROM (now() - pl.bucket_refilled_at));
  v_tokens  := LEAST(pl.requests_per_minute::numeric,
                     pl.bucket_tokens + v_elapsed * pl.requests_per_minute / 60.0);
  IF v_tokens < 1 THEN
    RETURN jsonb_build_object('status','retry_at',
      'retry_at', now() + make_interval(secs => ((1 - v_tokens) * 60.0 / pl.requests_per_minute)::numeric));
  END IF;
  -- leased concurrency: count unexpired active permits (crash-safe, no counters)
  SELECT count(*) INTO v_active FROM provider_permits
   WHERE provider = p_provider AND credential_scope = p_scope
     AND state = 'active' AND expires_at > now();
  IF v_active >= pl.concurrent_requests THEN
    RETURN jsonb_build_object('status','retry_at','retry_at', now() + interval '20 seconds');
  END IF;

  -- both-or-neither: consume token, insert reservation + permit
  UPDATE provider_limits SET bucket_tokens = v_tokens - 1, bucket_refilled_at = now()
   WHERE provider = p_provider AND credential_scope = p_scope;

  INSERT INTO budget_transactions
    (campaign_id, business_id, service_run_id, service, provider, operation,
     maximum_billable_usd, expires_at, idempotency_key)
  VALUES (p_campaign_id, p_business_id, p_service_run_id, p_service, p_provider,
     p_operation, p_max, now() + interval '30 minutes', p_idem)
  RETURNING id INTO v_auth;

  v_token := gen_random_uuid();
  INSERT INTO provider_permits
    (provider, credential_scope, service_run_id, operation, permit_token, expires_at)
  VALUES (p_provider, p_scope, p_service_run_id, p_operation, v_token,
          now() + interval '10 minutes')
  RETURNING id, expires_at INTO v_permit, v_expires;

  PERFORM _recompute_budget_state(p_campaign_id);
  RETURN jsonb_build_object('status','authorized','authorization_id',v_auth,
    'permit_id',v_permit,'permit_token',v_token,'permit_expires_at',v_expires);
END $$;

-- Non-gated spends (analyzer LLM calls, review fetches, discovery pages)
CREATE OR REPLACE FUNCTION @@SCHEMA@@.authorize_paid_operation(
  p_work_item_id uuid, p_claim_token uuid, p_service_run_id uuid,
  p_provider text, p_credential_scope text, p_operation text,
  p_maximum_billable_usd numeric, p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE w work_items; lead campaign_leads;
BEGIN
  IF p_maximum_billable_usd IS NULL OR p_maximum_billable_usd <= 0 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = 'P0001',
      DETAIL = 'maximum_billable_usd must be a positive, provider-enforceable bound';
  END IF;
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  SELECT * INTO lead FROM campaign_leads WHERE id = w.campaign_lead_id;
  RETURN _authorize_locked(w.campaign_id, lead.business_id, p_service_run_id,
    w.service, p_provider, p_credential_scope, p_operation,
    p_maximum_billable_usd, p_idempotency_key);
END $$;

-- Gated variant: gate + budget + permit in ONE transaction (no TOCTOU window).
-- Gate failure sets the work-item state directly and consumes NO retry.
CREATE OR REPLACE FUNCTION @@SCHEMA@@.authorize_enrichment_operation(
  p_work_item_id uuid, p_claim_token uuid, p_service_run_id uuid,
  p_provider text, p_credential_scope text, p_operation text,
  p_maximum_billable_usd numeric, p_idempotency_key text,
  p_gate_threshold numeric, p_gate_threshold_version text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  w work_items; lead campaign_leads; c campaigns; a lead_assessments;
  v_domain text; v_terminal boolean; v_result jsonb;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  IF w.service <> 'enrichment' THEN
    RAISE EXCEPTION 'invalid_transition' USING ERRCODE = 'P0001';
  END IF;
  SELECT * INTO lead FROM campaign_leads WHERE id = w.campaign_lead_id FOR UPDATE;
  SELECT * INTO c FROM campaigns WHERE id = w.campaign_id;
  SELECT website_domain INTO v_domain FROM businesses WHERE id = lead.business_id;

  -- analysis_terminal: all analyzer items for this lead are terminal
  SELECT NOT EXISTS (SELECT 1 FROM work_items s
    WHERE s.campaign_lead_id = lead.id
      AND s.service IN ('website','reviews','phone')
      AND s.state NOT IN ('done','dead','skipped_gate','skipped_budget',
                          'skipped_prerequisite','canceled')) INTO v_terminal;

  SELECT * INTO a FROM lead_assessments
   WHERE campaign_lead_id = lead.id AND is_current = true;

  -- Gate checks, all inside this transaction:
  IF c.status NOT IN ('analyzing','awaiting_approval')
     OR (c.requires_approval AND c.approval_status <> 'approved')
     OR a.id IS NULL
     OR a.opportunity_score < p_gate_threshold
     OR EXISTS (SELECT 1 FROM suppressions s WHERE
          (s.level = 'business' AND s.value = lead.business_id::text) OR
          (s.level = 'domain'   AND s.value = v_domain)) THEN
    UPDATE work_items SET
      state = CASE
        WHEN c.requires_approval AND c.approval_status = 'pending'
             AND a.id IS NOT NULL AND a.opportunity_score >= p_gate_threshold
          THEN 'waiting_approval'
        WHEN v_terminal THEN 'skipped_gate'
        ELSE 'blocked' END,
      claim_token = NULL, worker_id = NULL, lease_expires_at = NULL
    WHERE id = w.id;
    UPDATE service_runs SET status = 'discarded', completed_at = now()
     WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;
    RETURN jsonb_build_object('status',
      CASE WHEN v_terminal THEN 'gate_failed:skipped_gate' ELSE 'gate_failed:blocked' END);
  END IF;

  -- Gate passed: record provenance, then budget + permit atomically
  UPDATE work_items SET gate_assessment_id = a.id, gate_revision = lead.lead_revision,
    gate_threshold_version = p_gate_threshold_version WHERE id = w.id;

  v_result := _authorize_locked(w.campaign_id, lead.business_id, p_service_run_id,
    'enrichment', p_provider, p_credential_scope, p_operation,
    p_maximum_billable_usd, p_idempotency_key);
  RETURN v_result;
END $$;

-- Settle: actual <= maximum enforced (SC-005 — no overrun path). Valid after
-- work-item cancellation: credentials are authorization_id + permit_token.
CREATE OR REPLACE FUNCTION @@SCHEMA@@.settle_paid_operation(
  p_authorization_id uuid, p_permit_token uuid,
  p_actual_usd numeric, p_provider_request_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE bt budget_transactions;
BEGIN
  SELECT * INTO bt FROM budget_transactions WHERE id = p_authorization_id FOR UPDATE;
  IF NOT FOUND OR bt.state <> 'reserved' THEN
    RETURN jsonb_build_object('status','not_reserved','state', coalesce(bt.state,'missing'));
  END IF;
  IF p_actual_usd > bt.maximum_billable_usd THEN
    UPDATE budget_transactions SET reconciliation_status = 'reconciliation_required',
      provider_request_id = coalesce(p_provider_request_id, provider_request_id)
    WHERE id = bt.id;
    RETURN jsonb_build_object('status','max_exceeded_flagged',
      'maximum', bt.maximum_billable_usd, 'actual', p_actual_usd);
  END IF;
  UPDATE budget_transactions SET state = 'settled', actual_usd = p_actual_usd,
    settled_at = now(), provider_request_id = p_provider_request_id
  WHERE id = bt.id;
  UPDATE provider_permits SET state = 'released', released_at = now()
   WHERE permit_token = p_permit_token AND state = 'active';
  PERFORM _recompute_budget_state(bt.campaign_id);
  RETURN jsonb_build_object('status','settled');
END $$;

CREATE OR REPLACE FUNCTION @@SCHEMA@@.release_paid_operation(
  p_authorization_id uuid, p_permit_token uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE bt budget_transactions;
BEGIN
  SELECT * INTO bt FROM budget_transactions WHERE id = p_authorization_id FOR UPDATE;
  IF NOT FOUND OR bt.state <> 'reserved' THEN
    RETURN jsonb_build_object('status','not_reserved');
  END IF;
  UPDATE budget_transactions SET state = 'released' WHERE id = bt.id;
  UPDATE provider_permits SET state = 'released', released_at = now()
   WHERE permit_token = p_permit_token AND state = 'active';
  PERFORM _recompute_budget_state(bt.campaign_id);
  RETURN jsonb_build_object('status','released');
END $$;

-- Fenced permit renewal for provider calls outliving the lease
CREATE OR REPLACE FUNCTION @@SCHEMA@@.renew_provider_permit(
  p_permit_id uuid, p_permit_token uuid)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_new timestamptz;
BEGIN
  UPDATE provider_permits SET expires_at = now() + interval '10 minutes'
   WHERE id = p_permit_id AND permit_token = p_permit_token
     AND state = 'active' AND expires_at > now()
   RETURNING expires_at INTO v_new;
  IF v_new IS NULL THEN
    RAISE EXCEPTION 'fence_violation' USING ERRCODE = 'P0001',
      DETAIL = 'permit expired or not owned — slot reclaimed';
  END IF;
  RETURN v_new;
END $$;

-- Sweeper: expired reservations -> release (provably uncharged: no provider
-- request id) / flag reconciliation_required (uncertain).
CREATE OR REPLACE FUNCTION @@SCHEMA@@.reconcile_expired_reservations()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE r record; v_released int := 0; v_flagged int := 0;
BEGIN
  FOR r IN SELECT id, campaign_id, provider_request_id FROM budget_transactions
            WHERE state = 'reserved' AND expires_at <= now()
            FOR UPDATE SKIP LOCKED LOOP
    IF r.provider_request_id IS NULL THEN
      UPDATE budget_transactions SET state = 'released' WHERE id = r.id;
      v_released := v_released + 1;
    ELSE
      UPDATE budget_transactions SET reconciliation_status = 'reconciliation_required'
       WHERE id = r.id;
      v_flagged := v_flagged + 1;
    END IF;
    PERFORM _recompute_budget_state(r.campaign_id);
  END LOOP;
  RETURN jsonb_build_object('released', v_released, 'reconciliation_required', v_flagged);
END $$;
