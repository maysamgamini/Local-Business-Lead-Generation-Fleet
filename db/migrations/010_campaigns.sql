-- 010_campaigns.sql (T008)
-- campaigns, approval_tokens, campaign_business_snapshots — for BOTH namespaces.
-- Conventions: uuid PKs (gen_random_uuid), timestamptz, text+CHECK over enums,
-- money as numeric(12,4). Cross-file FKs (config_sets, campaign_leads) are added
-- in 090_indexes_constraints_views.sql after all tables exist.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

CREATE TABLE IF NOT EXISTS %1$I.campaigns (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  caller_identity             uuid        NOT NULL,
  request_id                  text        NOT NULL,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  trigger_source              text        NOT NULL CHECK (trigger_source IN ('form','schedule','webhook')),
  business_type               text        NOT NULL,
  resolved_place_category     text,
  geo_type                    text        NOT NULL CHECK (geo_type IN ('zip','city_radius')),
  geo_original                jsonb       NOT NULL,
  geo_lat                     double precision,   -- filled by Discovery after geocoding
  geo_lng                     double precision,
  geo_radius_m                integer     NOT NULL CHECK (geo_radius_m > 0),
  depth                       text        NOT NULL CHECK (depth IN ('quick','standard','deep')),
  volume_cap                  integer     NOT NULL CHECK (volume_cap BETWEEN 1 AND 300),
  budget_cap_usd              numeric(12,4) NOT NULL CHECK (budget_cap_usd > 0),
  requires_approval           boolean     NOT NULL DEFAULT false,
  approval_status             text        NOT NULL DEFAULT 'n/a'
                                CHECK (approval_status IN ('n/a','pending','approved','rejected','expired')),
  exclusions                  jsonb       NOT NULL DEFAULT '{"domains":[],"names":[]}',
  dry_run                     boolean     NOT NULL DEFAULT false,
  -- pinned immutable config sets (FKs added in 090)
  scoring_config_set_id       uuid        NOT NULL,
  chain_rule_set_id           uuid        NOT NULL,
  vertical_policy_set_id      uuid        NOT NULL,
  model_policy_set_id         uuid        NOT NULL,
  service_policy_set_id       uuid        NOT NULL,
  -- lifecycle / condition / quality (three separate dimensions)
  status                      text        NOT NULL DEFAULT 'created'
                                CHECK (status IN ('created','discovering','analyzing','awaiting_approval',
                                                  'finalizing','complete','failed','canceled')),
  budget_state                text        NOT NULL DEFAULT 'within_budget'
                                CHECK (budget_state IN ('within_budget','near_limit','exhausted')),
  quality_state               text        CHECK (quality_state IN ('healthy','partial','degraded','unusable')),
  -- finalization fence
  campaign_state_revision     bigint      NOT NULL DEFAULT 0,
  finalization_token          uuid,
  -- pinned deadlines (stamped by create_campaign from deadline policy)
  campaign_deadline_at        timestamptz NOT NULL,
  approval_deadline_at        timestamptz,
  critic_deadline_at          timestamptz,
  reconciliation_deadline_at  timestamptz,
  finalization_retry_deadline_at timestamptz,
  -- completion
  completed_at                timestamptz,
  completion_reason           text,
  digest_url                  text,
  sheet_snapshot_url          text,
  CONSTRAINT campaigns_caller_request_uniq UNIQUE (caller_identity, request_id)
);

CREATE TABLE IF NOT EXISTS %1$I.approval_tokens (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id   uuid        NOT NULL REFERENCES %1$I.campaigns(id),
  token_hash    text        NOT NULL UNIQUE,          -- sha256 hex; raw token never stored
  issued_to     text        NOT NULL,
  issued_at     timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  used_at       timestamptz,
  decision      text        CHECK (decision IN ('approved','rejected')),
  revoked_at    timestamptz
);

-- Identity as observed during THIS campaign; digests read snapshots, never
-- current identity (FR-025). campaign_lead_id FK added in 090 (table order).
CREATE TABLE IF NOT EXISTS %1$I.campaign_business_snapshots (
  campaign_lead_id uuid PRIMARY KEY,
  business_name    text NOT NULL,
  website_domain   text,
  phone_e164       text,
  address          text,
  lat              double precision,
  lng              double precision,
  captured_at      timestamptz NOT NULL DEFAULT now()
);

$ddl$, ns);
END LOOP;
END $mig$;
