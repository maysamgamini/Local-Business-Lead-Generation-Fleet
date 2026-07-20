-- 160_campaign_target.sql
-- Single-business "target mode" (Ops Console feature #3): a campaign can target ONE
-- business by name+city or website instead of an area search. create_campaign stores the
-- request's `target` here; Discovery reads it and does a Places text search (pageSize 1)
-- instead of a nearby search. NULL = normal area campaign. Idempotent.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
  EXECUTE format('ALTER TABLE %I.campaigns ADD COLUMN IF NOT EXISTS target jsonb', ns);
END LOOP;
END $mig$;
