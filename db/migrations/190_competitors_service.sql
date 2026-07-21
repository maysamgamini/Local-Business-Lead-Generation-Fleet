-- 190_competitors_service.sql
-- Adds the warm-gated 'competitors' fleet service (Competitor Gap-Finder): finds nearby same-category
-- rivals via Google Places Text Search, ranks by success (rating x review volume), deep-dives the single
-- best one (reuses the hardened ad-verification matcher + reviews) and writes a competitor_set evidence
-- row the Report renders as a "How you stack up" side-by-side. Mirrors 'ads' (180): created 'blocked' at
-- discovery, opened to 'pending' by the Scorer when a lead turns warm/hot, skipped otherwise. Extends the
-- work_items.service CHECK. Ships behind service_config.competitors.enabled.
\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  ALTER TABLE %1$I.work_items DROP CONSTRAINT IF EXISTS work_items_service_check;
  ALTER TABLE %1$I.work_items ADD CONSTRAINT work_items_service_check CHECK (service IN
    ('discovery','website','reviews','phone','enrichment','assessment','assets','social','phone_probe','ads','competitors'));
$ddl$, ns);
END LOOP;
END $mig$;
