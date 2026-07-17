-- 070_money_providers.sql (T014)
-- budget_transactions (max-billable authorization, expiry, reconciliation),
-- provider_limits, provider_permits (permit_token — full fence) — both namespaces.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

CREATE TABLE IF NOT EXISTS %1$I.budget_transactions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id           uuid NOT NULL REFERENCES %1$I.campaigns(id),
  business_id           uuid REFERENCES %1$I.businesses(id),
  service_run_id        uuid NOT NULL REFERENCES %1$I.service_runs(id),
  service               text NOT NULL,
  provider              text NOT NULL,
  operation             text NOT NULL,
  state                 text NOT NULL DEFAULT 'reserved'
                          CHECK (state IN ('reserved','settled','released')),
  maximum_billable_usd  numeric(12,4) NOT NULL CHECK (maximum_billable_usd > 0),
  actual_usd            numeric(12,4) CHECK (actual_usd >= 0),
  reserved_at           timestamptz NOT NULL DEFAULT now(),
  expires_at            timestamptz NOT NULL,        -- crash recovery via Sweeper
  settled_at            timestamptz,
  reconciliation_status text NOT NULL DEFAULT 'n/a'
                          CHECK (reconciliation_status IN ('n/a','reconciliation_required','reconciled')),
  provider_request_id   text,
  idempotency_key       text NOT NULL UNIQUE,
  -- the hard-cap guarantee has no overrun path (SC-005)
  CONSTRAINT settle_within_maximum CHECK (actual_usd IS NULL OR actual_usd <= maximum_billable_usd)
);
CREATE INDEX IF NOT EXISTS budget_campaign_state_idx
  ON %1$I.budget_transactions (campaign_id, state);
CREATE INDEX IF NOT EXISTS budget_expiry_idx
  ON %1$I.budget_transactions (expires_at) WHERE state = 'reserved';

-- Global per-credential quotas + cooldowns (shared across all services)
CREATE TABLE IF NOT EXISTS %1$I.provider_limits (
  provider            text NOT NULL,
  credential_scope    text NOT NULL,
  requests_per_minute integer NOT NULL CHECK (requests_per_minute > 0),
  concurrent_requests integer NOT NULL CHECK (concurrent_requests > 0),
  cooldown_until      timestamptz,
  throttle_state      jsonb NOT NULL DEFAULT '{}',
  -- token bucket state (managed inside acquire function under row lock)
  bucket_tokens       numeric(10,4) NOT NULL DEFAULT 0,
  bucket_refilled_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, credential_scope)
);

-- Leased concurrency slots: crash-expired, never counted (no counters to leak)
CREATE TABLE IF NOT EXISTS %1$I.provider_permits (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider         text NOT NULL,
  credential_scope text NOT NULL,
  service_run_id   uuid NOT NULL REFERENCES %1$I.service_runs(id),
  operation        text NOT NULL,
  permit_token     uuid NOT NULL,               -- ownership fence for release/renew
  acquired_at      timestamptz NOT NULL DEFAULT now(),
  expires_at       timestamptz NOT NULL,
  released_at      timestamptz,
  state            text NOT NULL DEFAULT 'active'
                     CHECK (state IN ('active','released','expired'))
);
CREATE INDEX IF NOT EXISTS permits_active_idx
  ON %1$I.provider_permits (provider, credential_scope, expires_at)
  WHERE state = 'active';

$ddl$, ns);
END LOOP;
END $mig$;
