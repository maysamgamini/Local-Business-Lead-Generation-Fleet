-- 120_lead_reports.sql — client-facing report registry (Report Generator, US4-adjacent)
-- One current report per lead (regeneration upserts). Stores the shareable bucket URL,
-- the object key, and a short summary. The `html` column exists but is left empty by the
-- generator (bucket-only delivery, no DB copy — per product decision); reports regenerate
-- from the ledger anyway. The S3 object is the single served copy.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  CREATE TABLE IF NOT EXISTS %1$I.lead_reports (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_lead_id uuid NOT NULL REFERENCES %1$I.campaign_leads(id),
    business_id      uuid,
    campaign_id      uuid,
    best_angle       text,
    report_url       text,
    object_key       text,
    summary          text,
    html             text,
    generated_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (campaign_lead_id)
  );
$ddl$, ns);
END LOOP;
END $mig$;
