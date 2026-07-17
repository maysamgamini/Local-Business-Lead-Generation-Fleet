# Implementation Plan: Local Business Lead Generation Fleet

**Branch**: `001-leadgen-fleet` | **Date**: 2026-07-16 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-leadgen-fleet/spec.md`

**Source-of-truth precedence (highest first)**: 1. `spec.md` → 2. `contracts/*` → 3. `data-model.md` → 4. `tasks.md` → 5. `plan.md` → 6. the historical design document ([docs/superpowers/specs/2026-07-16-leadgen-fleet-design.md](../../docs/superpowers/specs/2026-07-16-leadgen-fleet-design.md), v4 + addendum — five review rounds of rationale and history; where its older sections contradict the contracts, **the contracts win**).

## Summary

A choreographed fleet of independent n8n workflows researches local businesses per campaign request (form / scheduled sheet / authenticated webhook), scores every lead against four agency product lines with verifiable evidence, enriches above-threshold leads with verified decision-maker contacts under budget reservation, and delivers digest + snapshot + live dashboard. Technical approach: pull-based work queue and transactional outbox in PostgreSQL, with **every state mutation behind SECURITY DEFINER SQL functions** called from single n8n Postgres nodes (n8n nodes autocommit — multi-node write sequences are not atomic); deterministic scoring from immutable typed evidence; caged LLM agents with hard tool caps; cross-model one-time critics.

## Technical Context

**Language/Version**: n8n workflows (self-hosted, current LTS, queue mode); PostgreSQL 16 + PL/pgSQL for the transactional API; JavaScript in n8n Code nodes (external task-runner mode in production)

**Primary Dependencies**: n8n + Redis (queue mode); PostgreSQL; data providers — Google Places API, SerpAPI, Apify actors (Google/Yelp reviews), Apollo (contacts), Hunter (email verify), PageSpeed Insights API; LLM providers — Anthropic Claude (judgment: site assessment, hot-lead critic), OpenAI + Google Gemini (bulk extraction/classification; critics always cross-family from generator)

**Storage**: PostgreSQL — separate database `leadgen_db` + separate DB users/roles on the existing self-hosted cluster; isolated `leadgen_dryrun` schema for dry-run campaigns; Airtable (write-only dashboard mirror), Google Sheets (ICP input sheet read by Scheduled Intake only; output snapshots write-only), Slack (milestones/alerts)

**Testing**: SQL-level tests for the transactional API (race/failure injection via parallel psql sessions); per-service contract tests with fixture payloads + n8n pinned data; dry-run campaigns (fixture providers, real LLM calls); golden campaign (~10 hand-labeled businesses) re-run on any config-set change; critic evals with seeded failures

**Target Platform**: Self-hosted Docker (n8n main + workers + Redis + Postgres on existing infrastructure)

**Project Type**: Workflow-automation fleet (11 n8n services) + database transactional core — no application code outside n8n and PL/pgSQL

**Performance Goals**: Standard-depth campaign of up to 300 businesses → delivered digest in < 2 hours (SC-001); 3 concurrent campaigns with all guarantees intact (SC-011); dashboard reflects analyzer completions within one poll interval (≤ 2 min)

**Constraints**: Budget cap never exceeded — atomic max-billable authorization with `actual ≤ maximum` enforced at settle (SC-005); deterministic replay reproducibility under pinned config sets (SC-007); provider rate limits enforced globally per credential (token bucket + tokened, renewable permits); workflows have zero direct DML on protected tables; third-party corpora ephemeral, assets reference-only in v1 — `storage_ref` stays NULL (FR-026)

**Scale/Scope**: ≤ 300 businesses/campaign (intake-rejected above), 3 concurrent campaigns, ~4 analyzers + scorer + enricher per lead ⇒ ~2,000–3,000 work items per max campaign; 10 active service roles (16 deployed n8n workflow definitions; Asset Collector deferred to v2) + ~30 SQL functions (deployed twice: `leadgen` + `leadgen_dryrun` namespaces) + ~41 tables

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is an unfilled template — **no ratified project constitution exists**. No gates to evaluate; nothing to violate. Recommendation (non-blocking): run `/speckit-constitution` after this feature to ratify the principles this design already embodies (workflows-as-runtime / SQL-as-transactional-core; evidence provenance; deterministic scoring; spend safety). Re-checked after Phase 1: still no constitution; no violations to track.

## Project Structure

### Documentation (this feature)

```text
specs/001-leadgen-fleet/
├── plan.md              # This file
├── research.md          # Phase 0 — consolidated decisions (from design v4)
├── data-model.md        # Phase 1 — entities, relationships, state machines
├── quickstart.md        # Phase 1 — setup + end-to-end validation scenarios
├── contracts/
│   ├── canonical-request.md   # Intake contract (all three channels)
│   ├── sql-api.md             # Transactional function API (the core contract)
│   └── service-contracts.md   # Per-service I/O, queue + event semantics
└── tasks.md             # Task breakdown (65 tasks, 7 phases — generated, restructured after task-graph review)
```

### Source Code (repository root)

```text
db/
├── migrations/          # Ordered DDL: schema, tables, indexes, constraints, roles
├── functions/           # PL/pgSQL transactional API (one file per function)
├── seeds/               # config_sets, scoring_config, chain_rules,
│                        #   revision_impact_rules, service_config, provider_limits
└── tests/               # SQL race/failure-injection tests (psql scripts)

workflows/               # Exported n8n workflow JSON (source of truth, version-controlled)
├── intake-form.json
├── intake-schedule.json
├── intake-webhook.json
├── discovery.json
├── website-auditor.json
├── review-miner.json
├── phone-presence.json
├── contact-enricher.json
├── scorer.json
├── sweeper.json
├── event-relay.json
├── dashboard-sync.json
├── approval-form.json
├── sales-action-form.json  # human sales-status / disposition actions (FR-027)
├── fetch-page.json         # shared hardened fetch sub-workflow (SSRF cage)
└── error-handler.json   # global Error Trigger workflow

fixtures/                # Provider response fixtures (dry-run + contract tests)
├── README.md            # Supported fixture request_ids, planted failure cases,
│                        #   expected synthetic charges, expected evidence & scores
├── places/  ├── serpapi/  ├── apify-reviews/  ├── apollo/  ├── hunter/  └── psi/

golden/                  # Golden-campaign labeled expectations
├── request.json  ├── expectations.json  └── baseline.md   # pinned reference deployment
scripts/                 # deploy-db.ps1, import-workflows.ps1, run-race-tests.ps1
docs/superpowers/specs/  # Governing technical design (v4 + plan-consistency addendum)
```

**Structure Decision**: Two-tier repository — `db/` is the transactional core (deployed first, owns all invariants — including the contracted `healthcheck()` function and `stuck_work_overview` / `campaign_progress` views in `db/migrations/*views.sql`), `workflows/` is the n8n runtime layer (imports via n8n CLI/API, holds zero invariants). **Count reconciliation: 10 active service roles (Asset Collector deferred to v2 — schema ships, chain rule disabled), 16 deployed workflow definitions** (3 intakes + 9 operational incl. dashboard-sync + approval form + sales-action form + shared fetch-page sub-workflow + error handler). Fixtures and golden expectations are first-class, version-controlled artifacts because the test strategy depends on them; the exact n8n version is pinned in `golden/baseline.md` at deploy time.

## Complexity Tracking

No constitution exists, so no gate violations to justify. One deliberate complexity note for the record: the SQL transactional API (~30 functions, deployed in both namespaces) is load-bearing complexity — it exists because n8n Postgres nodes autocommit per node, making multi-node write sequences non-atomic. The simpler alternative (plain inserts/updates from workflow nodes) was rejected across three design-review rounds for concrete race conditions documented in the design doc's Decisions Log (stale-worker commits, budget TOCTOU, concurrency-cap bypass, finalization races).
