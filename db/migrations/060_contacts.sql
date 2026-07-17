-- 060_contacts.sql (T013)
-- contacts, contact_business_links, contact_channels, three referential
-- verification tables (no polymorphic FKs), campaign_contact_findings,
-- suppressions — both namespaces.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$

CREATE TABLE IF NOT EXISTS %1$I.contacts (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name    text NOT NULL,
  linkedin_url text,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Role-at-business: multiple decision-makers per business; buyer differs per product
CREATE TABLE IF NOT EXISTS %1$I.contact_business_links (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id         uuid NOT NULL REFERENCES %1$I.contacts(id),
  business_id        uuid NOT NULL REFERENCES %1$I.businesses(id),
  title              text,
  role_type          text NOT NULL CHECK (role_type IN
                       ('owner','founder','gm','office_manager','marketing','operations','it','other')),
  relevant_products  text[] NOT NULL DEFAULT '{}',
  confidence         numeric(4,3) CHECK (confidence BETWEEN 0 AND 1),
  source_evidence_id uuid REFERENCES %1$I.evidence_items(id),
  active             boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_id, business_id, role_type)
);
CREATE INDEX IF NOT EXISTS cbl_business_idx ON %1$I.contact_business_links (business_id);

CREATE TABLE IF NOT EXISTS %1$I.contact_channels (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id       uuid NOT NULL REFERENCES %1$I.contacts(id),
  channel          text NOT NULL CHECK (channel IN ('email','phone')),
  value            text NOT NULL,
  value_normalized text NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contact_id, channel, value_normalized)
);

-- Three verification tables: referentially enforced, no subject_type/subject_id.
-- Verification decays: expires_at removes contactability credit (FR-020).
CREATE TABLE IF NOT EXISTS %1$I.contact_identity_verifications (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id      uuid NOT NULL REFERENCES %1$I.contacts(id),
  method          text NOT NULL,
  status          text NOT NULL CHECK (status IN ('verified','unverified','failed')),
  verified_at     timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  idempotency_key text NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS %1$I.contact_channel_verifications (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_channel_id uuid NOT NULL REFERENCES %1$I.contact_channels(id),
  method             text NOT NULL,          -- hunter_verify | ...
  status             text NOT NULL CHECK (status IN ('deliverable','risky','undeliverable','unknown')),
  verified_at        timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,
  idempotency_key    text NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS %1$I.contact_role_verifications (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_business_link_id uuid NOT NULL REFERENCES %1$I.contact_business_links(id),
  method                   text NOT NULL,    -- source_attestation (deterministic check)
  status                   text NOT NULL CHECK (status IN ('attested','unattested','failed')),
  source_url               text,
  verified_at              timestamptz NOT NULL DEFAULT now(),
  expires_at               timestamptz NOT NULL,
  idempotency_key          text NOT NULL UNIQUE
);

-- Campaign provenance: later campaigns' discoveries never rewrite older
-- campaigns' contactability
CREATE TABLE IF NOT EXISTS %1$I.campaign_contact_findings (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_lead_id         uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
  contact_business_link_id uuid REFERENCES %1$I.contact_business_links(id),
  contact_channel_id       uuid REFERENCES %1$I.contact_channels(id),
  service_run_id           uuid NOT NULL REFERENCES %1$I.service_runs(id),
  discovered_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ccf_lead_idx ON %1$I.campaign_contact_findings (campaign_lead_id);

-- Five-level suppression; business-level rows are the single source from which
-- visible do-not-contact is derived (FR-027)
CREATE TABLE IF NOT EXISTS %1$I.suppressions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  level           text NOT NULL CHECK (level IN ('email','phone','contact','business','domain')),
  value           text NOT NULL,        -- normalized email/phone/uuid/domain
  reason          text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL UNIQUE,
  UNIQUE (level, value)
);

$ddl$, ns);
END LOOP;
END $mig$;
