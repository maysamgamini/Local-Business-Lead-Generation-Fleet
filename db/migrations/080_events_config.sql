-- 080_events_config.sql (T015)
-- Transactional outbox (events + per-destination deliveries + consumption
-- receipts), chain rules + durable evaluations, immutable config sets,
-- service config/policy/runtime split, assets (v1 reference-only) — both namespaces.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

-- ============ Transactional outbox ============
CREATE TABLE IF NOT EXISTS %1$I.outbox_events (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type         text NOT NULL,
  event_class        text NOT NULL CHECK (event_class IN
                       ('state_change','dependency','notification','mirror','audit')),
  blocks_finalization boolean NOT NULL,
  aggregate_id       uuid NOT NULL,          -- campaign_id or campaign_lead_id
  effective_revision bigint,
  payload            jsonb NOT NULL DEFAULT '{}',
  idempotency_key    text NOT NULL UNIQUE,
  created_at         timestamptz NOT NULL DEFAULT now(),
  -- only state/dependency events may block finalization
  CONSTRAINT blocks_only_state_dep CHECK
    (NOT blocks_finalization OR event_class IN ('state_change','dependency'))
);
CREATE INDEX IF NOT EXISTS outbox_events_aggregate_idx
  ON %1$I.outbox_events (aggregate_id, created_at DESC);

CREATE TABLE IF NOT EXISTS %1$I.outbox_deliveries (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id         uuid NOT NULL REFERENCES %1$I.outbox_events(id),
  destination      text NOT NULL,
  state            text NOT NULL DEFAULT 'pending'
                     CHECK (state IN ('pending','running','delivered','dead_letter')),
  available_at     timestamptz NOT NULL DEFAULT now(),
  claimed_at       timestamptz,
  lease_expires_at timestamptz,
  claim_token      uuid,
  attempt_count    integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  delivered_at     timestamptz,
  last_error       text,
  UNIQUE (event_id, destination)
);
CREATE INDEX IF NOT EXISTS outbox_deliveries_pending_idx
  ON %1$I.outbox_deliveries (destination, state, available_at);
CREATE INDEX IF NOT EXISTS outbox_deliveries_expired_idx
  ON %1$I.outbox_deliveries (lease_expires_at) WHERE state = 'running';

-- At-least-once + idempotent consumers: receipt committed with the mutation
CREATE TABLE IF NOT EXISTS %1$I.event_consumptions (
  event_id         uuid NOT NULL REFERENCES %1$I.outbox_events(id),
  destination      text NOT NULL,
  consumer_version text,
  consumed_at      timestamptz NOT NULL DEFAULT now(),
  result_hash      text,
  PRIMARY KEY (event_id, destination)
);

-- ============ Chain rules + durable evaluations ============
CREATE TABLE IF NOT EXISTS %1$I.chain_rules (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_set_id  uuid NOT NULL,                 -- FK to config_sets added in 090
  source_service text NOT NULL,
  event          text NOT NULL CHECK (event IN ('on_complete','on_assessment','on_approval')),
  field          text NOT NULL,
  operator       text NOT NULL CHECK (operator IN ('>=','<=','>','<','=','!=')),
  value          text NOT NULL,
  target_service text NOT NULL,                 -- allowlisted identifier, never a URL
  enabled        boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS %1$I.chain_rule_evaluations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  rule_id          uuid NOT NULL REFERENCES %1$I.chain_rules(id),
  input_revision   bigint NOT NULL,
  outcome          text NOT NULL CHECK (outcome IN ('fired','suppressed','not_applicable','error')),
  target_service   text,
  evaluated_at     timestamptz NOT NULL DEFAULT now(),
  event_id         uuid REFERENCES %1$I.outbox_events(id),
  error_detail     text,
  UNIQUE (campaign_lead_id, rule_id, input_revision)   -- idempotent under duplicate delivery
);

-- ============ Immutable config sets, campaign-pinned ============
CREATE TABLE IF NOT EXISTS %1$I.config_sets (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_type  text NOT NULL CHECK (config_type IN
                 ('scoring','chain_rules','vertical_policy','model_policy','service_policy')),
  version      integer NOT NULL CHECK (version > 0),
  content_hash text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz,
  retired_at   timestamptz,
  UNIQUE (config_type, version)
);

CREATE TABLE IF NOT EXISTS %1$I.scoring_config (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_set_id  uuid NOT NULL REFERENCES %1$I.config_sets(id),
  business_type  text,                          -- NULL = default vertical
  product        text NOT NULL CHECK (product IN
                   ('web_seo','voice_ai','ads_video','consulting',
                    'opportunity','contactability','confidence','thresholds')),
  feature_key    text NOT NULL,
  transform_type text NOT NULL CHECK (transform_type IN
                   ('linear','inverse_linear','step','log','boolean_points','composite')),
  direction      text CHECK (direction IN ('higher_better','lower_better')),
  input_min      numeric(12,4),
  input_max      numeric(12,4),
  weight         numeric(8,4) NOT NULL DEFAULT 1,
  point_cap      numeric(8,4),
  step_map       jsonb,                          -- for step transforms
  missing_policy text NOT NULL DEFAULT 'no_points'
                   CHECK (missing_policy IN ('no_points','neutral_points','penalize')),
  source_policy  jsonb,
  lineage_policy text NOT NULL DEFAULT 'count_roots_only'
                   CHECK (lineage_policy IN ('count_roots_only','allow_derived','explicit_both')),
  UNIQUE (config_set_id, product, feature_key, business_type)
);

-- Pinned policy entries (thresholds, deadlines, tool caps, model assignments,
-- vertical mappings) — immutable via config-set membership
CREATE TABLE IF NOT EXISTS %1$I.service_policy_entries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  config_set_id uuid NOT NULL REFERENCES %1$I.config_sets(id),
  policy_key    text NOT NULL,
  policy_value  jsonb NOT NULL,
  UNIQUE (config_set_id, policy_key)
);

-- Operational knobs: NOT pinned, mutable at runtime (claim sizes, leases)
CREATE TABLE IF NOT EXISTS %1$I.service_config (
  service             text PRIMARY KEY,
  claim_batch_size    integer NOT NULL DEFAULT 5  CHECK (claim_batch_size > 0),
  max_concurrency     integer NOT NULL DEFAULT 5  CHECK (max_concurrency > 0),
  rate_limit_per_minute integer,
  lease_ttl_s         integer NOT NULL DEFAULT 600 CHECK (lease_ttl_s > 0),
  unit_costs          jsonb NOT NULL DEFAULT '{}'
);

-- Ephemeral throttles/cooldowns — mutable runtime state, never pinned
CREATE TABLE IF NOT EXISTS %1$I.service_runtime_state (
  service       text PRIMARY KEY REFERENCES %1$I.service_config(service),
  throttle_state jsonb NOT NULL DEFAULT '{}',
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ============ Assets: v1 reference-only ============
CREATE TABLE IF NOT EXISTS %1$I.assets (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      uuid NOT NULL REFERENCES %1$I.businesses(id),
  campaign_lead_id uuid REFERENCES %1$I.campaign_leads(id),
  service_run_id   uuid REFERENCES %1$I.service_runs(id),
  source           text NOT NULL,
  source_url       text NOT NULL,
  storage_ref      text,          -- ALWAYS NULL in v1 (collector deferred; rights first)
  page_context     text,
  license_status   text NOT NULL DEFAULT 'reference_only' CHECK (license_status IN
                     ('reference_only','internal_analysis','customer_owned',
                      'permission_granted','licensed_for_reuse','prohibited')),
  observed_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT v1_reference_only CHECK (storage_ref IS NULL OR license_status IN
    ('customer_owned','permission_granted','licensed_for_reuse'))
);

-- ============ Scheduled-intake cursors (deployed early; used from US3) ============
CREATE TABLE IF NOT EXISTS %1$I.standing_profile_cursors (
  profile_source     text NOT NULL,
  profile_row_id     text NOT NULL,
  last_scheduled_slot text NOT NULL,
  last_campaign_id   uuid REFERENCES %1$I.campaigns(id),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  version            integer NOT NULL DEFAULT 1,
  PRIMARY KEY (profile_source, profile_row_id)
);

$ddl$, ns);
END LOOP;
END $mig$;
