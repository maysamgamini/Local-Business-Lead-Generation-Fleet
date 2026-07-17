-- 090_indexes_constraints_views.sql (T016)
-- Cross-file + circular FKs (deferred here so table order never matters),
-- contracted views, healthcheck() — both namespaces.
-- FK idempotency: DROP CONSTRAINT IF EXISTS then ADD (safe on re-run).

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

-- ===== Cross-file / circular foreign keys =====
ALTER TABLE %1$I.campaigns DROP CONSTRAINT IF EXISTS fk_campaigns_scoring_set;
ALTER TABLE %1$I.campaigns ADD CONSTRAINT fk_campaigns_scoring_set
  FOREIGN KEY (scoring_config_set_id) REFERENCES %1$I.config_sets(id);
ALTER TABLE %1$I.campaigns DROP CONSTRAINT IF EXISTS fk_campaigns_chain_set;
ALTER TABLE %1$I.campaigns ADD CONSTRAINT fk_campaigns_chain_set
  FOREIGN KEY (chain_rule_set_id) REFERENCES %1$I.config_sets(id);
ALTER TABLE %1$I.campaigns DROP CONSTRAINT IF EXISTS fk_campaigns_vertical_set;
ALTER TABLE %1$I.campaigns ADD CONSTRAINT fk_campaigns_vertical_set
  FOREIGN KEY (vertical_policy_set_id) REFERENCES %1$I.config_sets(id);
ALTER TABLE %1$I.campaigns DROP CONSTRAINT IF EXISTS fk_campaigns_model_set;
ALTER TABLE %1$I.campaigns ADD CONSTRAINT fk_campaigns_model_set
  FOREIGN KEY (model_policy_set_id) REFERENCES %1$I.config_sets(id);
ALTER TABLE %1$I.campaigns DROP CONSTRAINT IF EXISTS fk_campaigns_service_set;
ALTER TABLE %1$I.campaigns ADD CONSTRAINT fk_campaigns_service_set
  FOREIGN KEY (service_policy_set_id) REFERENCES %1$I.config_sets(id);

ALTER TABLE %1$I.campaign_leads DROP CONSTRAINT IF EXISTS fk_leads_latest_assessment;
ALTER TABLE %1$I.campaign_leads ADD CONSTRAINT fk_leads_latest_assessment
  FOREIGN KEY (latest_assessment_id) REFERENCES %1$I.lead_assessments(id);
ALTER TABLE %1$I.businesses DROP CONSTRAINT IF EXISTS fk_businesses_latest_assessment;
ALTER TABLE %1$I.businesses ADD CONSTRAINT fk_businesses_latest_assessment
  FOREIGN KEY (latest_assessment_id) REFERENCES %1$I.lead_assessments(id);
ALTER TABLE %1$I.campaign_business_snapshots DROP CONSTRAINT IF EXISTS fk_snapshots_lead;
ALTER TABLE %1$I.campaign_business_snapshots ADD CONSTRAINT fk_snapshots_lead
  FOREIGN KEY (campaign_lead_id) REFERENCES %1$I.campaign_leads(id);
ALTER TABLE %1$I.business_relationships DROP CONSTRAINT IF EXISTS fk_rel_evidence;
ALTER TABLE %1$I.business_relationships ADD CONSTRAINT fk_rel_evidence
  FOREIGN KEY (evidence_id) REFERENCES %1$I.evidence_items(id);
ALTER TABLE %1$I.chain_rules DROP CONSTRAINT IF EXISTS fk_chain_rules_set;
ALTER TABLE %1$I.chain_rules ADD CONSTRAINT fk_chain_rules_set
  FOREIGN KEY (config_set_id) REFERENCES %1$I.config_sets(id);
ALTER TABLE %1$I.work_items DROP CONSTRAINT IF EXISTS fk_work_gate_assessment;
ALTER TABLE %1$I.work_items ADD CONSTRAINT fk_work_gate_assessment
  FOREIGN KEY (gate_assessment_id) REFERENCES %1$I.lead_assessments(id);

-- ===== Contracted views =====
CREATE OR REPLACE VIEW %1$I.stuck_work_overview AS
SELECT w.id, w.scope_type, w.campaign_id, w.campaign_lead_id, w.service, w.state,
       w.available_at, w.lease_expires_at, w.retryable_failure_count,
       w.provider_deferral_count, w.error_code,
       now() - w.lease_expires_at AS lease_overdue_by
FROM %1$I.work_items w
WHERE (w.state = 'running' AND w.lease_expires_at < now())
   OR (w.state = 'failed_retryable' AND w.available_at < now() - interval '15 minutes')
   OR (w.state IN ('blocked','pending','waiting_approval')
       AND w.created_at < now() - interval '24 hours');

CREATE OR REPLACE VIEW %1$I.campaign_progress AS
SELECT c.id AS campaign_id, c.status, c.budget_state, c.quality_state,
       c.business_type, c.created_at,
       count(cl.id)                                            AS leads,
       count(*) FILTER (WHERE cl.classification = 'hot')       AS hot,
       count(*) FILTER (WHERE cl.hot_candidate
                          AND coalesce(cl.classification,'') <> 'hot') AS hot_candidates,
       count(w.id) FILTER (WHERE w.state IN
         ('done','dead','skipped_gate','skipped_budget','skipped_prerequisite','canceled'))
                                                               AS work_terminal,
       count(w.id)                                             AS work_total,
       coalesce(sum(bt.actual_usd) FILTER (WHERE bt.state = 'settled'), 0)          AS spent_usd,
       coalesce(sum(bt.maximum_billable_usd) FILTER (WHERE bt.state = 'reserved'), 0) AS reserved_usd
FROM %1$I.campaigns c
LEFT JOIN %1$I.campaign_leads cl ON cl.campaign_id = c.id
LEFT JOIN %1$I.work_items w      ON w.campaign_id = c.id
LEFT JOIN %1$I.budget_transactions bt ON bt.campaign_id = c.id
GROUP BY c.id;

-- ===== healthcheck() =====
CREATE OR REPLACE FUNCTION %1$I.healthcheck() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, %1$I AS $fn$
DECLARE
  v_tables int; v_functions int; v_active_sets int; v_dml_leaks int;
BEGIN
  SELECT count(*) INTO v_tables FROM information_schema.tables
   WHERE table_schema = %1$L AND table_type = 'BASE TABLE';
  SELECT count(*) INTO v_functions FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = %1$L;
  SELECT count(DISTINCT config_type) INTO v_active_sets
   FROM config_sets WHERE activated_at IS NOT NULL AND retired_at IS NULL;
  -- privilege audit: workflow roles must hold no direct DML on protected tables
  SELECT count(*) INTO v_dml_leaks FROM information_schema.role_table_grants
   WHERE table_schema = %1$L
     AND grantee LIKE 'leadgen_%%'
     AND grantee NOT IN ('leadgen_human','leadgen_human_dryrun')
     AND privilege_type IN ('INSERT','UPDATE','DELETE');
  RETURN jsonb_build_object(
    'schema', %1$L,
    'tables', v_tables,
    'functions', v_functions,
    'active_config_types', v_active_sets,
    'expected_config_types', 5,
    'direct_dml_grants_to_workflow_roles', v_dml_leaks,
    'ok', v_tables >= 28 AND v_active_sets = 5 AND v_dml_leaks = 0,
    'checked_at', now());
END $fn$;

$ddl$, ns);
END LOOP;
END $mig$;
