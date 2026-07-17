# Tasks: Local Business Lead Generation Fleet

**Input**: Design documents from `/specs/001-leadgen-fleet/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (canonical-request, sql-api, service-contracts), quickstart.md, governing design doc `docs/superpowers/specs/2026-07-16-leadgen-fleet-design.md` (v4 + §14 addendum)

**Tests**: Included — the spec's success criteria and quickstart validation scenarios (V1–V5) explicitly require race/failure-injection tests, critic evals with seeded failures, and golden-campaign regression. These are deliverables, not optional extras.

**Organization**: Setup + Foundational phases build the transactional engines (the correctness layer everything trusts); user-story phases deliver the fleet in spec priority order.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: US1 (on-demand campaign) / US2 (contacts & spend control) / US3 (standing campaigns & integration) / US4 (visibility & delivery)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Repository skeleton, deployment tooling, runtime environment

- [ ] T001 Create repository structure per plan.md: `db/{migrations,functions,seeds,tests}/`, `workflows/`, `fixtures/{places,serpapi,apify-reviews,apollo,hunter,psi}/`, `golden/`, `scripts/`
- [ ] T002 Write `scripts/deploy-db.ps1` — ordered migration runner + function deployer for both namespaces (`leadgen`, `leadgen_dryrun`), idempotent re-runs
- [ ] T003 [P] Write `scripts/import-workflows.ps1` — n8n CLI/API import of `workflows/*.json` with credential mapping notes
- [ ] T004 Configure n8n runtime: queue mode (main + 2 workers + Redis), external task-runner mode for Code nodes, execution-data pruning; pin exact n8n version and record reference deployment in `golden/baseline.md`
- [ ] T005 [P] Write `fixtures/README.md`: supported fixture request_ids, provider fixtures used, planted failure cases (fabricated quote, wrong-business contact), expected synthetic charges, expected evidence & scores
- [ ] T006 Create `leadgen_db`, schemas `leadgen` + `leadgen_dryrun`, and DB roles (analyzer, scorer, enricher, sweeper, relay, human-actions, dashboard-read; dry-run counterparts) in `db/migrations/000_database_roles.sql`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The transactional core — schema, SQL function API, engines, race tests. **No user story work until this phase passes its checkpoint.**

**Migrations** (ordered files in `db/migrations/`):

- [ ] T007 `010_campaigns.sql` — campaigns (caller-scoped idempotency, pinned config-set ids, deadlines, budget/quality states, finalization fence fields), approval_tokens, campaign_business_snapshots
- [ ] T008 `020_businesses.sql` — businesses, business_relationships, business_sales_state, campaign_leads (lead_revision, hot_candidate, critic_state), campaign_lead_dispositions, discovery_observations
- [ ] T009 `030_work_queue.sql` — work_items (scope_type campaign|lead, 3 counters, lease+fence fields, 3-version coalescing, gate provenance), service_runs, revision_impact_rules
- [ ] T010 [P] `040_evidence.sql` — evidence_items (typed values, scoped idempotency), evidence_links (PK, self-link CHECK), evidence_verification_events (idempotency-keyed)
- [ ] T011 [P] `050_scoring.sql` — lead_assessments (is_current, watermark), score_components, score_log, critic_reviews
- [ ] T012 [P] `060_contacts.sql` — contacts, contact_business_links, contact_channels, 3 verification tables, campaign_contact_findings, suppressions
- [ ] T013 [P] `070_money_providers.sql` — budget_transactions (max-billable, expiry, reconciliation), provider_limits, provider_permits (permit_token)
- [ ] T014 [P] `080_events_config.sql` — outbox_events (event_class, blocks_finalization, idempotency), outbox_deliveries (UNIQUE event+destination, lease), event_consumptions, chain_rules, chain_rule_evaluations, config_sets, scoring_config, service_policy_entries, service_config, service_runtime_state, assets (campaign-scoped, reference-only)
- [ ] T015 `090_indexes_constraints_views.sql` — all contracted indexes, CHECK constraints (scores 0–100, positive money, nonnegative counters), views `stuck_work_overview` + `campaign_progress`, function `healthcheck()`

**SQL Function API** (files in `db/functions/`, per contracts/sql-api.md; each SECURITY DEFINER, pinned search_path, typed errors):

- [ ] T016 `claim_work_items.sql` + `renew_lease.sql` — concurrency semaphore (slots = max_concurrency − running unexpired), SKIP LOCKED batch, service_runs creation, version pickup
- [ ] T017 `complete_work_items.sql` — per-service completion family (analysis/scorer/enrichment/collector) with universal fence (incl. lease expiry), single-transaction result writes, version-coalescing rerun rule; `fail_work_item` + `defer_work_item` (separate counters)
- [ ] T018 [P] `sweeper_engine.sql` — `reap_expired_leases()`, `requeue_retryable_work()` (failed_retryable→pending / →dead), `requeue_stale_assessments()`
- [ ] T019 [P] `lead_revision.sql` — `advance_lead_revision()` with effective-change detection + revision_impact_rules routing (self-requeue excluded)
- [ ] T020 `paid_operations.sql` — `authorize_paid_operation()` (atomic max-billable reservation + permit, both-or-neither), `settle_paid_operation()` (actual ≤ maximum enforced), `release_paid_operation()`, `renew_provider_permit()`, `reconcile_expired_reservations()`
- [ ] T021 [P] `outbox_engine.sql` — `claim/complete/fail_outbox_delivery()` with consumption receipts committed in-transaction, dead-letter, per-destination fan-out on event insert
- [ ] T022 `campaign_lifecycle.sql` — `create_campaign()` (trusted caller_identity + trigger_source, config-set pinning, discovery work-item creation, deadline stamping), `commit_discovery_results()` (fenced, one transaction), `cancel_campaign()`
- [ ] T023 [P] `human_actions.sql` — `issue_approval_token()`, `record_approval()`, `record_sales_status()`, `record_lead_disposition()`, `record_suppression()` (human-actions role only)
- [ ] T024 `finalization.sql` — `begin/complete/abort_campaign_finalization()` with campaign_state_revision fence, blocks_finalization event check, deadline-policy resolution
- [ ] T025 `config_admin.sql` — `activate_config_set()`, `evaluate_chain_rules()` (idempotent per lead+rule+revision, allowlisted targets)
- [ ] T026 `100_privileges.sql` migration — revoke all direct DML on protected tables; grant EXECUTE per role per function; verify with a privilege-audit query in `healthcheck()`
- [ ] T027 [P] Seeds in `db/seeds/activate-v1.sql` — config sets v1: scoring_config **initialized from `specs/001-leadgen-fleet/contracts/scoring-defaults.md` (drafted initial weights/transforms — tune via golden campaign, never edit activated sets)**, classification/enrichment thresholds, chain_rules, revision_impact_rules, vertical policy (dental/medspa title mappings, category allowlists), deadline + retry policies, service_config (claim sizes, concurrency, leases), provider_limits, unit-cost table
- [ ] T028 SQL race/failure-injection suite in `db/tests/` + `scripts/run-race-tests.ps1` — every quickstart V1 assertion: concurrency semaphore, discovery poke storm, fence rejection of killed workers, atomic authorize at cap boundary, settle-above-max raises, retry lifecycle (2 retries→pending, 3rd→dead, deferrals don't count), permit renewal/expiry, duplicate delivery/verification no-ops, finalization abort on state_change event, deadline resolution, **campaign cancellation** (pending→canceled, running tokens invalidated so late fenced writes reject, in-flight settlement still lands, spend history intact — FR-004)
- [ ] T029 Transport workflows: `workflows/event-relay.json` (delivery claiming loop, destination dispatch — no business logic) + `workflows/error-handler.json` (global Error Trigger → Slack + ledger annotation)

**Checkpoint**: `run-race-tests.ps1` fully green + `healthcheck()` green → user stories may begin.

---

## Phase 3: User Story 1 — Run an on-demand research campaign (Priority: P1) 🎯 MVP

**Goal**: Form request → discovered, analyzed, scored, critic-checked leads with verifiable evidence → completed campaign with snapshot export.

**Independent Test**: Submit one form request for a known business type/area; verify a delivered ranked list where every score traces to verifiable evidence, obvious mismatches were filtered, fabricated evidence died at the gate, and the campaign reached a defined terminal state.

- [ ] T030 [US1] `workflows/intake-form.json` — n8n Form → canonical validation → `create_campaign()` (internal caller identity, trigger_source=form, requires_approval default true)
- [ ] T031 [P] [US1] Provider fixtures for the golden vertical in `fixtures/places/`, `fixtures/serpapi/`, `fixtures/apify-reviews/`, `fixtures/psi/` + `golden/request.json` (incl. planted fabricated-quote case per fixtures/README)
- [ ] T032 [US1] `workflows/discovery.json` — claim campaign-scoped item, geocode, Places (depth 20/60/grid, `renew_lease` on grid) ∥ SerpAPI (ranks), normalize/merge/dedup (place_id→phone→fuzzy), **multi-location relationship detection** (typed `business_relationships` with confidence + evidence + `sales_target_level`, per design §6.1 — never bare shared-domain inference; FR-009), hard filter (category/geo/exclusions/suppressions/sales-status, batched cheap-model category call), volume_cap by evidence richness, `commit_discovery_results()` (fenced)
- [ ] T033 [P] [US1] `workflows/fetch-page.json` — shared hardened fetch sub-workflow: http/https only, private-IP/localhost block post-DNS, ≤3 re-validated redirects, size cap, HTML→text sanitization (used by auditor + DM-hunter)
- [ ] T034 [US1] `workflows/website-auditor.json` Tier 1 — reachability, SSL, PSI Lighthouse lab scores, viewport, tech fingerprints → typed evidence via `complete_analysis_work_item()`
- [ ] T035 [US1] Website auditor Tier 2 in same workflow — caged Claude agent over `fetch-page` (cap 6 calls, authorize_paid_operation for token spend, post-hoc schema validation)
- [ ] T036 [US1] `workflows/review-miner.json` Tier 1 — Apify newest-200 (authorized spend), oldest→newest processing, deterministic stats as typed evidence
- [ ] T037 [US1] Review miner Tier 2 — cheap-model theme extraction (4 product tags, short quotes) + quote checker → verification events; corpora discarded after derivation (ephemerality per FR-026)
- [ ] T038 [US1] `workflows/phone-presence.json` — dependency-blocked passive analyzer; derived evidence with `derived_from` links; watermark reruns via impact rules
- [ ] T039 [US1] `workflows/scorer.json` — deterministic Code-node scoring from confirmed evidence under pinned config set; score_components; three dimensions; classification with hot_candidate flow; is_current publication rule via `complete_scorer_work_item()`
- [ ] T040 [US1] Hot-lead critic in scorer workflow — cross-family critic on first hot-candidate; `critic_reviews`; disputes → deterministic re-verification → recompute; deadline → contested; `lead.hot` only post-resolution
- [ ] T041 [US1] `workflows/sweeper.json` — scheduled: engine functions (T018/T020 reconciliation), deadline enforcement, fenced finalization, quality_state, Sheets snapshot export write
- [ ] T042 [US1] Dry-run validation (quickstart V2): full fixture campaign in `leadgen_dryrun`; assert zero production writes, planted failures caught, scores explained; fix until green
- [ ] T043 [US1] Golden campaign live at `quick` depth (quickstart V4): create `golden/expectations.json` tolerance bands; deterministic-replay check (exact equality from stored evidence)

**Checkpoint**: US1 independently deliverable — the agency can research a market from a form.

---

## Phase 4: User Story 2 — Verified decision-maker contacts with spend control (Priority: P2)

**Goal**: Above-threshold leads get verified contacts, under hard budget caps and (for manual runs) human approval.

**Independent Test**: Small-budget campaign with approval required: no spend before approval; only above-gate leads enriched; cap never exceeded; unverifiable contacts demoted; suppressed channels never stored as outreach-usable.

- [ ] T044 [US2] `workflows/approval-form.json` — n8n Form consuming signed one-time links (`record_approval()`); link issuance + Slack delivery on `awaiting_approval`
- [ ] T045 [US2] `workflows/contact-enricher.json` stage 1 — gate-blocked claim; `revalidate_enrichment_gate()` before every `authorize_paid_operation()`; Apollo lookup with vertical-policy title filter
- [ ] T046 [US2] DM-hunter caged agent in enricher — web_search + `fetch-page` (cap 6), explicit `not_found` rewarded, authorized token spend
- [ ] T047 [US2] Verification + persistence in enricher — identity/role/channel verification tables with expiry, deterministic role-attestation check (LLM assists matching only), `campaign_contact_findings`, 5-level suppression checks pre-storage, Hunter deliverability tier, settle within maximum
- [ ] T048 [P] [US2] Fixtures: `fixtures/apollo/`, `fixtures/hunter/` incl. planted wrong-business contact (verifier eval per fixtures/README)
- [ ] T049 [US2] Spend-control & contact-integrity validation (quickstart V3 subset): budget-cap campaign completes with `skipped_budget` labels; approval-expiry finalizes without enrichment; contact points flow only from verified+unexpired; **SC-006 assertions** — planted suppressed email never stored/delivered as outreach-usable, unverified channel earns zero contactability credit, every delivered email carries a passing deliverability verification

**Checkpoint**: US1+US2 = fully qualified, contactable leads under financial control.

---

## Phase 5: User Story 3 — Standing campaigns & system integration (Priority: P3)

**Goal**: Scheduled ICP-sheet campaigns and authenticated API triggers; cross-campaign dedup; idempotent submissions.

**Independent Test**: One standing profile, two scheduled runs — second run links/refreshes instead of duplicating and older campaign results stay frozen; replayed API request yields exactly one campaign; unauthenticated/over-budget requests rejected.

- [ ] T050 [US3] `workflows/intake-schedule.json` — ICP sheet reader (the only machine-read sheet), per-row ledger cursors, derived request_id (row+slot), requires_approval=false
- [ ] T051 [US3] `workflows/intake-webhook.json` — authenticated intake, caller identity → trusted `create_campaign()` args, caller-bound budget limits, contract-violation 4xx responses
- [ ] T052 [US3] Rediscovery validation — run golden vertical twice: assert link-not-duplicate (<2% dup rate SC-008), evidence refresh, prior campaign's snapshot/assessments unchanged (FR-008/FR-025)
- [ ] T053 [US3] Idempotency & rejection validation (quickstart V3): request_id replay → `creation_status=existing`; volume_cap 500, EUR, `region` geo, over-authorization budget → all rejected with clear errors

**Checkpoint**: The pipeline is always-warm and externally composable.

---

## Phase 6: User Story 4 — Live visibility & delivery surfaces (Priority: P4)

**Goal**: Live dashboard, milestone notifications, hot-lead digest with evidence and objections.

**Independent Test**: During a running campaign, dashboard statuses/scores update within one poll interval; milestones fire (started / first hot post-critic / complete); digest lists exactly the hot leads with snapshot-accurate details, evidence, and unresolved objections.

- [ ] T054 [US4] Slack destinations in `workflows/event-relay.json` — milestone formatting (started, first-hot with top evidence line, complete with quality_state + spend, dead work items, budget alerts, reconciliation_required)
- [ ] T055 [US4] Digest generation in sweeper finalization — hot leads (post-critic only) with best_angle, top evidence quotes (verified only), contested objections, spend summary; written before `complete_campaign_finalization()`
- [ ] T056 [US4] `workflows/dashboard-sync.json` + Airtable base/Interface — one-way mirror (campaign summaries, leads, per-service statuses from work_items, fit bars); documented as read-only
- [ ] T057 [US4] `workflows/sales-action-form.json` — authenticated `record_sales_status()` / `record_lead_disposition()` actions (FR-027); SC-009 query view over dispositions
- [ ] T058 [US4] Live-progress validation — timed check that analyzer completions surface in dashboard within one poll interval; milestone timing (no `lead.hot` before critic resolution)

---

## Phase 7: Polish & Production Readiness

- [ ] T059 Scale rehearsal (quickstart V5): 300-lead standard campaign p95 < 2h on reference deployment; 3 concurrent campaigns; record actuals in `golden/baseline.md` (SC-001/SC-005/SC-010/SC-011)
- [ ] T060 [P] Automated critic-eval harness in `db/tests/critic_evals.sql` + fixture plants — quote-checker and DM-verifier must catch seeded failures on every run (decorative-critic detector)
- [ ] T061 [P] Data-rights pass — verify corpora ephemerality (no full review text persisted), excerpt length limits, asset `license_status` defaults, `storage_ref` NULL everywhere (FR-026)
- [ ] T062 Ops runbook `docs/runbook.md` — responding to dead work items, dead-letter deliveries, `reconciliation_required`, over-deadline campaigns, config-set rollout procedure (new version + activate, never edit)
- [ ] T063 Verify deferred R-15 items — current Places pagination ceiling, PSI/CrUX field-data status; update Discovery/Auditor + fixtures if drifted

---

## Dependencies

```
Phase 1 Setup ──► Phase 2 Foundational ──► US1 (P1) ──► US2 (P2) ──► US3 (P3) ──► US4 (P4) ──► Polish
                                            │
                                            ├─ US2 depends on US1 (scorer produces the gate US2 spends against)
                                            ├─ US3 depends on US1 only (intakes reuse the US1 pipeline; can run parallel to US2)
                                            └─ US4 depends on US1 (needs events/assessments; digest parts benefit from US2 contacts)
```

- **US3 can start in parallel with US2** once US1 is checkpointed (different workflows, no shared files).
- Within Phase 2: T007–T015 migrations before T016–T026 functions; T027 seeds and T028 tests after functions; T029 anytime after T021.

## Parallel Execution Examples

- **Phase 2**: T010–T014 migrations in parallel (separate files); then T018, T019, T021, T023, T027 in parallel after T016–T017.
- **US1**: T031 fixtures + T033 fetch-page in parallel with T030/T032; analyzers T034–T038 in parallel after Discovery lands (separate workflow files).
- **US2 ∥ US3**: after US1 checkpoint, one track builds T044–T049 while another builds T050–T053.

## Implementation Strategy

**MVP = Phase 1 + Phase 2 + US1** — a form-triggered campaign producing evidenced, critic-checked, scored leads with a snapshot export. Ship that, run the golden campaign, tune scoring config against real output, then add spend (US2), automation (US3), and polish (US4) as independent increments. Phases 1–2 produce correctness rather than leads by design; fixtures ride the engines from T031 onward so end-to-end signal arrives before the full fleet exists.
