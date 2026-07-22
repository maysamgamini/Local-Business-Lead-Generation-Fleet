-- zz_worker_consolidation.sql
-- v1 role simplification: the single n8n Postgres credential ('Postgres account')
-- connects as leadgen_relay. Grant it the full WORKER function surface so all
-- worker workflows (Discovery, analyzers, Scorer, Enricher, Sweeper, Event Relay,
-- Intake) run under one credential.
--
-- PRESERVED boundaries (the ones that matter): no direct DML on protected tables;
-- human-action functions (record_approval / record_sales_status /
-- record_lead_disposition / record_suppression / cancel_campaign) stay on
-- leadgen_human ONLY; config admin (activate_config_set) stays admin-only;
-- dashboard role stays read-only. The per-role worker split (analyzer vs scorer
-- vs enricher vs sweeper) collapses to one worker role for v1 — the work-item
-- fence + per-service checks inside the functions still prevent completing the
-- wrong service's item, so this is defense-in-depth relaxation, not a hole.
-- Deployed after zz_grants.sql (zz_ ordering); rendered per namespace.

GRANT EXECUTE ON FUNCTION
  @@SCHEMA@@.claim_work_items(text,text),
  @@SCHEMA@@.renew_lease(uuid,uuid),
  @@SCHEMA@@.complete_analysis_work_item(uuid,uuid,jsonb),
  @@SCHEMA@@.complete_scorer_work_item(uuid,uuid,jsonb),
  @@SCHEMA@@.complete_enrichment_work_item(uuid,uuid,jsonb),
  @@SCHEMA@@.commit_discovery_results(uuid,uuid,uuid,jsonb),
  @@SCHEMA@@.fail_work_item(uuid,uuid,text,text),
  @@SCHEMA@@.defer_work_item(uuid,uuid,timestamptz,text),
  @@SCHEMA@@.authorize_paid_operation(uuid,uuid,uuid,text,text,text,numeric,text),
  @@SCHEMA@@.authorize_enrichment_operation(uuid,uuid,uuid,text,text,text,numeric,text,numeric,text),
  @@SCHEMA@@.settle_paid_operation(uuid,uuid,numeric,text),
  @@SCHEMA@@.release_paid_operation(uuid,uuid),
  @@SCHEMA@@.renew_provider_permit(uuid,uuid),
  @@SCHEMA@@.reap_expired_leases(),
  @@SCHEMA@@.requeue_retryable_work(integer),
  @@SCHEMA@@.requeue_stale_assessments(),
  @@SCHEMA@@.skip_disabled_service_work(),
  @@SCHEMA@@.reconcile_blocked_dependencies(),
  @@SCHEMA@@.record_lead_report(uuid,text,text,text,text,text),
  @@SCHEMA@@.record_lead_report_v2(uuid,text,text,text,text,text,uuid,jsonb,text,text,jsonb,text),
  @@SCHEMA@@.reconcile_expired_reservations(),
  @@SCHEMA@@.begin_campaign_finalization(uuid),
  @@SCHEMA@@.complete_campaign_finalization(uuid,uuid,bigint,jsonb),
  @@SCHEMA@@.abort_campaign_finalization(uuid,uuid,text)
TO @@RELAY@@;
