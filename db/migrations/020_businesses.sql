-- 020_businesses.sql (T009)
-- businesses, business_relationships, business_sales_state, campaign_leads,
-- campaign_lead_dispositions, discovery_observations — both namespaces.
-- Cross-file FKs (latest_assessment_id -> lead_assessments, evidence refs) in 090.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

-- CURRENT identity of a real-world location. Durable across campaigns.
CREATE TABLE IF NOT EXISTS %1$I.businesses (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  place_id              text UNIQUE,                  -- primary dedup key (nullable: rare non-Places finds)
  business_name         text NOT NULL,
  website_domain        text,
  phone_e164            text,
  address               text,
  lat                   double precision,
  lng                   double precision,
  dedup_key             text NOT NULL,                -- normalized fallback key
  latest_assessment_id  uuid,                         -- convenience pointer (FK in 090)
  latest_summary        jsonb,                        -- dashboard display only
  sales_status          text NOT NULL DEFAULT 'untouched'
                          CHECK (sales_status IN ('untouched','contacted','in_talks','customer','bad_lead')),
                        -- derived from latest business_sales_state row by record_sales_status();
                        -- do-not-contact is NOT here: it derives from active suppressions
  first_seen_campaign_id uuid REFERENCES %1$I.campaigns(id),
  last_updated          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS businesses_dedup_key_idx ON %1$I.businesses (dedup_key);
CREATE INDEX IF NOT EXISTS businesses_domain_idx    ON %1$I.businesses (website_domain);
CREATE INDEX IF NOT EXISTS businesses_phone_idx     ON %1$I.businesses (phone_e164);

-- Typed, evidence-backed multi-location links (never bare shared-domain inference)
CREATE TABLE IF NOT EXISTS %1$I.business_relationships (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         uuid NOT NULL REFERENCES %1$I.businesses(id),
  related_business_id uuid NOT NULL REFERENCES %1$I.businesses(id),
  relationship_type   text NOT NULL CHECK (relationship_type IN
                        ('same_brand','franchise','parent_org','shared_platform','unknown')),
  confidence          numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  evidence_id         uuid,                            -- FK in 090 (evidence_items later file)
  sales_target_level  text NOT NULL CHECK (sales_target_level IN
                        ('location','franchisee','regional','hq')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (business_id <> related_business_id),
  UNIQUE (business_id, related_business_id, relationship_type)
);

-- Append-only audited human sales-status changes (record_sales_status only)
CREATE TABLE IF NOT EXISTS %1$I.business_sales_state (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  uuid NOT NULL REFERENCES %1$I.businesses(id),
  sales_status text NOT NULL CHECK (sales_status IN
                 ('untouched','contacted','in_talks','customer','bad_lead')),
  changed_by   text NOT NULL,
  changed_at   timestamptz NOT NULL DEFAULT now(),
  reason       text
);
CREATE INDEX IF NOT EXISTS business_sales_state_biz_idx
  ON %1$I.business_sales_state (business_id, changed_at DESC);

-- One business's participation in one campaign
CREATE TABLE IF NOT EXISTS %1$I.campaign_leads (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id           uuid NOT NULL REFERENCES %1$I.campaigns(id),
  business_id           uuid NOT NULL REFERENCES %1$I.businesses(id),
  rediscovered          boolean NOT NULL DEFAULT false,
  priority              integer NOT NULL DEFAULT 0,
  lead_revision         bigint  NOT NULL DEFAULT 0,   -- monotonic watermark; advance_lead_revision only
  latest_assessment_id  uuid,                          -- FK in 090 (circular with lead_assessments)
  classification        text CHECK (classification IN ('hot','warm','cold','disqualified')),
  classification_reason text,
  classified_at         timestamptz,
  hot_candidate         boolean NOT NULL DEFAULT false, -- opportunity>=75 AND confidence>=60 (scoring-defaults)
  critic_state          text CHECK (critic_state IN ('pending','reverifying','resolved')),
  contested             boolean NOT NULL DEFAULT false,
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (campaign_id, business_id)
);
CREATE INDEX IF NOT EXISTS campaign_leads_campaign_idx ON %1$I.campaign_leads (campaign_id);
CREATE INDEX IF NOT EXISTS campaign_leads_business_idx ON %1$I.campaign_leads (business_id);

-- Per-delivered-lead human review: the SC-009 data source
CREATE TABLE IF NOT EXISTS %1$I.campaign_lead_dispositions (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  outcome          text NOT NULL CHECK (outcome IN ('accepted','rejected','not_reviewed')),
  reviewed_by      text NOT NULL,
  reviewed_at      timestamptz NOT NULL DEFAULT now(),
  rejection_reason text
);
CREATE INDEX IF NOT EXISTS dispositions_lead_idx
  ON %1$I.campaign_lead_dispositions (campaign_lead_id, reviewed_at DESC);

-- Query/geo/date-scoped discovery facts (serp rank lives here, never on businesses)
CREATE TABLE IF NOT EXISTS %1$I.discovery_observations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  provider         text NOT NULL,
  query            text NOT NULL,
  geo_lat          double precision,
  geo_lng          double precision,
  radius_m         integer,
  rank             integer,
  observed_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS discovery_obs_lead_idx
  ON %1$I.discovery_observations (campaign_lead_id);

$ddl$, ns);
END LOOP;
END $mig$;
