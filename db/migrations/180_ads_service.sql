-- 180_ads_service.sql
-- Adds the warm-gated 'ads' fleet service (Active-Ad Detection Tier 2 / CONFIRMED): live ad-campaign
-- verification via Meta Ad Library API + SerpApi Google/Yelp ad transparency. Mirrors 'social' (130):
-- created 'blocked' at discovery, opened to 'pending' by the Scorer when a lead turns warm/hot,
-- skipped otherwise. Extends the work_items.service CHECK. Ships behind service_config.ads.enabled.
\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  ALTER TABLE %1$I.work_items DROP CONSTRAINT IF EXISTS work_items_service_check;
  ALTER TABLE %1$I.work_items ADD CONSTRAINT work_items_service_check CHECK (service IN
    ('discovery','website','reviews','phone','enrichment','assessment','assets','social','phone_probe','ads'));
$ddl$, ns);
END LOOP;
END $mig$;
