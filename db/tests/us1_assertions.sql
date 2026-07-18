-- us1_assertions.sql (T042/T043 — US1 checkpoint validation)
--
-- Asserts the US1 guarantees against ACTUAL produced data in a namespace (default
-- `leadgen`; pass -v schema=leadgen_dryrun for the dry-run copy). Any failed
-- assertion RAISEs -> ON_ERROR_STOP exits nonzero. Run: scripts/validate-us1.ps1.
--
-- SCOPE / HONESTY: this validates the invariants exercisable by the shipped US1
-- spine (Discovery -> Website Auditor+vision -> Scorer -> Sweeper finalization).
-- Two spec items are DEFERRED because their producers do not exist yet:
--   * fabricated-quote rejection (needs Review Miner + quote-checker; Apify-blocked)
--     -> A2 asserts the GENERAL invariant (no score references rejected evidence),
--        which holds now and will catch a bad quote once Review Miner ships.
--   * fixture-pinned golden leads (gold-p1..) + dry-run-namespace execution need
--     dry-run workflow variants; the golden/expectations.json bands are checked by
--     T043's live golden run once those exist. Determinism (SC-007) is covered here
--     by A8 (published fit == exact recomputation from stored score_components).

\set ON_ERROR_STOP 1
\if :{?schema}
\else
  \set schema leadgen
\endif
SET search_path = :schema, public;

CREATE FUNCTION pg_temp._assert(p_ok boolean, p_name text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'ASSERTION FAILED: %', p_name;
  END IF;
  RAISE NOTICE 'PASS: %', p_name;
END $$;

DO $$
DECLARE
  v_current int;
  v_finalized int;
BEGIN
  SELECT count(*) INTO v_current FROM lead_assessments WHERE is_current;
  PERFORM pg_temp._assert(v_current > 0,
    'precondition: at least one current assessment exists to validate');

  -- A1 Traceability: every scored fit point comes from a stored evidence item,
  -- EXCEPT Scorer-internal derived features (scoring-defaults: fits_in_midband_count,
  -- best/second fit, completeness — computed from other scored values, no producer).
  PERFORM pg_temp._assert(NOT EXISTS (
    SELECT 1 FROM score_components sc JOIN lead_assessments a ON a.id = sc.assessment_id
     WHERE a.is_current
       AND sc.product IN ('web_seo','voice_ai','ads_video','consulting')
       AND sc.feature_key NOT IN ('fits_in_midband_count','best_fit','second_fit','completeness')
       AND sc.points > 0
       AND (sc.evidence_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM evidence_items e WHERE e.id = sc.evidence_id))
  ), 'A1 every scored fit point traces to a stored evidence item (derived features excluded)');

  -- A2 Confirmed-only: no scored component references evidence whose latest
  -- verification event is a rejection (the generalized fabricated-quote guard).
  PERFORM pg_temp._assert(NOT EXISTS (
    SELECT 1 FROM score_components sc
      JOIN lead_assessments a ON a.id = sc.assessment_id
      JOIN LATERAL (
        SELECT status FROM evidence_verification_events v
         WHERE v.evidence_id = sc.evidence_id
         ORDER BY v.verified_at DESC NULLS LAST LIMIT 1
      ) latest ON true
     WHERE a.is_current AND sc.points > 0 AND latest.status = 'rejected'
  ), 'A2 no scored point references rejected evidence');

  -- A3 hot_candidate AND-gate: candidate IFF opportunity>=75 AND confidence>=60
  -- (US1-computable dimensions; contactability is US2).
  PERFORM pg_temp._assert(NOT EXISTS (
    SELECT 1 FROM lead_assessments a JOIN campaign_leads cl ON cl.id = a.campaign_lead_id
     WHERE a.is_current
       AND coalesce(cl.hot_candidate,false)
           <> (a.opportunity_score >= 75 AND a.evidence_confidence >= 60)
  ), 'A3 hot_candidate == (opportunity>=75 AND confidence>=60)');

  -- A4 Classification matches opportunity thresholds (warm>=60, cold>=40, else dq).
  PERFORM pg_temp._assert(NOT EXISTS (
    SELECT 1 FROM lead_assessments a JOIN campaign_leads cl ON cl.id = a.campaign_lead_id
     WHERE a.is_current AND cl.classification IS NOT NULL
       AND cl.classification <> CASE
             WHEN a.opportunity_score >= 60 THEN 'warm'
             WHEN a.opportunity_score >= 40 THEN 'cold'
             ELSE 'disqualified' END
  ), 'A4 classification consistent with opportunity thresholds');

  -- A5 No-website leads are scored as prime redesign prospects (fit_web_seo>=85).
  -- This is the Fix-A guarantee: a missing site must not be silently unscored.
  PERFORM pg_temp._assert(NOT EXISTS (
    SELECT 1 FROM lead_assessments a
      JOIN campaign_leads cl ON cl.id = a.campaign_lead_id
      JOIN evidence_items e ON e.business_id = cl.business_id
     WHERE a.is_current AND e.feature_key = 'website_present'
       AND e.value_jsonb = 'false'::jsonb
       AND a.fit_web_seo < 85
  ), 'A5 no-website leads score fit_web_seo>=85 (redesign signal)');

  -- A6 US1 has no verified contacts, so contactability must be 0 everywhere
  -- (this is why Hot cannot exist at the US1 checkpoint).
  PERFORM pg_temp._assert(NOT EXISTS (
    SELECT 1 FROM lead_assessments a
     WHERE a.is_current AND coalesce(a.contactability_score,0) <> 0
  ), 'A6 contactability_score = 0 for all US1 assessments');

  -- A7 At least one campaign reached a defined terminal state with a quality_state.
  SELECT count(*) INTO v_finalized FROM campaigns
   WHERE status = 'complete' AND quality_state IS NOT NULL;
  PERFORM pg_temp._assert(v_finalized > 0,
    'A7 a campaign reached terminal state (complete + quality_state)');

  -- A8 Determinism / exact replay (SC-007): each published fit equals the capped
  -- sum of its stored score_components, i.e. the score is reproducible from stored
  -- evidence with no hidden state (tolerance 0.02 for float rounding).
  PERFORM pg_temp._assert(NOT EXISTS (
    WITH sums AS (
      SELECT a.id AS aid,
        LEAST(100, coalesce(sum(sc.points) FILTER (WHERE sc.product='web_seo'),0))    AS web_seo,
        LEAST(100, coalesce(sum(sc.points) FILTER (WHERE sc.product='voice_ai'),0))   AS voice_ai,
        LEAST(100, coalesce(sum(sc.points) FILTER (WHERE sc.product='ads_video'),0))  AS ads_video,
        LEAST(100, coalesce(sum(sc.points) FILTER (WHERE sc.product='consulting'),0)) AS consulting
      FROM lead_assessments a
      LEFT JOIN score_components sc ON sc.assessment_id = a.id
      WHERE a.is_current
      GROUP BY a.id
    )
    SELECT 1 FROM sums s JOIN lead_assessments a ON a.id = s.aid
     WHERE abs(a.fit_web_seo   - s.web_seo)   > 0.02
        OR abs(a.fit_voice_ai  - s.voice_ai)  > 0.02
        OR abs(a.fit_ads_video - s.ads_video) > 0.02
        OR abs(a.fit_consulting- s.consulting)> 0.02
  ), 'A8 each published fit == capped sum of its score_components (SC-007 replay)');

  RAISE NOTICE '--- US1 assertions all passed for schema % ---', current_schema();
END $$;
