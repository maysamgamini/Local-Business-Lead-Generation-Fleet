-- 170_campaign_schedules.sql
-- Scheduler (Ops Console feature #4): recurring / one-off campaign launches. A schedule stores a
-- create_campaign template (cloned from a source campaign) + a cadence + next_run_at. The Scheduler
-- workflow calls fire_due_schedules() hourly. Prod-only by design (scheduled real spend). Idempotent.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  CREATE TABLE IF NOT EXISTS %1$I.campaign_schedules (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    caller_identity    uuid NOT NULL,
    label              text,
    template           jsonb NOT NULL,            -- create_campaign request minus request_id
    cadence            text NOT NULL CHECK (cadence IN ('once','weekly','monthly')),
    next_run_at        timestamptz NOT NULL,
    enabled            boolean NOT NULL DEFAULT true,
    source_campaign_id uuid,
    last_run_at        timestamptz,
    last_campaign_id   uuid,
    run_count          integer NOT NULL DEFAULT 0,
    created_at         timestamptz NOT NULL DEFAULT now()
  );
  CREATE INDEX IF NOT EXISTS campaign_schedules_due_idx
    ON %1$I.campaign_schedules (next_run_at) WHERE enabled;
$ddl$, ns);
END LOOP;
END $mig$;
