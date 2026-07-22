-- 211_archive_status_constraint.sql
-- Allow 'archived' in campaigns_status_check constraint

ALTER TABLE @@SCHEMA@@.campaigns DROP CONSTRAINT IF EXISTS campaigns_status_check;
ALTER TABLE @@SCHEMA@@.campaigns ADD CONSTRAINT campaigns_status_check 
  CHECK (status = ANY (ARRAY['created'::text, 'discovering'::text, 'analyzing'::text, 'awaiting_approval'::text, 'finalizing'::text, 'complete'::text, 'failed'::text, 'canceled'::text, 'archived'::text]));
