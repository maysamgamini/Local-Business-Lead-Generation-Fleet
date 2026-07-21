-- 200_ads_social_report_quality.sql
-- Align Ads/Social scoring with evidence that the shipped workers actually produce.
-- Existing campaigns remain pinned to immutable scoring-v1; new campaigns receive v2.
-- Also routes late ads/competitor evidence to assessment so confidence and the current
-- assessment watermark reflect all completed warm-gated analysis.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE
  ns text;
  old_id uuid;
  new_id uuid;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
  EXECUTE format(
    'SELECT id FROM %I.config_sets WHERE config_type=''scoring'' AND retired_at IS NULL ORDER BY version DESC LIMIT 1',
    ns) INTO old_id;

  IF old_id IS NOT NULL THEN
    EXECUTE format($sql$
      INSERT INTO %1$I.config_sets
        (config_type, version, content_hash, activated_at)
      SELECT 'scoring', coalesce(max(version),0)+1,
             md5('scoring-v2-ads-social-' || (coalesce(max(version),0)+1)::text), now()
        FROM %1$I.config_sets WHERE config_type='scoring'
      RETURNING id
    $sql$, ns) INTO new_id;

    EXECUTE format($sql$
      INSERT INTO %1$I.scoring_config
        (config_set_id, business_type, product, feature_key, transform_type,
         direction, input_min, input_max, weight, point_cap, step_map,
         missing_policy, source_policy, lineage_policy)
      SELECT $1, business_type, product, feature_key, transform_type,
             direction, input_min, input_max, weight, point_cap, step_map,
             missing_policy, source_policy, lineage_policy
        FROM %1$I.scoring_config
       WHERE config_set_id=$2
         AND NOT (product='ads_video' AND feature_key='ad_presence')
    $sql$, ns) USING new_id, old_id;

    EXECUTE format($sql$
      INSERT INTO %1$I.scoring_config
        (config_set_id, product, feature_key, transform_type, weight, point_cap,
         step_map, missing_policy, lineage_policy)
      VALUES
        ($1,'ads_video','ad_active','boolean_points',1,25,
         '{"when":false,"points":25}','no_points','count_roots_only'),
        ($1,'ads_video','social_platform_count','boolean_points',1,20,
         '{"when_lt":2,"points":20}','no_points','count_roots_only')
      ON CONFLICT DO NOTHING
    $sql$, ns) USING new_id;

    EXECUTE format(
      'UPDATE %I.config_sets SET retired_at=now() WHERE id=$1', ns)
      USING old_id;
  END IF;

  EXECUTE format($sql$
    INSERT INTO %1$I.revision_impact_rules (cause_type, affected_service)
    VALUES ('ads_evidence','assessment'), ('competitors_evidence','assessment')
    ON CONFLICT (cause_type, affected_service) DO UPDATE SET enabled=true
  $sql$, ns);
END LOOP;
END $mig$;
