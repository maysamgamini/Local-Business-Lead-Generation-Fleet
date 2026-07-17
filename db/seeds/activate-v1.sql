-- activate-v1.sql (T028)
-- Seeds + activates the v1 config sets in BOTH namespaces.
-- Source of truth for numbers: specs/001-leadgen-fleet/contracts/scoring-defaults.md
-- Idempotent: ON CONFLICT DO NOTHING on config_sets(config_type,version); child
-- rows only inserted when the set row is newly created.

\set ON_ERROR_STOP 1

DO $seed$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($body$

DO $inner$
DECLARE
  s_scoring uuid; s_chain uuid; s_vertical uuid; s_model uuid; s_service uuid;
  v_new boolean;
BEGIN
  INSERT INTO %1$I.config_sets (config_type, version, content_hash)
  VALUES ('scoring', 1, md5('scoring-v1-2026-07-17'))
  ON CONFLICT (config_type, version) DO NOTHING
  RETURNING id INTO s_scoring;
  v_new := s_scoring IS NOT NULL;
  IF NOT v_new THEN
    SELECT id INTO s_scoring FROM %1$I.config_sets WHERE config_type='scoring' AND version=1;
  END IF;

  INSERT INTO %1$I.config_sets (config_type, version, content_hash)
  VALUES ('chain_rules', 1, md5('chain-v1')),
         ('vertical_policy', 1, md5('vertical-v1')),
         ('model_policy', 1, md5('model-v1')),
         ('service_policy', 1, md5('service-v1'))
  ON CONFLICT (config_type, version) DO NOTHING;
  SELECT id INTO s_chain    FROM %1$I.config_sets WHERE config_type='chain_rules' AND version=1;
  SELECT id INTO s_vertical FROM %1$I.config_sets WHERE config_type='vertical_policy' AND version=1;
  SELECT id INTO s_model    FROM %1$I.config_sets WHERE config_type='model_policy' AND version=1;
  SELECT id INTO s_service  FROM %1$I.config_sets WHERE config_type='service_policy' AND version=1;

  IF v_new THEN
    -- ============ scoring_config (scoring-defaults.md) ============
    INSERT INTO %1$I.scoring_config
      (config_set_id, product, feature_key, transform_type, direction,
       input_min, input_max, weight, point_cap, step_map, missing_policy, lineage_policy)
    VALUES
    -- fit_web_seo
    (s_scoring,'web_seo','website_present','boolean_points',NULL,NULL,NULL,1,85,
       '{"when":false,"points":85}','no_points','count_roots_only'),
    (s_scoring,'web_seo','pagespeed_performance','inverse_linear','lower_better',0,100,1,25,NULL,'no_points','count_roots_only'),
    (s_scoring,'web_seo','pagespeed_seo','inverse_linear','lower_better',0,100,1,15,NULL,'no_points','count_roots_only'),
    (s_scoring,'web_seo','serp_rank','step',NULL,NULL,NULL,1,20,
       '{"steps":[{"gt":20,"points":20},{"gte":11,"points":12},{"gte":4,"points":5},{"lte":3,"points":0}]}',
       'no_points','count_roots_only'),
    (s_scoring,'web_seo','design_age_estimate','step',NULL,NULL,NULL,1,15,
       '{"map":{"dated":15,"aging":8,"modern":0}}','no_points','count_roots_only'),
    (s_scoring,'web_seo','seo_gaps_count','linear','higher_better',0,5,3,15,NULL,'no_points','count_roots_only'),
    (s_scoring,'web_seo','conversion_blockers_count','linear','higher_better',0,2,5,10,NULL,'no_points','count_roots_only'),
    -- fit_voice_ai
    (s_scoring,'voice_ai','phone_pain_score','linear','higher_better',0,1,40,40,NULL,'no_points','count_roots_only'),
    (s_scoring,'voice_ai','phone_complaint_share','linear','higher_better',0,1,25,25,NULL,'no_points','count_roots_only'),
    (s_scoring,'voice_ai','booking_widget_present','boolean_points',NULL,NULL,NULL,1,15,
       '{"when":false,"points":15}','no_points','count_roots_only'),
    (s_scoring,'voice_ai','hours_gap_vs_norm','linear','higher_better',0,1,10,10,NULL,'no_points','count_roots_only'),
    (s_scoring,'voice_ai','owner_response_rate','boolean_points',NULL,NULL,NULL,1,10,
       '{"when_lt":0.2,"points":10}','no_points','count_roots_only'),
    -- fit_ads_video
    (s_scoring,'ads_video','ad_presence','boolean_points',NULL,NULL,NULL,1,30,
       '{"when":"none","points":30}','no_points','count_roots_only'),
    (s_scoring,'ads_video','review_volume','log','higher_better',25,400,1,25,NULL,'no_points','count_roots_only'),
    (s_scoring,'ads_video','social_inactive_90d','boolean_points',NULL,NULL,NULL,1,25,
       '{"when":true,"points":25}','no_points','count_roots_only'),
    (s_scoring,'ads_video','photo_asset_count','boolean_points',NULL,NULL,NULL,1,10,
       '{"when_gte":10,"points":10}','no_points','count_roots_only'),
    (s_scoring,'ads_video','rating','boolean_points',NULL,NULL,NULL,1,10,
       '{"when_gte":4.0,"points":10}','no_points','count_roots_only'),
    -- fit_consulting (scorer-internal derived features)
    (s_scoring,'consulting','fits_in_midband_count','boolean_points',NULL,NULL,NULL,1,40,
       '{"when_gte":2,"points":40}','no_points','count_roots_only'),
    (s_scoring,'consulting','tech_fragmentation','boolean_points',NULL,NULL,NULL,1,30,
       '{"when_gte":3,"points":30}','no_points','count_roots_only'),
    (s_scoring,'consulting','multi_location_parent','boolean_points',NULL,NULL,NULL,1,15,
       '{"when":true,"points":15}','no_points','count_roots_only'),
    (s_scoring,'consulting','owner_responds_to_reviews','boolean_points',NULL,NULL,NULL,1,15,
       '{"when":true,"points":15}','no_points','count_roots_only'),
    -- opportunity composite
    (s_scoring,'opportunity','best_fit','composite',NULL,NULL,NULL,0.55,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'opportunity','second_fit','composite',NULL,NULL,NULL,0.15,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'opportunity','firmographic_category','boolean_points',NULL,NULL,NULL,1,15,
       '{"when":true,"points":15}','no_points','count_roots_only'),
    (s_scoring,'opportunity','firmographic_geo','boolean_points',NULL,NULL,NULL,1,5,
       '{"when":true,"points":5}','no_points','count_roots_only'),
    (s_scoring,'opportunity','firmographic_size','boolean_points',NULL,NULL,NULL,1,10,
       '{"when":true,"points":10}','no_points','count_roots_only'),
    -- contactability (verified + unexpired only)
    (s_scoring,'contactability','role_source_attested','boolean_points',NULL,NULL,NULL,1,40,
       '{"when":true,"points":40}','no_points','count_roots_only'),
    (s_scoring,'contactability','channel_deliverable_email','boolean_points',NULL,NULL,NULL,1,40,
       '{"when":true,"points":40}','no_points','count_roots_only'),
    (s_scoring,'contactability','direct_phone','boolean_points',NULL,NULL,NULL,1,10,
       '{"when":true,"points":10}','no_points','count_roots_only'),
    (s_scoring,'contactability','linkedin_matched','boolean_points',NULL,NULL,NULL,1,10,
       '{"when":true,"points":10}','no_points','count_roots_only'),
    -- evidence confidence
    (s_scoring,'confidence','completeness','linear','higher_better',0,1,40,40,NULL,'no_points','count_roots_only'),
    (s_scoring,'confidence','confirmed_evidence_count','linear','higher_better',0,20,1.5,30,NULL,'no_points','count_roots_only'),
    (s_scoring,'confidence','recency_share_12mo','boolean_points',NULL,NULL,NULL,1,20,
       '{"when_gte":0.6,"points":20}','no_points','count_roots_only'),
    (s_scoring,'confidence','source_diversity','boolean_points',NULL,NULL,NULL,1,10,
       '{"when_gte":3,"points":10}','no_points','count_roots_only'),
    -- thresholds
    (s_scoring,'thresholds','hot_opportunity','composite',NULL,NULL,NULL,75,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'thresholds','hot_contactability','composite',NULL,NULL,NULL,60,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'thresholds','hot_confidence','composite',NULL,NULL,NULL,60,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'thresholds','hot_candidate_confidence','composite',NULL,NULL,NULL,60,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'thresholds','warm_opportunity','composite',NULL,NULL,NULL,60,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'thresholds','cold_opportunity','composite',NULL,NULL,NULL,40,NULL,NULL,'no_points','count_roots_only'),
    (s_scoring,'thresholds','enrichment_gate','composite',NULL,NULL,NULL,60,NULL,NULL,'no_points','count_roots_only');

    -- ============ chain rules (asset collector rule ships DISABLED) ============
    INSERT INTO %1$I.chain_rules
      (config_set_id, source_service, event, field, operator, value, target_service, enabled)
    VALUES
      (s_chain,'assessment','on_assessment','fit_web_seo','>=','60','assets', false),
      (s_chain,'assessment','on_assessment','fit_ads_video','>=','60','assets', false);

    -- ============ revision impact rules (self-requeue never mapped) ============
    INSERT INTO %1$I.revision_impact_rules (cause_type, affected_service) VALUES
      ('website_evidence','phone'), ('website_evidence','assessment'),
      ('reviews_evidence','phone'), ('reviews_evidence','assessment'),
      ('phone_evidence','assessment'),
      ('contact_finding','assessment'), ('contact_verification','assessment'),
      ('suppression_change','enrichment'), ('suppression_change','assessment'),
      ('evidence_dispute','assessment')
    ON CONFLICT DO NOTHING;

    -- ============ vertical policy ============
    INSERT INTO %1$I.service_policy_entries (config_set_id, policy_key, policy_value) VALUES
      (s_vertical,'titles.medspa',  '["Owner","Founder","Medical Director","Practice Manager","Office Manager"]'),
      (s_vertical,'titles.dental',  '["Owner","Dentist","Practice Manager","Office Manager"]'),
      (s_vertical,'titles.default', '["Owner","Founder","General Manager","Office Manager","Marketing Director"]'),
      (s_vertical,'categories.medspa','["med_spa","spa","skin_care_clinic","medical_spa"]'),
      (s_vertical,'categories.dental','["dentist","dental_clinic","orthodontist"]'),
      (s_vertical,'yelp_verticals', '["medspa","dental","restaurant","salon"]');

    -- ============ model policy (cross-family critics enforced by assignment) ====
    INSERT INTO %1$I.service_policy_entries (config_set_id, policy_key, policy_value) VALUES
      (s_model,'model.website_agent',   '{"provider":"anthropic","model":"claude-sonnet-5","max_output_tokens":2000}'),
      (s_model,'model.review_themes',   '{"provider":"google_ai","model":"gemini-flash-latest","max_output_tokens":1500}'),
      (s_model,'model.category_classify','{"provider":"openai","model":"gpt-mini-latest","max_output_tokens":400}'),
      (s_model,'model.dm_hunter',       '{"provider":"anthropic","model":"claude-sonnet-5","max_output_tokens":1200}'),
      (s_model,'model.hot_critic',      '{"provider":"openai","model":"gpt-latest","max_output_tokens":1500,"note":"cross-family from claude evidence writers"}');

    -- ============ service policy: deadlines, caps, retries, quality floors =====
    INSERT INTO %1$I.service_policy_entries (config_set_id, policy_key, policy_value) VALUES
      (s_service,'deadline.campaign_hours','24'),
      (s_service,'deadline.approval_hours','12'),
      (s_service,'agent.fetch_page_cap','6'),
      (s_service,'agent.dm_hunter_cap','6'),
      (s_service,'retry.dead_threshold','3'),
      (s_service,'quality.dead_ratio_degraded','0.20'),
      (s_service,'quality.dead_ratio_unusable','0.35'),
      (s_service,'quality.min_confidence_degraded','40'),
      (s_service,'review_window','200'),
      (s_service,'gate.threshold_version','"v1"');
  END IF;

  -- activate all five (idempotent)
  UPDATE %1$I.config_sets SET activated_at = coalesce(activated_at, now())
   WHERE version = 1 AND config_type IN
     ('scoring','chain_rules','vertical_policy','model_policy','service_policy');
END $inner$;

-- ============ operational config (mutable; upsert every run) ============
INSERT INTO %1$I.service_config
  (service, claim_batch_size, max_concurrency, rate_limit_per_minute, lease_ttl_s, unit_costs) VALUES
  ('discovery',  1, 2, NULL, 900, '{"places_page":0.017,"serpapi_search":0.01}'),
  ('website',    5, 5, NULL, 600, '{"psi_call":0.0,"llm_est":0.05}'),
  ('reviews',    5, 5, NULL, 600, '{"apify_batch":0.25,"llm_est":0.02}'),
  ('phone',      5, 5, NULL, 300, '{}'),
  ('enrichment', 3, 3, NULL, 600, '{"apollo_lookup":0.40,"hunter_verify":0.10}'),
  ('assessment', 5, 5, NULL, 300, '{"llm_est":0.03}'),
  ('assets',     1, 1, NULL, 300, '{}')
ON CONFLICT (service) DO UPDATE SET
  claim_batch_size = EXCLUDED.claim_batch_size,
  max_concurrency = EXCLUDED.max_concurrency,
  lease_ttl_s = EXCLUDED.lease_ttl_s,
  unit_costs = EXCLUDED.unit_costs;

INSERT INTO %1$I.provider_limits
  (provider, credential_scope, requests_per_minute, concurrent_requests, bucket_tokens) VALUES
  ('google_places','default', 300, 10, 300),
  ('serpapi','default',        60,  5,  60),
  ('apify','default',          30,  5,  30),
  ('apollo','default',         60,  3,  60),
  ('hunter','default',         60,  5,  60),
  ('psi','default',           240, 10, 240),
  ('anthropic','default',      60,  8,  60),
  ('openai','default',        120, 10, 120),
  ('google_ai','default',     120, 10, 120),
  ('slack','default',          60,  4,  60),
  ('airtable','default',      250,  5, 250),
  ('gsheets','default',        60,  4,  60)
ON CONFLICT (provider, credential_scope) DO NOTHING;

$body$, ns);
END LOOP;
END $seed$;
