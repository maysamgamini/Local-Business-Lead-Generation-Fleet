-- 030_work_queue.sql (T010)
-- work_items (campaign|lead scope, lease+fence, 3-version coalescing, 3 counters,
-- gate provenance), service_runs, revision_impact_rules — both namespaces.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

CREATE TABLE IF NOT EXISTS %1$I.work_items (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope_type               text NOT NULL CHECK (scope_type IN ('campaign','lead')),
  campaign_id              uuid NOT NULL REFERENCES %1$I.campaigns(id),
  campaign_lead_id         uuid REFERENCES %1$I.campaign_leads(id),
  service                  text NOT NULL CHECK (service IN
                             ('discovery','website','reviews','phone','enrichment','assessment','assets')),
  state                    text NOT NULL DEFAULT 'pending' CHECK (state IN
                             ('blocked','pending','running','failed_retryable','waiting_approval',
                              'done','dead','skipped_gate','skipped_budget','skipped_prerequisite','canceled')),
  priority                 integer NOT NULL DEFAULT 0,
  available_at             timestamptz NOT NULL DEFAULT now(),
  -- three separate counters: deferrals are never failures
  execution_attempt_count  integer NOT NULL DEFAULT 0 CHECK (execution_attempt_count >= 0),
  provider_deferral_count  integer NOT NULL DEFAULT 0 CHECK (provider_deferral_count >= 0),
  retryable_failure_count  integer NOT NULL DEFAULT 0 CHECK (retryable_failure_count >= 0),
  -- lease + fence
  claimed_at               timestamptz,
  lease_expires_at         timestamptz,
  claim_token              uuid,
  worker_id                text,
  -- version coalescing (requested>=processing>=completed enforced by functions)
  requested_version        bigint NOT NULL DEFAULT 0,
  processing_version       bigint NOT NULL DEFAULT 0,
  completed_version        bigint NOT NULL DEFAULT 0,
  -- enrichment gate provenance (recorded by authorize_enrichment_operation)
  gate_assessment_id       uuid,
  gate_revision            bigint,
  gate_threshold_version   text,
  error_code               text,
  error_detail             text,
  completed_at             timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  -- scope integrity: campaign-scoped rows have no lead; lead-scoped have both
  CONSTRAINT work_items_scope_chk CHECK (
    (scope_type = 'campaign' AND campaign_id IS NOT NULL AND campaign_lead_id IS NULL) OR
    (scope_type = 'lead'     AND campaign_id IS NOT NULL AND campaign_lead_id IS NOT NULL))
);

-- Partial uniques: a plain UNIQUE over nullable campaign_lead_id would not
-- prevent duplicate campaign-scoped rows (review round 5, finding 5).
CREATE UNIQUE INDEX IF NOT EXISTS one_campaign_work_item_per_service
  ON %1$I.work_items (campaign_id, service) WHERE scope_type = 'campaign';
CREATE UNIQUE INDEX IF NOT EXISTS one_lead_work_item_per_service
  ON %1$I.work_items (campaign_lead_id, service) WHERE scope_type = 'lead';

-- Claim path + reaper path (contracted indexes)
CREATE INDEX IF NOT EXISTS work_items_claim_idx
  ON %1$I.work_items (service, state, available_at, priority DESC);
CREATE INDEX IF NOT EXISTS work_items_expired_leases_idx
  ON %1$I.work_items (lease_expires_at) WHERE state = 'running';

-- One row per execution attempt; created by claim_work_items(), finalized by
-- complete_*/fail_. Budget transactions reference the exact run.
CREATE TABLE IF NOT EXISTS %1$I.service_runs (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_item_id           uuid NOT NULL REFERENCES %1$I.work_items(id),
  work_attempt           integer NOT NULL,
  service                text NOT NULL,
  input_version          bigint NOT NULL,
  workflow_version       text,
  prompt_version         text,
  model_provider         text,
  model_name             text,
  scoring_config_set_id  uuid,
  started_at             timestamptz NOT NULL DEFAULT now(),
  completed_at           timestamptz,
  status                 text NOT NULL DEFAULT 'running'
                           CHECK (status IN ('running','succeeded','failed','deferred','discarded')),
  tool_call_count        integer NOT NULL DEFAULT 0,
  input_hash             text,
  output_hash            text,
  estimated_cost         numeric(12,4),
  actual_cost            numeric(12,4),
  error_code             text,
  UNIQUE (work_item_id, work_attempt)
);
CREATE INDEX IF NOT EXISTS service_runs_item_idx ON %1$I.service_runs (work_item_id);

-- Which cause re-queues which service (self-requeue excluded by convention:
-- seeds must not map a cause to its own producing service)
CREATE TABLE IF NOT EXISTS %1$I.revision_impact_rules (
  cause_type       text NOT NULL,
  affected_service text NOT NULL,
  enabled          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (cause_type, affected_service)
);

$ddl$, ns);
END LOOP;
END $mig$;
