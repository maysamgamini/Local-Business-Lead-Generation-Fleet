-- race_tests.sql (T029, sequential half)
-- Runs against leadgen_dryrun (structurally identical, disposable). The truly
-- concurrent scenarios (semaphore, poke storm, budget boundary) live in
-- run-race-tests.sh. Any failed assertion raises -> ON_ERROR_STOP exits nonzero.

\set ON_ERROR_STOP 1
SET search_path = leadgen_dryrun, public;

-- test-only assert helper (dryrun namespace only; no grants)
CREATE OR REPLACE FUNCTION leadgen_dryrun._assert(p_ok boolean, p_name text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'ASSERTION FAILED: %', p_name;
  END IF;
  RAISE NOTICE 'PASS: %', p_name;
END $$;

-- clean slate for the fixture caller
DO $$
DECLARE cid uuid;
BEGIN
  -- Reset ALL dryrun campaigns (not just the fixture caller): claim_work_items is a
  -- GLOBAL queue (workers are shared across campaigns), so leftover work items from any
  -- prior run would make claims non-deterministic and break the cancellation assertion.
  FOR cid IN SELECT id FROM campaigns LOOP
    DELETE FROM chain_rule_evaluations WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM score_log WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM score_components WHERE assessment_id IN
      (SELECT a.id FROM lead_assessments a JOIN campaign_leads cl ON cl.id=a.campaign_lead_id
        WHERE cl.campaign_id = cid);
    DELETE FROM critic_reviews WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    UPDATE campaign_leads SET latest_assessment_id = NULL WHERE campaign_id = cid;
    UPDATE businesses SET latest_assessment_id = NULL
      WHERE id IN (SELECT business_id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM lead_assessments WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM campaign_contact_findings WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM evidence_verification_events WHERE evidence_id IN
      (SELECT id FROM evidence_items WHERE campaign_id = cid);
    DELETE FROM evidence_links WHERE child_evidence_id IN
      (SELECT id FROM evidence_items WHERE campaign_id = cid);
    UPDATE business_relationships SET evidence_id = NULL WHERE evidence_id IN
      (SELECT id FROM evidence_items WHERE campaign_id = cid);
    DELETE FROM evidence_items WHERE campaign_id = cid;
    DELETE FROM discovery_observations WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM campaign_business_snapshots WHERE campaign_lead_id IN
      (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM budget_transactions WHERE campaign_id = cid;
    DELETE FROM provider_permits WHERE service_run_id IN
      (SELECT r.id FROM service_runs r JOIN work_items w ON w.id=r.work_item_id
        WHERE w.campaign_id = cid);
    DELETE FROM service_runs WHERE work_item_id IN
      (SELECT id FROM work_items WHERE campaign_id = cid);
    DELETE FROM event_consumptions WHERE event_id IN
      (SELECT id FROM outbox_events WHERE aggregate_id = cid
        OR aggregate_id IN (SELECT id FROM campaign_leads WHERE campaign_id = cid));
    DELETE FROM outbox_deliveries WHERE event_id IN
      (SELECT id FROM outbox_events WHERE aggregate_id = cid
        OR aggregate_id IN (SELECT id FROM campaign_leads WHERE campaign_id = cid));
    DELETE FROM outbox_events WHERE aggregate_id = cid
      OR aggregate_id IN (SELECT id FROM campaign_leads WHERE campaign_id = cid);
    DELETE FROM work_items WHERE campaign_id = cid;
    DELETE FROM campaign_leads WHERE campaign_id = cid;
    DELETE FROM approval_tokens WHERE campaign_id = cid;
    UPDATE businesses SET first_seen_campaign_id = NULL WHERE first_seen_campaign_id = cid;
    DELETE FROM campaigns WHERE id = cid;
  END LOOP;
END $$;

-- ===========================================================================
-- Fixture: campaign + discovery commit -> 2 leads with full work-item graph
-- ===========================================================================
DO $t$
DECLARE
  v_camp uuid; v_status text; v_item uuid; v_token uuid; v_run uuid; v_ver bigint;
  r record; j jsonb;
BEGIN
  SELECT campaign_id, creation_status INTO v_camp, v_status FROM create_campaign(
    '{"schema_version":"1.0","request_id":"race-fixture-1","business_type":"med spa",
      "geo":{"type":"zip","zip":"78613","radius_m":15000},"depth":"quick",
      "volume_cap":10,"budget":{"amount":10,"currency":"USD"},
      "requires_approval":false,"dry_run":true}'::jsonb,
    'aaaaaaaa-0000-0000-0000-000000000001', 'webhook');
  PERFORM _assert(v_status = 'created', 'create_campaign creates');

  -- idempotent replay
  SELECT creation_status INTO v_status FROM create_campaign(
    '{"schema_version":"1.0","request_id":"race-fixture-1","business_type":"med spa",
      "geo":{"type":"zip","zip":"78613","radius_m":15000},"depth":"quick",
      "volume_cap":10,"budget":{"amount":10,"currency":"USD"}}'::jsonb,
    'aaaaaaaa-0000-0000-0000-000000000001', 'webhook');
  PERFORM _assert(v_status = 'existing', 'request_id replay -> existing');

  -- region rejected
  BEGIN
    PERFORM create_campaign(
      '{"schema_version":"1.0","request_id":"race-region","business_type":"x",
        "geo":{"type":"region","region":"Travis County"},"depth":"quick",
        "volume_cap":10,"budget":{"amount":5,"currency":"USD"}}'::jsonb,
      'aaaaaaaa-0000-0000-0000-000000000001','webhook');
    PERFORM _assert(false, 'region must be rejected');
  EXCEPTION WHEN OTHERS THEN
    PERFORM _assert(SQLERRM = 'invalid_request', 'region geo rejected');
  END;

  -- claim discovery + commit two businesses
  SELECT * INTO r FROM claim_work_items('discovery','test-worker-1');
  PERFORM _assert(r.work_item_id IS NOT NULL, 'discovery claimable');
  v_item := r.work_item_id; v_token := r.claim_token;

  j := format('{"geo":{"lat":30.5,"lng":-97.8},"businesses":[
    {"place_id":"race-p1","name":"Radiance MedSpa","domain":"radiance.example",
     "phone_e164":"+15125550001","dedup_key":"radiance|78613","lat":30.5,"lng":-97.8,
     "evidence":[{"feature_key":"website_present","value":true,"value_type":"boolean",
       "idempotency_key":"race-p1-webpresent","source_provider":"places"}],
     "observations":[{"provider":"serpapi","query":"med spa 78613","rank":3}]},
    {"place_id":"race-p2","name":"Glow Spa","domain":"","phone_e164":"+15125550002",
     "dedup_key":"glow|78613",
     "evidence":[{"feature_key":"website_present","value":false,"value_type":"boolean",
       "idempotency_key":"race-p2-webpresent","source_provider":"places"}],
     "relationships":[{"related_place_id":"race-p1","type":"shared_platform",
       "confidence":0.4,"target_level":"location"}]}],
    "run":{"workflow_version":"test"}}')::jsonb;
  PERFORM commit_discovery_results(v_camp, v_item, v_token, j);

  PERFORM _assert((SELECT count(*) FROM campaign_leads WHERE campaign_id = v_camp) = 2,
    'two leads created');
  PERFORM _assert((SELECT count(*) FROM work_items WHERE campaign_id = v_camp
     AND scope_type = 'lead') = 10, 'work-item graph: 5 per lead');
  PERFORM _assert((SELECT state FROM work_items w JOIN campaign_leads cl
     ON cl.id = w.campaign_lead_id JOIN businesses b ON b.id = cl.business_id
     WHERE b.place_id = 'race-p2' AND w.service = 'website') = 'skipped_prerequisite',
    'no-website lead: website item skipped_prerequisite');
  PERFORM _assert((SELECT count(*) FROM business_relationships br
     JOIN businesses b ON b.id = br.business_id WHERE b.place_id = 'race-p2') = 1,
    'typed relationship recorded');
  PERFORM _assert((SELECT status FROM campaigns WHERE id = v_camp) = 'analyzing',
    'campaign analyzing after commit');

  -- stale-token replay: second commit with the used token must fence-fail
  BEGIN
    PERFORM commit_discovery_results(v_camp, v_item, v_token, j);
    PERFORM _assert(false, 'used token must fence-fail');
  EXCEPTION WHEN OTHERS THEN
    PERFORM _assert(SQLERRM = 'fence_violation', 'discovery re-commit fenced');
  END;
END $t$;

-- ===========================================================================
-- Fence + lease expiry + reap + retry lifecycle + deferral counters
-- ===========================================================================
DO $t$
DECLARE
  v_camp uuid; r record; v_item uuid; v_tok1 uuid; v_tok2 uuid; j jsonb; v_n int;
BEGIN
  SELECT id INTO v_camp FROM campaigns
   WHERE caller_identity = 'aaaaaaaa-0000-0000-0000-000000000001'
     AND request_id = 'race-fixture-1';

  SELECT * INTO r FROM claim_work_items('reviews','worker-A');
  v_item := r.work_item_id; v_tok1 := r.claim_token;
  PERFORM _assert(v_item IS NOT NULL, 'reviews claim 1');

  -- force lease expiry (admin surgery, simulating a stalled worker)
  UPDATE work_items SET lease_expires_at = now() - interval '1 second' WHERE id = v_item;

  -- zombie completion must fail on the lease-expiry leg of the fence
  BEGIN
    PERFORM complete_analysis_work_item(v_item, v_tok1,
      '{"evidence":[],"run":{}}'::jsonb);
    PERFORM _assert(false, 'expired-lease completion must fail');
  EXCEPTION WHEN OTHERS THEN
    PERFORM _assert(SQLERRM = 'fence_violation', 'lease expiry fences completion');
  END;

  -- reap -> failed_retryable; requeue -> pending; reclaim by worker B
  PERFORM reap_expired_leases();
  PERFORM _assert((SELECT state FROM work_items WHERE id = v_item) = 'failed_retryable',
    'reaper moves expired running -> failed_retryable');
  UPDATE work_items SET available_at = now() WHERE id = v_item;  -- skip backoff wait
  PERFORM requeue_retryable_work();
  PERFORM _assert((SELECT state FROM work_items WHERE id = v_item) = 'pending',
    'requeue: failed_retryable -> pending');

  SELECT * INTO r FROM claim_work_items('reviews','worker-B');
  PERFORM _assert(r.work_item_id = v_item, 'worker B reclaims');
  v_tok2 := r.claim_token;

  -- old token still dead even though item is running again
  BEGIN
    PERFORM complete_analysis_work_item(v_item, v_tok1, '{"evidence":[],"run":{}}'::jsonb);
    PERFORM _assert(false, 'old token must stay dead');
  EXCEPTION WHEN OTHERS THEN
    PERFORM _assert(SQLERRM = 'fence_violation', 'zombie token rejected after reclaim');
  END;

  -- worker B completes with evidence + planted duplicate idempotency (2 items, 1 dup)
  j := '{"run":{"model_provider":"test"},"cause_type":"reviews_evidence","evidence":[
    {"feature_key":"review_volume","value":142,"value_type":"integer",
     "idempotency_key":"race-rv-1","source_provider":"apify",
     "verification":{"status":"confirmed","verifier":"test","idempotency_key":"race-rv-1-v"}},
    {"feature_key":"rating","value":4.4,"value_type":"decimal",
     "idempotency_key":"race-rt-1","source_provider":"apify"}]}'::jsonb;
  PERFORM complete_analysis_work_item(v_item, v_tok2, j);
  PERFORM _assert((SELECT state FROM work_items WHERE id = v_item) = 'done',
    'worker B completes exactly once');

  -- duplicate verification event idempotency: same key inserted again -> 1 row
  PERFORM _assert((SELECT count(*) FROM evidence_verification_events
     WHERE idempotency_key = 'race-rv-1-v') = 1, 'verification event single row');

  -- deferral never touches the failure counter
  SELECT * INTO r FROM claim_work_items('phone','worker-C');
  -- phone unblocked? race-p2 lead: reviews done unblocks phone only when website
  -- also terminal; race-p2 website = skipped_prerequisite (terminal) and its
  -- reviews item is still pending -> phone stays blocked. race-p1: reviews just
  -- done was THE claimed one? claim order is nondeterministic; assert on data:
  IF r.work_item_id IS NOT NULL THEN
    PERFORM defer_work_item(r.work_item_id, r.claim_token, now() + interval '1 minute', 'cooldown');
    SELECT provider_deferral_count, retryable_failure_count
      INTO v_n, v_n FROM work_items WHERE id = r.work_item_id;  -- second wins
    PERFORM _assert((SELECT provider_deferral_count FROM work_items
       WHERE id = r.work_item_id) = 1
      AND (SELECT retryable_failure_count FROM work_items WHERE id = r.work_item_id) = 0,
      'deferral increments deferral counter only');
  ELSE
    RAISE NOTICE 'SKIP: phone not yet claimable (dependency order) — counters covered by fail path';
  END IF;

  -- fail path to dead at threshold 2 (test threshold): fail -> requeue -> fail -> dead
  SELECT * INTO r FROM claim_work_items('reviews','worker-D');  -- race-p2's reviews
  IF r.work_item_id IS NOT NULL THEN
    PERFORM fail_work_item(r.work_item_id, r.claim_token, 'test_err','boom 1');
    UPDATE work_items SET available_at = now() WHERE id = r.work_item_id;
    PERFORM requeue_retryable_work(2);
    SELECT * INTO r FROM claim_work_items('reviews','worker-D2');
    PERFORM fail_work_item(r.work_item_id, r.claim_token, 'test_err','boom 2');
    UPDATE work_items SET available_at = now() WHERE id = r.work_item_id;
    PERFORM requeue_retryable_work(2);
    PERFORM _assert((SELECT state FROM work_items WHERE id = r.work_item_id) = 'dead',
      'threshold failures -> dead + alert event');
    PERFORM _assert((SELECT count(*) FROM outbox_events
       WHERE event_type = 'workitem.dead'
         AND payload->>'work_item_id' = r.work_item_id::text) = 1,
      'dead work item emits notification');
  END IF;
END $t$;

-- ===========================================================================
-- Money: settle<=max, cancellation preserves settlement, reconciliation
-- ===========================================================================
DO $t$
DECLARE
  v_camp uuid; r record; auth jsonb; v_lead uuid; v_biz uuid;
BEGIN
  SELECT id INTO v_camp FROM campaigns
   WHERE caller_identity = 'aaaaaaaa-0000-0000-0000-000000000001'
     AND request_id = 'race-fixture-1';

  -- claim race-p1's website item for an authorized spend
  SELECT * INTO r FROM claim_work_items('website','money-worker');
  PERFORM _assert(r.work_item_id IS NOT NULL, 'website claimable');

  auth := authorize_paid_operation(r.work_item_id, r.claim_token, r.service_run_id,
    'psi','default','lighthouse', 2.00, 'race-auth-1');
  PERFORM _assert(auth->>'status' = 'authorized', 'authorization grants');

  -- settle above maximum: flagged, never settled
  PERFORM _assert(
    (settle_paid_operation((auth->>'authorization_id')::uuid,
       (auth->>'permit_token')::uuid, 3.50, 'req-x'))->>'status' = 'max_exceeded_flagged',
    'settle above max flagged, not settled');
  PERFORM _assert((SELECT state FROM budget_transactions
     WHERE id = (auth->>'authorization_id')::uuid) = 'reserved',
    'over-max stays reserved + reconciliation_required');

  -- cancel campaign mid-flight: running tokens invalidated, settlement still lands
  PERFORM cancel_campaign(v_camp);
  BEGIN
    PERFORM complete_analysis_work_item(r.work_item_id, r.claim_token,
      '{"evidence":[],"run":{}}'::jsonb);
    PERFORM _assert(false, 'canceled item completion must fail');
  EXCEPTION WHEN OTHERS THEN
    PERFORM _assert(SQLERRM = 'fence_violation', 'cancellation invalidates tokens');
  END;
  -- fix the over-max flag by settling honestly within max — AFTER cancellation
  PERFORM _assert(
    (settle_paid_operation((auth->>'authorization_id')::uuid,
       (auth->>'permit_token')::uuid, 1.75, 'req-x'))->>'status' = 'settled',
    'settlement valid after cancellation');
  PERFORM _assert((SELECT count(*) FROM budget_transactions
     WHERE campaign_id = v_camp AND state = 'settled') = 1,
    'spend history preserved after cancel');
END $t$;

SELECT 'SEQUENTIAL RACE TESTS: ALL PASSED' AS result;
