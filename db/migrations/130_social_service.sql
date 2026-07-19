-- 130_social_service.sql
-- Adds the 'social' fleet service: a WARM-GATED social-activity eval (Apify
-- Instagram/Facebook/TikTok + SerpApi profile discovery + Yelp reuse) that derives
-- follower counts, last-post recency and social_inactive_90d. Mirrors the enrichment
-- gate: created 'blocked' at discovery, opened to 'pending' by the Scorer when a lead
-- turns warm/hot, skipped otherwise. Extends the work_items.service CHECK constraint.
--
-- Ships DISABLED via the service_config seed (enabled=false) so commit_discovery_results
-- creates it terminal (skipped_prerequisite) and campaigns finalize normally until the
-- Social Activity worker is deployed; then it's a one-row flip (enabled=true).

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  ALTER TABLE %1$I.work_items DROP CONSTRAINT IF EXISTS work_items_service_check;
  ALTER TABLE %1$I.work_items ADD CONSTRAINT work_items_service_check CHECK (service IN
    ('discovery','website','reviews','phone','enrichment','assessment','assets','social'));
$ddl$, ns);
END LOOP;
END $mig$;
