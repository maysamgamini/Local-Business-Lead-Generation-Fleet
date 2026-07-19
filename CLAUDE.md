# CLAUDE.md — Local Business Lead Generation Fleet

Agentic lead-research system: a **choreographed fleet of n8n workflows over a PostgreSQL transactional core**. n8n owns behavior; Postgres owns correctness.

## Architecture (the non-negotiables)
- **Every state mutation goes through a SECURITY DEFINER PL/pgSQL function** called from a *single* n8n Postgres node (n8n nodes autocommit — multi-node write sequences are not atomic). Workflows hold SELECT + EXECUTE only; **no direct DML** on protected tables.
- **Fenced pull queue**: `work_items` claimed via `claim_work_items(service, worker_id)` with `claim_token` + `lease_expires_at`; universal fence `state='running' AND claim_token=? AND lease_expires_at>now()`. Each worker = 1-min schedule poll + poke webhook; an empty poll is one cheap DB query (no paid API).
- **Immutable evidence ledger**: `evidence_items` are append-only, latest-wins per `(business_id, campaign_id, feature_key)`. **Never delete evidence** — repair by appending a corrective observation via `leadgen._insert_evidence`. Scoring reads only latest-`confirmed` evidence; every score point traces to a `score_components` row.
- **Dual namespaces**: `leadgen` (prod) + `leadgen_dryrun`, each with the full function set on a pinned `search_path`.

## Source-of-truth precedence
`specs/001-leadgen-fleet/spec.md` → `contracts/*` → `data-model.md` → `tasks.md` → `plan.md` → historical design doc. Deployed-workflow inventory + credentials: `workflows/README.md`.

## Deploying
- **DB**: `db/migrations/*` (ordered, both namespaces via `%1$I` loop) + `db/functions/*` (`@@SCHEMA@@` token, rendered per namespace) + `db/seeds/*`. Runner: `scripts/deploy-db.ps1`. Ad-hoc, functions apply per namespace: `sed 's/@@SCHEMA@@/leadgen/g' file.sql | psql`.
- **Workflows**: source of truth is `workflows/*.sdk.ts` (n8n Workflow SDK), deployed via the n8n MCP (`create_workflow_from_code` / `update_workflow` → `publish_workflow`). Postgres query params that embed `{{ }}` must start with `=` (expression prefix).

## Secrets — NEVER commit
Apify token, Gemini/PSI/Yelp/SerpApi keys, AWS access key/secret, n8n Bearer, DB passwords. They live in the n8n DB (Code nodes / request URLs / credentials); redact to `<<PLACEHOLDER>>` in the `.sdk.ts` archives. Never commit `.mcp.json`, `*.pem`, `.env`. Commits are `--no-gpg-sign`; branch off `main` before committing.

## Key decisions (see tasks.md Phase 8 + research R-16..R-18)
- **Target market: small local SMBs** — signal design favors free homepage parsing + social-activity scraping over website-traffic estimates. **Similarweb dropped** (needs ~5k monthly visits; empty for SMBs).
- **Scoring thresholds + opportunity formula are hardcoded in the Scorer Code node** (`r0K3xkLN2XtUceTF`), NOT read from `scoring_config` (which documents intent). Warm = opportunity ≥45.
- **Fleet services**: discovery, website, reviews, phone, enrichment (US2), assessment, assets (v2), **social** (warm-gated Apify IG/FB/TikTok activity, 2026-07-18). Form intake never requires approval.
- **Report Generator** (`LD2ujo15iFNfrhEM`): per-prospect audit/pitch, auto-fired by the Sweeper on finalization; bucket-only secret-link delivery; brand "HiLeadDiscovery Studio".

## Infra
n8n + Postgres on AWS Lightsail (Docker). DB is inside `n8n-postgres-1`: `sudo docker exec n8n-postgres-1 psql -U n8n_root -d leadgen_db`. Queue mode (main + workers + Redis). n8n URL: `n8n.hiwebenterprise.com`.
