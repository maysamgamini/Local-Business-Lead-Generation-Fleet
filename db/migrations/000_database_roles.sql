-- 000_database_roles.sql
-- Cluster/database-level roles and the two namespaces.
-- Passwords arrive as psql variables (deploy-db.ps1 injects from env): never committed.
-- NOTE: psql variables do NOT interpolate inside dollar-quoted DO bodies, so role
-- creation uses top-level SELECT format(...) \gexec, where :'var' works.
-- Privilege model (100_privileges.sql): workflow roles get SELECT + EXECUTE on
-- approved functions ONLY; direct DML on protected tables is revoked there.

\set ON_ERROR_STOP 1

-- Schemas -----------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS leadgen;
CREATE SCHEMA IF NOT EXISTS leadgen_dryrun;

-- Roles: create-or-update, production + dry-run twin per service class ------
SELECT format(
  CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r.name)
       THEN 'ALTER ROLE %I WITH LOGIN PASSWORD %L'
       ELSE 'CREATE ROLE %I LOGIN PASSWORD %L' END,
  r.name, r.pw)
FROM (VALUES
  ('leadgen_analyzer',          :'pw_analyzer'),
  ('leadgen_scorer',            :'pw_scorer'),
  ('leadgen_enricher',          :'pw_enricher'),
  ('leadgen_sweeper',           :'pw_sweeper'),
  ('leadgen_relay',             :'pw_relay'),
  ('leadgen_human',             :'pw_human'),
  ('leadgen_dashboard',         :'pw_dashboard'),
  ('leadgen_analyzer_dryrun',   :'pw_analyzer'),
  ('leadgen_scorer_dryrun',     :'pw_scorer'),
  ('leadgen_enricher_dryrun',   :'pw_enricher'),
  ('leadgen_sweeper_dryrun',    :'pw_sweeper'),
  ('leadgen_relay_dryrun',      :'pw_relay'),
  ('leadgen_human_dryrun',      :'pw_human'),
  ('leadgen_dashboard_dryrun',  :'pw_dashboard')
) AS r(name, pw)
\gexec

-- Baseline: schema usage only; object grants come with 100_privileges.sql ----
GRANT USAGE ON SCHEMA leadgen
  TO leadgen_analyzer, leadgen_scorer, leadgen_enricher, leadgen_sweeper,
     leadgen_relay, leadgen_human, leadgen_dashboard;
GRANT USAGE ON SCHEMA leadgen_dryrun
  TO leadgen_analyzer_dryrun, leadgen_scorer_dryrun, leadgen_enricher_dryrun,
     leadgen_sweeper_dryrun, leadgen_relay_dryrun, leadgen_human_dryrun,
     leadgen_dashboard_dryrun;

-- Cross-namespace isolation (defense in depth on top of static function binding)
REVOKE ALL ON SCHEMA leadgen_dryrun FROM
  leadgen_analyzer, leadgen_scorer, leadgen_enricher, leadgen_sweeper,
  leadgen_relay, leadgen_human, leadgen_dashboard;
REVOKE ALL ON SCHEMA leadgen FROM
  leadgen_analyzer_dryrun, leadgen_scorer_dryrun, leadgen_enricher_dryrun,
  leadgen_sweeper_dryrun, leadgen_relay_dryrun, leadgen_human_dryrun,
  leadgen_dashboard_dryrun;
