-- 040_evidence.sql (T011)
-- evidence_items (IMMUTABLE, typed values, scoped idempotency), evidence_links
-- (lineage; composite PK; self-link CHECK; cycle check lives in the insertion
-- function), evidence_verification_events (event-sourced; idempotency-keyed).

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

CREATE TABLE IF NOT EXISTS %1$I.evidence_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         uuid NOT NULL REFERENCES %1$I.businesses(id),
  campaign_id         uuid NOT NULL REFERENCES %1$I.campaigns(id),
  service             text NOT NULL,
  feature_key         text NOT NULL,
  product_tag         text CHECK (product_tag IN
                        ('web_seo','voice_ai','ads_video','consulting','firmographic')),
  value_jsonb         jsonb NOT NULL,               -- THE machine-readable value
  value_type          text  NOT NULL CHECK (value_type IN
                        ('boolean','integer','decimal','string','enum','object')),
  unit                text,                          -- percent|count|ms|rank|score|...
  confidence          numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
  calculation_version text,
  source_provider     text NOT NULL,
  source_record_id    text,
  source_url          text,
  source_fetched_at   timestamptz,
  observed_at         timestamptz NOT NULL DEFAULT now(),
  content_hash        text,
  excerpt             text,                          -- human explanation ONLY, never parsed
  service_run_id      uuid NOT NULL REFERENCES %1$I.service_runs(id),
  idempotency_key     text NOT NULL,
  -- scoped uniqueness: campaigns never collide on the same underlying fact
  CONSTRAINT evidence_idem_scoped UNIQUE (campaign_id, service, idempotency_key)
);
CREATE INDEX IF NOT EXISTS evidence_campaign_feature_idx
  ON %1$I.evidence_items (campaign_id, business_id, feature_key);
CREATE INDEX IF NOT EXISTS evidence_business_idx
  ON %1$I.evidence_items (business_id, feature_key);

-- Lineage: derived evidence never double-counts its roots (lineage_policy)
CREATE TABLE IF NOT EXISTS %1$I.evidence_links (
  parent_evidence_id uuid NOT NULL REFERENCES %1$I.evidence_items(id),
  child_evidence_id  uuid NOT NULL REFERENCES %1$I.evidence_items(id),
  relationship_type  text NOT NULL CHECK (relationship_type IN
                       ('derived_from','supports','contradicts','supersedes','aggregates')),
  PRIMARY KEY (parent_evidence_id, child_evidence_id, relationship_type),
  CHECK (parent_evidence_id <> child_evidence_id)
);
CREATE INDEX IF NOT EXISTS evidence_links_child_idx ON %1$I.evidence_links (child_evidence_id);

-- Event-sourced verification: latest event wins; only 'confirmed' scores.
-- Idempotency: duplicate deliveries can never re-insert or bump lead_revision.
CREATE TABLE IF NOT EXISTS %1$I.evidence_verification_events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id     uuid NOT NULL REFERENCES %1$I.evidence_items(id),
  status          text NOT NULL CHECK (status IN ('confirmed','rejected','superseded','disputed')),
  reason          text,
  verifier        text NOT NULL,      -- named deterministic verifier or critic id
  verified_at     timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL UNIQUE
);
-- Latest-event lookup (contracted index)
CREATE INDEX IF NOT EXISTS verification_latest_idx
  ON %1$I.evidence_verification_events (evidence_id, verified_at DESC, id DESC);

$ddl$, ns);
END LOOP;
END $mig$;
