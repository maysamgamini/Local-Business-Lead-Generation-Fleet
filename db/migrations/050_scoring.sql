-- 050_scoring.sql (T012)
-- lead_assessments (is_current publication rule + partial unique), score_components,
-- score_log, critic_reviews — both namespaces.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

CREATE TABLE IF NOT EXISTS %1$I.lead_assessments (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id     uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  scoring_version      text NOT NULL,               -- content_hash of pinned scoring set
  fit_web_seo          numeric(5,2) NOT NULL CHECK (fit_web_seo    BETWEEN 0 AND 100),
  fit_voice_ai         numeric(5,2) NOT NULL CHECK (fit_voice_ai   BETWEEN 0 AND 100),
  fit_ads_video        numeric(5,2) NOT NULL CHECK (fit_ads_video  BETWEEN 0 AND 100),
  fit_consulting       numeric(5,2) NOT NULL CHECK (fit_consulting BETWEEN 0 AND 100),
  opportunity_score    numeric(5,2) NOT NULL CHECK (opportunity_score   BETWEEN 0 AND 100),
  contactability_score numeric(5,2) NOT NULL CHECK (contactability_score BETWEEN 0 AND 100),
  evidence_confidence  numeric(5,2) NOT NULL CHECK (evidence_confidence BETWEEN 0 AND 100),
  completeness         numeric(4,3) NOT NULL CHECK (completeness BETWEEN 0 AND 1),
  best_angle           text,
  evidence_watermark   bigint NOT NULL,             -- lead_revision consumed
  scored_at            timestamptz NOT NULL DEFAULT now(),
  is_current           boolean NOT NULL DEFAULT false,
  superseded_at        timestamptz
);
-- Stale results insert is_current=false and never move the pointer; at most one
-- current assessment per lead (review round 5, finding 4 + uniqueness DDL).
CREATE UNIQUE INDEX IF NOT EXISTS one_current_assessment_per_lead
  ON %1$I.lead_assessments (campaign_lead_id) WHERE is_current = true;
CREATE INDEX IF NOT EXISTS assessments_lead_idx
  ON %1$I.lead_assessments (campaign_lead_id, scored_at DESC);

-- Every point mechanically explained (SC-003)
CREATE TABLE IF NOT EXISTS %1$I.score_components (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assessment_id     uuid NOT NULL REFERENCES %1$I.lead_assessments(id),
  product           text NOT NULL CHECK (product IN
                      ('web_seo','voice_ai','ads_video','consulting',
                       'opportunity','contactability','confidence')),
  feature_key       text NOT NULL,
  observed_value    jsonb,
  transformed_value numeric(10,4),
  weight            numeric(8,4) NOT NULL,
  points            numeric(8,4) NOT NULL,
  evidence_id       uuid REFERENCES %1$I.evidence_items(id)  -- null only for scorer-internal derived
);
CREATE INDEX IF NOT EXISTS score_components_assessment_idx
  ON %1$I.score_components (assessment_id);

CREATE TABLE IF NOT EXISTS %1$I.score_log (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id       uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  previous_assessment_id uuid REFERENCES %1$I.lead_assessments(id),
  current_assessment_id  uuid NOT NULL REFERENCES %1$I.lead_assessments(id),
  change_reason          text NOT NULL,
  ts                     timestamptz NOT NULL DEFAULT now()
);

-- Durable prosecutor record: critic never writes scores or verification outcomes
CREATE TABLE IF NOT EXISTS %1$I.critic_reviews (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  assessment_id    uuid NOT NULL REFERENCES %1$I.lead_assessments(id),
  critic_type      text NOT NULL,
  input_version    bigint NOT NULL,
  state            text NOT NULL DEFAULT 'open' CHECK (state IN ('open','reverifying','resolved')),
  objections_json  jsonb,
  resolution       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  resolved_at      timestamptz
);
CREATE INDEX IF NOT EXISTS critic_reviews_lead_idx
  ON %1$I.critic_reviews (campaign_lead_id, created_at DESC);

$ddl$, ns);
END LOOP;
END $mig$;
