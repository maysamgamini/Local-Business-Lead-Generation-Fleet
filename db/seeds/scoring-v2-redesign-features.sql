-- scoring-v2-redesign-features.sql
-- Website Auditor v2 adds redesign-opportunity signals that reward OUTDATED and
-- VISUALLY WEAK sites (the best redesign-sale prospects). Appended to the active
-- scoring config set (v1) in both namespaces. Pre-launch: we append rather than
-- version-bump, since no production campaign depends on reproducibility yet.
--
-- New web_seo features (on top of website_present, pagespeed_performance/seo,
-- serp_rank, design_age_estimate, seo_gaps, conversion_blockers):
--   pagespeed_accessibility  inverse_linear 0-100  cap 10   (worse a11y -> prospect)
--   mobile_friendly=false    boolean               cap 20   (not mobile -> strong)
--   staleness_years          linear 0-6            cap 25   (stale -> strong)
--   visual_appeal            step poor/avg/good    cap 25   (ugly -> strong; from Gemini vision)
-- design_age_estimate already present (dated 15 / aging 8 / modern 0).

\set ON_ERROR_STOP 1

DO $seed$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($body$
  INSERT INTO %1$I.scoring_config
    (config_set_id, product, feature_key, transform_type, direction,
     input_min, input_max, weight, point_cap, step_map, missing_policy, lineage_policy)
  SELECT cs.id, v.product, v.feature_key, v.transform_type, v.direction,
         v.input_min, v.input_max, v.weight, v.point_cap, v.step_map::jsonb,
         v.missing_policy, v.lineage_policy
  FROM %1$I.config_sets cs
  CROSS JOIN (VALUES
    ('web_seo','pagespeed_accessibility','inverse_linear','lower_better',0,100,1,10,NULL,'no_points','count_roots_only'),
    ('web_seo','mobile_friendly','boolean_points',NULL,NULL,NULL,1,20,'{"when":false,"points":20}','no_points','count_roots_only'),
    ('web_seo','staleness_years','linear','higher_better',0,6,1,25,NULL,'no_points','count_roots_only'),
    ('web_seo','visual_appeal','step',NULL,NULL,NULL,1,25,'{"map":{"poor":25,"average":12,"good":0}}','no_points','count_roots_only')
  ) AS v(product,feature_key,transform_type,direction,input_min,input_max,weight,point_cap,step_map,missing_policy,lineage_policy)
  WHERE cs.config_type='scoring' AND cs.version=1
  ON CONFLICT (config_set_id, product, feature_key, business_type) DO NOTHING;
$body$, ns);
END LOOP;
END $seed$;
