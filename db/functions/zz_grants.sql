-- zz_grants.sql (T027, part 2: function grants)
-- Deployed LAST in the functions pass (zz_ prefix), once per namespace.
-- PUBLIC loses execute on everything; each role gets exactly its API surface.
-- leadgen_relay doubles as the EDGE role: intake workflows (create_campaign)
-- and the Event Relay share it.

DO $g$
DECLARE
  sfx text := CASE WHEN '@@SCHEMA@@' = 'leadgen_dryrun' THEN '_dryrun' ELSE '' END;
  fn record;
BEGIN
  -- strip default PUBLIC execute from every function in the namespace
  FOR fn IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = '@@SCHEMA@@' LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', fn.sig);
  END LOOP;

  -- helper to keep grants terse
  -- analyzers: discovery + website/reviews/phone workers
  EXECUTE format($f$
    GRANT EXECUTE ON FUNCTION
      @@SCHEMA@@.claim_work_items(text,text),
      @@SCHEMA@@.renew_lease(uuid,uuid),
      @@SCHEMA@@.complete_analysis_work_item(uuid,uuid,jsonb),
      @@SCHEMA@@.commit_discovery_results(uuid,uuid,uuid,jsonb),
      @@SCHEMA@@.fail_work_item(uuid,uuid,text,text),
      @@SCHEMA@@.defer_work_item(uuid,uuid,timestamptz,text),
      @@SCHEMA@@.authorize_paid_operation(uuid,uuid,uuid,text,text,text,numeric,text),
      @@SCHEMA@@.settle_paid_operation(uuid,uuid,numeric,text),
      @@SCHEMA@@.release_paid_operation(uuid,uuid),
      @@SCHEMA@@.renew_provider_permit(uuid,uuid)
    TO %I $f$, 'leadgen_analyzer' || sfx);

  -- scorer
  EXECUTE format($f$
    GRANT EXECUTE ON FUNCTION
      @@SCHEMA@@.claim_work_items(text,text),
      @@SCHEMA@@.renew_lease(uuid,uuid),
      @@SCHEMA@@.complete_scorer_work_item(uuid,uuid,jsonb),
      @@SCHEMA@@.fail_work_item(uuid,uuid,text,text),
      @@SCHEMA@@.defer_work_item(uuid,uuid,timestamptz,text),
      @@SCHEMA@@.authorize_paid_operation(uuid,uuid,uuid,text,text,text,numeric,text),
      @@SCHEMA@@.settle_paid_operation(uuid,uuid,numeric,text),
      @@SCHEMA@@.release_paid_operation(uuid,uuid),
      @@SCHEMA@@.renew_provider_permit(uuid,uuid)
    TO %I $f$, 'leadgen_scorer' || sfx);

  -- enricher: gated authorization ONLY (no ungated spend path)
  EXECUTE format($f$
    GRANT EXECUTE ON FUNCTION
      @@SCHEMA@@.claim_work_items(text,text),
      @@SCHEMA@@.renew_lease(uuid,uuid),
      @@SCHEMA@@.complete_enrichment_work_item(uuid,uuid,jsonb),
      @@SCHEMA@@.fail_work_item(uuid,uuid,text,text),
      @@SCHEMA@@.defer_work_item(uuid,uuid,timestamptz,text),
      @@SCHEMA@@.authorize_enrichment_operation(uuid,uuid,uuid,text,text,text,numeric,text,numeric,text),
      @@SCHEMA@@.settle_paid_operation(uuid,uuid,numeric,text),
      @@SCHEMA@@.release_paid_operation(uuid,uuid),
      @@SCHEMA@@.renew_provider_permit(uuid,uuid)
    TO %I $f$, 'leadgen_enricher' || sfx);

  -- sweeper: engines + finalization + token issuance + health
  EXECUTE format($f$
    GRANT EXECUTE ON FUNCTION
      @@SCHEMA@@.reap_expired_leases(),
      @@SCHEMA@@.requeue_retryable_work(integer),
      @@SCHEMA@@.requeue_stale_assessments(),
      @@SCHEMA@@.reconcile_expired_reservations(),
      @@SCHEMA@@.begin_campaign_finalization(uuid),
      @@SCHEMA@@.complete_campaign_finalization(uuid,uuid,bigint,jsonb),
      @@SCHEMA@@.abort_campaign_finalization(uuid,uuid,text),
      @@SCHEMA@@.issue_approval_token(uuid,text,text,interval),
      @@SCHEMA@@.healthcheck()
    TO %I $f$, 'leadgen_sweeper' || sfx);

  -- relay (transport + edge): outbox engine + intake entry
  EXECUTE format($f$
    GRANT EXECUTE ON FUNCTION
      @@SCHEMA@@.claim_outbox_deliveries(text,text,integer),
      @@SCHEMA@@.complete_outbox_delivery(uuid,uuid,text,text),
      @@SCHEMA@@.fail_outbox_delivery(uuid,uuid,text,integer),
      @@SCHEMA@@.create_campaign(jsonb,uuid,text),
      @@SCHEMA@@.issue_approval_token(uuid,text,text,interval),
      @@SCHEMA@@.evaluate_chain_rules(uuid,text,bigint)
    TO %I $f$, 'leadgen_relay' || sfx);

  -- human actions
  EXECUTE format($f$
    GRANT EXECUTE ON FUNCTION
      @@SCHEMA@@.record_approval(text,text),
      @@SCHEMA@@.record_sales_status(uuid,text,text,text),
      @@SCHEMA@@.record_lead_disposition(uuid,text,text,text),
      @@SCHEMA@@.record_suppression(text,text,text,text),
      @@SCHEMA@@.cancel_campaign(uuid)
    TO %I $f$, 'leadgen_human' || sfx);

  -- dashboard: healthcheck only (tables already SELECT-granted)
  EXECUTE format('GRANT EXECUTE ON FUNCTION @@SCHEMA@@.healthcheck() TO %I',
                 'leadgen_dashboard' || sfx);
END $g$;
