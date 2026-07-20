-- 150_lead_reports_grant.sql
-- lead_reports (120) was created AFTER 100_privileges.sql, whose GRANT SELECT ON ALL
-- TABLES only covers tables existing at that point ("future tables default to no
-- privileges" — 100_privileges.sql). The Ops Console reads report_url from lead_reports,
-- so the workflow read-roles need explicit SELECT on it. Read-only; no DML. Idempotent.

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text; sfx text; r text;
  roles text[] := ARRAY['analyzer','scorer','enricher','sweeper','relay','human','dashboard'];
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
  sfx := CASE WHEN ns = 'leadgen_dryrun' THEN '_dryrun' ELSE '' END;
  FOREACH r IN ARRAY roles LOOP
    EXECUTE format('GRANT SELECT ON %I.lead_reports TO %I', ns, 'leadgen_' || r || sfx);
  END LOOP;
END LOOP;
END $mig$;
