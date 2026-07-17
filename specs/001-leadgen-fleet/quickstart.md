# Quickstart & Validation Guide: Lead Generation Fleet

How to stand the system up and prove it works, end to end. References: [data-model.md](./data-model.md), [contracts/](./contracts/), governing design doc v4.

## Prerequisites

- Self-hosted n8n (current LTS) in **queue mode**: main + ≥2 workers + Redis; **external task-runner mode** enabled for Code nodes.
- PostgreSQL 16 on the existing cluster; ability to create database `leadgen_db`, roles, and the `leadgen_dryrun` schema.
- Credentials configured in n8n: Google Places, SerpAPI, Apify, Apollo, Hunter, PageSpeed Insights, Anthropic, OpenAI, Google AI, Slack, Airtable, Google Sheets.
- Provider spend: a golden-campaign run costs low single-digit USD; dry-run scenarios cost only LLM tokens.

## Setup

```powershell
# 1. Database core (migrations create schema, tables, indexes, roles, functions, seeds)
./scripts/deploy-db.ps1 -Database leadgen_db

# 2. Import workflows into n8n (source of truth is workflows/*.json)
./scripts/import-workflows.ps1

# 3. Seed config sets and activate v1
#    (scoring_config, chain_rules, revision_impact_rules, service_config, provider_limits)
psql -d leadgen_db -f db/seeds/activate-v1.sql

# 4. Smoke check
psql -d leadgen_db -c "SELECT leadgen.healthcheck();"   -- verifies roles, functions, seeds
```

## Validation scenarios (run in order)

### V1 — Engine correctness (no providers, no LLMs; SQL-level)

```powershell
./scripts/run-race-tests.ps1
```

Proves, via parallel psql sessions against fixture rows:
- Concurrent claims never exceed `max_concurrency` (semaphore, not batch limit) — including the campaign-scoped `discovery` item: N simultaneous pokes yield exactly one owning execution.
- A killed worker's late completion is rejected by the fence (lease + token + expiry); exactly one committed result.
- Concurrent `authorize_paid_operation` at the cap boundary never over-authorizes; settlement above `maximum_billable_usd` raises (hard cap has no overrun path); authorization allocates budget + permit atomically (both or neither).
- Crash between authorize and call → `reconcile_expired_reservations()` resolves (release / settle / flag).
- Retry lifecycle: failures 1 and 2 → `failed_retryable`, then back to `pending` via `requeue_retryable_work()` once `available_at` passes; failure 3 → `dead` + alert; **provider deferrals never touch the failure counter**.
- Permit lifecycle: a long call renews via `renew_provider_permit()`; an expired permit cannot renew or release, and its slot is reclaimed.
- Duplicate outbox delivery / duplicate verification events → receipts prevent double effects; no revision inflation.
- Finalization: a `state_change`/`dependency` event between `begin_` and `complete_campaign_finalization` aborts back to `analyzing`; a failed `notification`/`mirror` delivery does NOT block completion; every deadline (`approval`, `critic`, `reconciliation`) resolves per pinned policy rather than waiting forever.

**Expected**: all assertions pass; zero orphaned `running` rows after `reap_expired_leases()`; `healthcheck()` green.

### V2 — Dry-run campaign (fixture providers, real LLM calls, isolated schema)

**V2a (US1 checkpoint)** — submit via the **form intake** (Execute Workflow) or a direct `leadgen_dryrun.create_campaign()` call with a fixture-covered request (see `fixtures/README`). The webhook intake does not exist until US3 and is not used here. **Expected**:
- Campaign completes in `leadgen_dryrun`; zero rows written to production tables; zero provider spend outside LLM tokens.
- Every fit score fully explained by `score_components` rows pointing at typed evidence (SC-003 spot-check); `hot_candidate` set where opportunity thresholds are met — **no Hot classification exists yet** (contactability is US2).
- Quote-checker rejects the fabricated quote planted in the review fixtures.

**V2b (US2 checkpoint)** — rerun with enrichment fixtures: DM-verifier demotes the planted wrong-business contact; planted suppressed email never becomes outreach-usable; Hot AND-gate (75/60/60) holds.

### V3 — Contract replay & idempotency

- Re-submit the same `request_id` → same campaign reference, no duplicate (FR-002).
- Submit `volume_cap: 500` → rejected at intake (FR-003).
- Submit `currency: "EUR"` → rejected at intake.
- Use an approval link twice → second use rejected; expired link → rejected.

### V4 — Golden campaign (live providers, `quick` depth, small volume)

**V4a (US1 checkpoint)** — run `golden/request.json` (~10 hand-labeled businesses). **Expected**: fit scores within tolerance bands in `golden/expectations.json` (±10), opportunity ranking order correct, invariant facts survive (top complaint themes, website characteristics), snapshot sheet written, `service_runs` show model/prompt/config-set/cost per execution. **No contact, Hot, digest, or Slack expectations at this stage.**

**V4b (after US4, task T061)** — full live end-to-end: verified owner names, post-critic Hot leads, digest with evidence + contested objections, Slack milestones (started / first Hot / complete), dashboard live. Extends `golden/expectations.json` with the contact/Hot/digest sections.

Re-run V4 after **any** config-set, prompt, or workflow-version change. Two distinct reproducibility checks:
- **Deterministic replay (SC-007)**: recompute assessments from the *stored* evidence snapshot + stored verification state + pinned config → exact equality of score components, scores, and classifications.
- **Fresh regression**: refetch live evidence for the golden businesses → known invariant facts survive and outcomes stay within `golden/expectations.json` tolerance bands. Exact equality is NOT expected (the world changes); drift outside bands is the signal.

### V5 — Scale & concurrency rehearsal (before first production sweep)

**Pinned reference deployment (SC-001/SC-011 are only meaningful against this baseline — record actuals in `golden/baseline.md` at deploy time):**

| Parameter | Reference value |
|---|---|
| n8n version | exact version pinned at deploy (recorded in baseline.md — "current LTS" is not reproducible) |
| Topology | 1 main + 2 workers, worker concurrency 10, Redis 1 GB |
| Host | 4 vCPU / 8 GB RAM (n8n stack), Postgres 2 vCPU / 4 GB with autovacuum defaults |
| Provider quotas | Recorded per-credential RPM assumptions in baseline.md |
| Enrichment | ≤ 60 enrichment-eligible leads per 300-lead campaign (gate at default threshold) |
| Measurement | p95 request→digest, **approval waiting time excluded** |

- One `standard`-depth campaign at volume_cap 300: p95 < 2 h (SC-001), budget cap honored with zero over-settlement (SC-005), no work item left non-terminal (SC-010).
- Three campaigns concurrently (mixed triggers): all guarantees hold per campaign (SC-011); provider permits keep combined traffic under credential quotas.

## Operational checks (steady state)

- Dashboard reflects analyzer completions within one poll interval (≤2 min).
- `SELECT * FROM leadgen.stuck_work_overview;` — empty in steady state (view over non-terminal items with stale leases).
- Dead-letter deliveries and `reconciliation_required` reservations alert to Slack and require human action.
- Humans record sales outcomes through the authenticated action form (invoking `record_sales_status()` / `record_lead_disposition()` — the Airtable mirror is never a write path); next campaigns exclude engaged businesses automatically, and dispositions feed SC-009 (FR-027).
