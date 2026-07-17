-- 110_service_enabled.sql (Option A: data-driven service enablement)
-- Adds service_config.enabled so commit_discovery_results only enqueues live-worker
-- services as active work; a disabled service is created terminal (skipped_prerequisite)
-- so a campaign can finalize without a worker that does not exist yet. Enabling a
-- service later is a one-row flip (UPDATE service_config SET enabled=true ...); new
-- campaigns pick it up automatically. US1 disables reviews/phone/enrichment/assets.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  ALTER TABLE %1$I.service_config ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true;
  UPDATE %1$I.service_config SET enabled = false
   WHERE service IN ('reviews','phone','enrichment','assets');
$ddl$, ns);
END LOOP;
END $mig$;
