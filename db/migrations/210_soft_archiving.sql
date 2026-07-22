-- 210_soft_archiving.sql
-- Soft-archiving system: adds archived_at timestamp columns to core entities,
-- partial indexes for active items (WHERE archived_at IS NULL), and schema safeguards.

ALTER TABLE @@SCHEMA@@.evidence_items ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;
ALTER TABLE @@SCHEMA@@.campaign_leads ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;
ALTER TABLE @@SCHEMA@@.campaigns ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;
ALTER TABLE @@SCHEMA@@.work_items ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;
ALTER TABLE @@SCHEMA@@.lead_reports ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;
ALTER TABLE @@SCHEMA@@.lead_assessments ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;

-- Partial indexes for active queries (WHERE archived_at IS NULL)
CREATE INDEX IF NOT EXISTS evidence_items_active_idx 
  ON @@SCHEMA@@.evidence_items (business_id, campaign_id, feature_key) 
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS campaign_leads_active_idx 
  ON @@SCHEMA@@.campaign_leads (campaign_id, classification) 
  WHERE archived_at IS NULL;

CREATE INDEX IF NOT EXISTS work_items_active_idx 
  ON @@SCHEMA@@.work_items (campaign_lead_id, service, state) 
  WHERE archived_at IS NULL;
