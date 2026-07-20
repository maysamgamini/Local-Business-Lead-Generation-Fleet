-- campaign_lifecycle.sql (T023)
-- create_campaign (trusted args, validation, caller-scoped idempotency, config
-- pinning, deadlines, discovery work item), commit_discovery_results (fenced,
-- ONE transaction for the whole discovery result), cancel_campaign.

CREATE OR REPLACE FUNCTION @@SCHEMA@@.create_campaign(
  p_request jsonb, p_caller_identity uuid, p_trigger_source text)
RETURNS TABLE (campaign_id uuid, creation_status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  v_existing uuid; v_id uuid;
  v_sets record; v_policy jsonb;
  v_geo jsonb; v_requires boolean; v_deadline_h numeric; v_target jsonb;
BEGIN
  -- ---- validation (typed errors; no campaign on violation) ----
  IF p_request->>'schema_version' IS DISTINCT FROM '1.0' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='unsupported schema_version';
  END IF;
  IF coalesce(p_request->>'request_id','') = '' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='request_id required';
  END IF;
  IF coalesce(p_request->>'business_type','') = '' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='business_type required';
  END IF;
  -- Target mode (analyze ONE business by name+city or website) OR area geo.
  -- Target mode synthesizes a nominal geo so campaigns' NOT NULL geo columns hold;
  -- Discovery reads campaigns.target and does a Places text search instead of nearby.
  v_target := p_request->'target';
  IF v_target IS NOT NULL AND jsonb_typeof(v_target) = 'object'
     AND (coalesce(v_target->>'name','') <> '' OR coalesce(v_target->>'website','') <> '') THEN
    v_geo := jsonb_build_object('type','city_radius','city',coalesce(v_target->>'city',''),'radius_m',1);
  ELSE
    v_target := NULL;
    IF p_request->'geo' IS NULL OR jsonb_typeof(p_request->'geo') <> 'object' THEN
      RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='geo or target required';
    END IF;
    v_geo := p_request->'geo';
    IF v_geo->>'type' NOT IN ('zip','city_radius') THEN
      RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001',
        DETAIL='geo.type must be zip|city_radius (region is not supported in v1)';
    END IF;
    IF coalesce((v_geo->>'radius_m')::int, 0) <= 0 THEN
      RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='geo.radius_m required';
    END IF;
  END IF;
  IF p_request->>'depth' NOT IN ('quick','standard','deep') THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='invalid depth';
  END IF;
  IF coalesce((p_request->>'volume_cap')::int, 0) NOT BETWEEN 1 AND 300 THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001',
      DETAIL='volume_cap must be 1..300 (v1 system maximum)';
  END IF;
  IF p_request->'budget'->>'currency' IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='v1 accepts USD only';
  END IF;
  IF coalesce((p_request->'budget'->>'amount')::numeric, 0) <= 0 THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='budget.amount must be > 0';
  END IF;
  IF p_trigger_source NOT IN ('form','schedule','webhook') THEN
    RAISE EXCEPTION 'invalid_request' USING ERRCODE='P0001', DETAIL='bad trigger_source';
  END IF;

  -- ---- caller-scoped idempotency ----
  SELECT c.id INTO v_existing FROM campaigns c
   WHERE c.caller_identity = p_caller_identity
     AND c.request_id = p_request->>'request_id';
  IF v_existing IS NOT NULL THEN
    RETURN QUERY SELECT v_existing, 'existing'::text; RETURN;
  END IF;

  -- ---- pin exactly one active config set per type ----
  SELECT
    (SELECT id FROM config_sets WHERE config_type='scoring'        AND activated_at IS NOT NULL AND retired_at IS NULL) AS scoring,
    (SELECT id FROM config_sets WHERE config_type='chain_rules'    AND activated_at IS NOT NULL AND retired_at IS NULL) AS chain,
    (SELECT id FROM config_sets WHERE config_type='vertical_policy'AND activated_at IS NOT NULL AND retired_at IS NULL) AS vertical,
    (SELECT id FROM config_sets WHERE config_type='model_policy'   AND activated_at IS NOT NULL AND retired_at IS NULL) AS model,
    (SELECT id FROM config_sets WHERE config_type='service_policy' AND activated_at IS NOT NULL AND retired_at IS NULL) AS service
  INTO v_sets;
  IF v_sets.scoring IS NULL OR v_sets.chain IS NULL OR v_sets.vertical IS NULL
     OR v_sets.model IS NULL OR v_sets.service IS NULL THEN
    RAISE EXCEPTION 'config_missing' USING ERRCODE='P0001',
      DETAIL='one active config set required per type (run activate-v1 seeds)';
  END IF;

  -- deadline policy from the pinned service_policy set (hours; sane defaults)
  SELECT coalesce(jsonb_object_agg(policy_key, policy_value), '{}') INTO v_policy
    FROM service_policy_entries WHERE config_set_id = v_sets.service
     AND policy_key LIKE 'deadline.%';

  v_requires := coalesce((p_request->>'requires_approval')::boolean, false);
  v_deadline_h := coalesce((v_policy->'deadline.campaign_hours'->>0)::numeric,
                           (v_policy->>'deadline.campaign_hours')::numeric, 24);

  INSERT INTO campaigns
    (caller_identity, request_id, trigger_source, business_type,
     geo_type, geo_original, geo_radius_m, depth, volume_cap, budget_cap_usd,
     requires_approval, approval_status, exclusions, dry_run, target,
     scoring_config_set_id, chain_rule_set_id, vertical_policy_set_id,
     model_policy_set_id, service_policy_set_id,
     status, campaign_deadline_at, approval_deadline_at,
     critic_deadline_at, reconciliation_deadline_at, finalization_retry_deadline_at)
  VALUES
    (p_caller_identity, p_request->>'request_id', p_trigger_source,
     p_request->>'business_type',
     v_geo->>'type', v_geo, (v_geo->>'radius_m')::int,
     p_request->>'depth', (p_request->>'volume_cap')::int,
     (p_request->'budget'->>'amount')::numeric,
     v_requires, CASE WHEN v_requires THEN 'pending' ELSE 'n/a' END,
     coalesce(p_request->'exclusions','{"domains":[],"names":[]}'),
     coalesce((p_request->>'dry_run')::boolean, false), v_target,
     v_sets.scoring, v_sets.chain, v_sets.vertical, v_sets.model, v_sets.service,
     'discovering',
     now() + make_interval(hours => v_deadline_h::int),
     CASE WHEN v_requires THEN now() + interval '12 hours' END,
     now() + make_interval(hours => v_deadline_h::int),
     now() + make_interval(hours => (v_deadline_h + 24)::int),
     now() + make_interval(hours => (v_deadline_h + 2)::int))
  RETURNING id INTO v_id;

  -- campaign-scoped discovery work item (partial unique makes duplicates impossible)
  INSERT INTO work_items (scope_type, campaign_id, service, state)
  VALUES ('campaign', v_id, 'discovery', 'pending');

  PERFORM _emit_event('campaign.created','state_change', true, v_id, 0,
    jsonb_build_object('business_type', p_request->>'business_type',
                       'depth', p_request->>'depth'),
    'campaign.created:' || v_id);

  RETURN QUERY SELECT v_id, 'created'::text;
END $$;

-- ---------------------------------------------------------------------------
-- _reuse_fresh_evidence: freshness cache for rediscovered businesses. If this
-- business already has evidence for p_service from ANOTHER campaign observed within
-- p_window, copy the latest-per-feature rows into p_campaign_id (preserving the real
-- observed_at, so staleness/recency scoring stays honest) under a synthetic
-- 'cache-reuse' service_run, and mark the just-created analyzer work item done —
-- skipping the paid re-run. Only acts on an enabled, still-claimable work item
-- (state blocked|pending); disabled services (skipped_prerequisite) are left alone.
-- Returns the number of evidence rows copied (0 = cache miss / nothing to reuse).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@._reuse_fresh_evidence(
  p_business_id uuid, p_campaign_id uuid, p_lead_id uuid, p_service text, p_window interval)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE v_wi uuid; v_attempt int; v_run uuid; v_n int := 0; e record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM evidence_items ei
      WHERE ei.business_id = p_business_id AND ei.service = p_service
        AND ei.campaign_id <> p_campaign_id AND ei.observed_at > now() - p_window) THEN
    RETURN 0;
  END IF;
  SELECT id, execution_attempt_count INTO v_wi, v_attempt
    FROM work_items
   WHERE campaign_lead_id = p_lead_id AND service = p_service AND state IN ('blocked','pending');
  IF v_wi IS NULL THEN RETURN 0; END IF;

  INSERT INTO service_runs (work_item_id, work_attempt, service, input_version,
                            workflow_version, status, completed_at)
  VALUES (v_wi, v_attempt, p_service, 0, 'cache-reuse-v1', 'succeeded', now())
  ON CONFLICT (work_item_id, work_attempt) DO UPDATE SET status = 'succeeded'
  RETURNING id INTO v_run;

  FOR e IN
    SELECT DISTINCT ON (feature_key) feature_key, value_jsonb, value_type, unit,
           product_tag, source_provider, observed_at, calculation_version, excerpt
      FROM evidence_items
     WHERE business_id = p_business_id AND service = p_service
       AND campaign_id <> p_campaign_id AND observed_at > now() - p_window
     ORDER BY feature_key, observed_at DESC
  LOOP
    INSERT INTO evidence_items (business_id, campaign_id, service, feature_key, product_tag,
      value_jsonb, value_type, unit, source_provider, observed_at, service_run_id,
      idempotency_key, calculation_version, excerpt)
    VALUES (p_business_id, p_campaign_id, p_service, e.feature_key, e.product_tag,
      e.value_jsonb, e.value_type, e.unit, e.source_provider, e.observed_at, v_run,
      p_campaign_id::text||':'||p_business_id::text||':'||e.feature_key||':reused',
      e.calculation_version, e.excerpt)
    ON CONFLICT (campaign_id, service, idempotency_key) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;

  UPDATE work_items SET state = 'done', completed_at = now() WHERE id = v_wi;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------------
-- commit_discovery_results: THE single transaction for discovery output.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@.commit_discovery_results(
  p_campaign_id uuid, p_work_item_id uuid, p_claim_token uuid, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE
  w work_items; c campaigns; b jsonb; obs jsonb; ev jsonb; rel jsonb;
  v_biz uuid; v_lead uuid; v_redisc boolean; v_run_id uuid;
  v_count int := 0; v_state text; ins record; v_related uuid;
BEGIN
  w := _fenced_lock_work_item(p_work_item_id, p_claim_token);
  IF w.service <> 'discovery' OR w.scope_type <> 'campaign'
     OR w.campaign_id <> p_campaign_id THEN
    RAISE EXCEPTION 'invalid_transition' USING ERRCODE='P0001';
  END IF;
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id FOR UPDATE;
  SELECT id INTO v_run_id FROM service_runs
   WHERE work_item_id = w.id AND work_attempt = w.execution_attempt_count;

  IF jsonb_array_length(coalesce(p_payload->'businesses','[]')) > c.volume_cap THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE='P0001',
      DETAIL='businesses exceed volume_cap';
  END IF;

  UPDATE campaigns SET
    geo_lat = coalesce((p_payload->'geo'->>'lat')::float8, geo_lat),
    geo_lng = coalesce((p_payload->'geo'->>'lng')::float8, geo_lng),
    resolved_place_category = coalesce(p_payload->>'resolved_category', resolved_place_category),
    status = CASE WHEN requires_approval AND approval_status = 'pending'
                  THEN 'awaiting_approval' ELSE 'analyzing' END
  WHERE id = p_campaign_id;

  FOR b IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'businesses','[]')) LOOP
    INSERT INTO businesses (place_id, business_name, website_domain, phone_e164,
                            address, lat, lng, dedup_key, first_seen_campaign_id)
    VALUES (b->>'place_id', b->>'name', b->>'domain', b->>'phone_e164',
            b->>'address', (b->>'lat')::float8, (b->>'lng')::float8,
            b->>'dedup_key', p_campaign_id)
    ON CONFLICT (place_id) DO UPDATE SET
      business_name = EXCLUDED.business_name,
      website_domain = coalesce(EXCLUDED.website_domain, businesses.website_domain),
      phone_e164 = coalesce(EXCLUDED.phone_e164, businesses.phone_e164),
      address = coalesce(EXCLUDED.address, businesses.address),
      last_updated = now()
    RETURNING id, (xmax <> 0) INTO v_biz, v_redisc;

    INSERT INTO campaign_leads (campaign_id, business_id, rediscovered, priority)
    VALUES (p_campaign_id, v_biz, v_redisc, coalesce((b->>'priority')::int, 0))
    ON CONFLICT (campaign_id, business_id) DO NOTHING
    RETURNING id INTO v_lead;
    IF v_lead IS NULL THEN CONTINUE; END IF;   -- duplicate within payload
    v_count := v_count + 1;

    INSERT INTO campaign_business_snapshots
      (campaign_lead_id, business_name, website_domain, phone_e164, address, lat, lng)
    VALUES (v_lead, b->>'name', b->>'domain', b->>'phone_e164', b->>'address',
            (b->>'lat')::float8, (b->>'lng')::float8)
    ON CONFLICT (campaign_lead_id) DO NOTHING;

    FOR obs IN SELECT * FROM jsonb_array_elements(coalesce(b->'observations','[]')) LOOP
      INSERT INTO discovery_observations
        (campaign_lead_id, provider, query, geo_lat, geo_lng, radius_m, rank)
      VALUES (v_lead, obs->>'provider', obs->>'query',
        (obs->>'geo_lat')::float8, (obs->>'geo_lng')::float8,
        (obs->>'radius_m')::int, (obs->>'rank')::int);
    END LOOP;

    FOR ev IN SELECT * FROM jsonb_array_elements(coalesce(b->'evidence','[]')) LOOP
      SELECT * INTO ins FROM _insert_evidence(v_biz, p_campaign_id, 'discovery', v_run_id, ev);
    END LOOP;

    -- lead-scoped work-item graph with correct initial states, gated by
    -- service_config.enabled: a disabled service (no worker shipped yet — e.g.
    -- US1 has reviews/phone/enrichment/assets disabled) is created terminal
    -- (skipped_prerequisite) so the campaign can finalize without it. Enabling a
    -- service later is a one-row service_config flip; new campaigns pick it up.
    INSERT INTO work_items (scope_type, campaign_id, campaign_lead_id, service, state)
    SELECT 'lead', p_campaign_id, v_lead, sc.service,
      CASE
        WHEN NOT sc.enabled THEN 'skipped_prerequisite'
        WHEN sc.service = 'website' THEN
          CASE WHEN coalesce(b->>'domain','') = '' THEN 'skipped_prerequisite' ELSE 'pending' END
        WHEN sc.service = 'reviews' THEN 'pending'
        ELSE 'blocked'   -- phone, enrichment, assessment, social: unblocked by dependency/gate hooks
      END
    FROM service_config sc
    WHERE sc.service IN ('website','reviews','phone','enrichment','assessment','social','phone_probe')
    ON CONFLICT DO NOTHING;

    -- FRESHNESS CACHE: for a REDISCOVERED business, skip re-running the expensive
    -- analyzers when this business already has evidence for that service (from any
    -- OTHER campaign) observed within the freshness window — reuse it instead of
    -- re-paying the provider (window = 30 days). Copies the latest-per-feature evidence into this
    -- campaign and marks the analyzer work item done. Only touches enabled services
    -- (claimable states); phone (free, review-derived) runs normally off the reused
    -- reviews evidence, so its completion drives the assessment/dependency hooks.
    IF v_redisc THEN
      PERFORM _reuse_fresh_evidence(v_biz, p_campaign_id, v_lead, 'website',     interval '30 days');
      PERFORM _reuse_fresh_evidence(v_biz, p_campaign_id, v_lead, 'reviews',     interval '30 days');
      PERFORM _reuse_fresh_evidence(v_biz, p_campaign_id, v_lead, 'social',      interval '30 days');
      PERFORM _reuse_fresh_evidence(v_biz, p_campaign_id, v_lead, 'phone_probe', interval '30 days');
      -- website+reviews were cache-completed without going through complete_analysis,
      -- so resolve the phone dependency here (same rule complete_analysis uses).
      UPDATE work_items SET state = 'pending', available_at = now()
       WHERE campaign_lead_id = v_lead AND service = 'phone' AND state = 'blocked'
         AND NOT EXISTS (SELECT 1 FROM work_items s
              WHERE s.campaign_lead_id = v_lead AND s.service IN ('website','reviews')
                AND s.state NOT IN ('done','dead','skipped_gate','skipped_budget',
                                    'skipped_prerequisite','canceled'));
    END IF;

    -- Leads with NO runnable analyzer (e.g. no-website + reviews/phone disabled)
    -- would never see an analyzer completion, so their assessment would stay
    -- blocked forever. A missing website is itself the top redesign signal, so
    -- advance the revision on the discovery evidence: the discovery_evidence ->
    -- assessment impact rule unblocks + scores them off discovery alone. Leads
    -- with a runnable analyzer are left to score after that analyzer completes.
    IF NOT EXISTS (
      SELECT 1 FROM work_items a
       WHERE a.campaign_lead_id = v_lead AND a.service IN ('website','reviews','phone')
         AND a.state NOT IN ('done','dead','skipped_gate','skipped_budget',
                             'skipped_prerequisite','canceled')
    ) THEN
      PERFORM advance_lead_revision(v_lead, 'discovery_evidence');
    END IF;
  END LOOP;

  -- typed relationships (second pass, after all businesses exist)
  FOR b IN SELECT * FROM jsonb_array_elements(coalesce(p_payload->'businesses','[]')) LOOP
    SELECT id INTO v_biz FROM businesses WHERE place_id = b->>'place_id';
    FOR rel IN SELECT * FROM jsonb_array_elements(coalesce(b->'relationships','[]')) LOOP
      SELECT id INTO v_related FROM businesses WHERE place_id = rel->>'related_place_id';
      IF v_related IS NOT NULL AND v_related <> v_biz THEN
        INSERT INTO business_relationships
          (business_id, related_business_id, relationship_type, confidence, sales_target_level)
        VALUES (v_biz, v_related, coalesce(rel->>'type','unknown'),
          coalesce((rel->>'confidence')::numeric, 0.5),
          coalesce(rel->>'target_level','location'))
        ON CONFLICT DO NOTHING;
      END IF;
    END LOOP;
  END LOOP;

  PERFORM _emit_event('discovery.committed','state_change', true, p_campaign_id, 0,
    jsonb_build_object('leads', v_count, 'business_type', c.business_type),
    'discovery.committed:' || p_campaign_id);

  v_state := _finish_work_item(w, 'succeeded', p_payload->'run');
  RETURN jsonb_build_object('result', v_state, 'leads_created', v_count);
END $$;

-- ---------------------------------------------------------------------------
-- cancel_campaign: pending work canceled; running tokens invalidated (their
-- completions fence-fail); settlement stays possible; spend history preserved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION @@SCHEMA@@.cancel_campaign(p_campaign_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, @@SCHEMA@@ AS $$
DECLARE c campaigns; v_n int;
BEGIN
  SELECT * INTO c FROM campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown_campaign' USING ERRCODE='P0001'; END IF;
  IF c.status IN ('complete','failed','canceled') THEN
    RETURN jsonb_build_object('status','already_terminal','campaign_status', c.status);
  END IF;
  UPDATE campaigns SET status = 'canceled',
    completed_at = now(), completion_reason = 'canceled',
    campaign_state_revision = campaign_state_revision + 1
  WHERE id = p_campaign_id;

  UPDATE work_items SET
    state = 'canceled', claim_token = NULL, lease_expires_at = NULL
  WHERE campaign_id = p_campaign_id
    AND state IN ('blocked','pending','failed_retryable','waiting_approval','running');
  GET DIAGNOSTICS v_n = ROW_COUNT;

  PERFORM _emit_event('campaign.completed','state_change', false, p_campaign_id, NULL,
    jsonb_build_object('reason','canceled'), 'campaign.canceled:' || p_campaign_id);
  RETURN jsonb_build_object('status','canceled','work_items_canceled', v_n);
END $$;
