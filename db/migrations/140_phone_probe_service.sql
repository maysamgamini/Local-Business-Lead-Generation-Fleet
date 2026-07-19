-- 140_phone_probe_service.sql
-- Adds the warm-gated 'phone_probe' fleet service: an active Twilio Answering-Machine-Detection
-- probe-caller (Phone Presence V2). Mirrors 'social' (130): created 'blocked' at discovery,
-- opened to 'pending' by the Scorer when a lead turns warm/hot, skipped otherwise. Extends the
-- work_items.service CHECK. Ships DISABLED (service_config seed enabled=false) because it places
-- REAL outbound calls — flip enabled=true when ready to auto-probe warm leads.
\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text;
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
EXECUTE format($ddl$
  ALTER TABLE %1$I.work_items DROP CONSTRAINT IF EXISTS work_items_service_check;
  ALTER TABLE %1$I.work_items ADD CONSTRAINT work_items_service_check CHECK (service IN
    ('discovery','website','reviews','phone','enrichment','assessment','assets','social','phone_probe'));
$ddl$, ns);
END LOOP;
END $mig$;
