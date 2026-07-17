-- 100_privileges.sql (T027, part 1: tables/views)
-- Workflow roles: SELECT only on tables — ZERO direct DML. All mutations go
-- through SECURITY DEFINER functions (grants for those live in
-- db/functions/zz_grants.sql, deployed after the functions exist).

\set ON_ERROR_STOP 1

DO $mig$
DECLARE ns text; sfx text; r text;
  roles text[] := ARRAY['analyzer','scorer','enricher','sweeper','relay','human','dashboard'];
BEGIN
FOREACH ns IN ARRAY ARRAY['leadgen','leadgen_dryrun'] LOOP
  sfx := CASE WHEN ns = 'leadgen_dryrun' THEN '_dryrun' ELSE '' END;
  FOREACH r IN ARRAY roles LOOP
    -- revoke everything, then grant read-only
    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM %I',
                   ns, 'leadgen_' || r || sfx);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I',
                   ns, 'leadgen_' || r || sfx);
  END LOOP;
  -- future tables in this schema default to no privileges for these roles
  -- (deploys are explicit; nothing is granted implicitly)
END LOOP;
END $mig$;
