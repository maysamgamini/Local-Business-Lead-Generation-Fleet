# Tasks: Local Business Lead Generation Fleet

**Input**: Design documents from `/specs/001-leadgen-fleet/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (canonical-request, sql-api, service-contracts, scoring-defaults), quickstart.md. Source-of-truth precedence: spec.md → contracts/ → data-model.md → tasks.md → plan.md → historical design doc.

**Tests**: Included — the spec's success criteria and quickstart scenarios explicitly require race/failure-injection tests, critic evals with seeded failures, and golden-campaign regression.

**Story boundaries (dependency-corrected)**: US1 delivers **opportunity-ranked, evidence-backed fit profiles with `hot_candidate` flags** — no Hot classification, no contacts, no notifications. US2 adds verified contacts, hot-lead critic resolution, and **final Hot promotion** (Hot is AND-gated on contactability, which only US2 produces). US3 adds standing/scheduled/webhook intake. US4 adds delivery surfaces and the full live end-to-end validation. Spec US1 acceptance scenario 4 (contrarian check before Hot stands) therefore completes at the US2 checkpoint.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [X] T001 Create repository structure per plan.md: `db/{migrations,functions,seeds,tests}/`, `workflows/`, `fixtures/{places,serpapi,apify-reviews,apollo,hunter,psi,critics}/`, `golden/`, `scripts/`, `docs/`
- [X] T002 Write `scripts/deploy-db.ps1` — ordered migration runner + function deployer for both namespaces (`leadgen`, `leadgen_dryrun`), idempotent re-runs
- [X] T003 [P] Write `scripts/import-workflows.ps1` — n8n CLI/API import of `workflows/*.json` with credential-mapping notes
- [ ] T004 Configure n8n runtime on the Lightsail host: queue mode (main + 2 workers + Redis via the modified `withPostgresAndWorker` compose), external task runners, execution pruning; pin exact n8n version (currently 2.30.4) and record the reference deployment in `golden/baseline.md`
- [X] T005 [P] Write `fixtures/README.md`: supported fixture request_ids, provider fixtures, planted failure cases (fabricated quote, wrong-business contact), expected synthetic charges, expected evidence & scores
- [X] T006 Create `leadgen_db`, schemas `leadgen` + `leadgen_dryrun`, DB roles (analyzer, scorer, enricher, sweeper, relay, human-actions, dashboard-read + dry-run counterparts) in `db/migrations/000_database_roles.sql`
- [X] T007 Verify current provider behavior BEFORE building provider workflows (research.md R-15): Places Text Search pagination ceiling, PSI-vs-CrUX field-data status; record findings + any contract deltas in `docs/provider-verification.md` and adjust `fixtures/` shapes accordingly

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ No user-story work until the checkpoint at the end of this phase passes.**

**Migrations** (`db/migrations/`):

- [ ] T008 `010_campaigns.sql` — campaigns (caller-scoped idempotency `UNIQUE(caller_identity, request_id)`, pinned config-set ids, deadlines, budget/quality states, finalization fence), approval_tokens, campaign_business_snapshots
- [ ] T009 `020_businesses.sql` — businesses, business_relationships, business_sales_state, campaign_leads (lead_revision, hot_candidate, critic_state), campaign_lead_dispositions, discovery_observations
- [ ] T010 `030_work_queue.sql` — work_items with **scope CHECK** (`campaign` ⇒ campaign_id NOT NULL ∧ campaign_lead_id NULL; `lead` ⇒ both NOT NULL) and **partial unique indexes** (`(campaign_id, service) WHERE scope_type='campaign'`; `(campaign_lead_id, service) WHERE scope_type='lead'`); service_runs (`UNIQUE(work_item_id, work_attempt)`); revision_impact_rules
- [ ] T011 [P] `040_evidence.sql` — evidence_items (typed values, scoped idempotency), evidence_links (composite PK, self-link CHECK), evidence_verification_events (idempotency-keyed)
- [ ] T012 [P] `050_scoring.sql` — lead_assessments (+ **partial unique index `(campaign_lead_id) WHERE is_current = true`**), score_components, score_log, critic_reviews
- [ ] T013 [P] `060_contacts.sql` — contacts, contact_business_links, contact_channels, 3 verification tables, campaign_contact_findings, suppressions
- [ ] T014 [P] `070_money_providers.sql` — budget_transactions (max-billable, expiry, reconciliation, `service_run_id` FK), provider_limits, provider_permits (permit_token)
- [ ] T015 [P] `080_events_config.sql` — outbox_events (event_class, blocks_finalization, idempotency), outbox_deliveries (`UNIQUE(event_id, destination)`, lease), event_consumptions (PK event+destination), chain_rules, chain_rule_evaluations, config_sets, scoring_config, service_policy_entries, service_config, service_runtime_state, assets (campaign-scoped; v1 reference-only, chain rule shipped disabled)
- [ ] T016 `090_indexes_constraints_views.sql` — remaining contracted indexes, CHECK constraints (scores 0–100, positive money, nonnegative counters), views `stuck_work_overview` + `campaign_progress`, function `healthcheck()`

**SQL Function API** (`db/functions/`, per contracts/sql-api.md):

- [ ] T017 `claim_work_items.sql` + `renew_lease.sql` — concurrency semaphore, SKIP LOCKED batch, service_runs creation, version pickup
- [ ] T018 `complete_work_items.sql` — per-service completion family with universal fence (state + token + lease expiry), single-transaction result writes, version-coalescing rerun rule; `fail_work_item` + `defer_work_item` (separate counters)
- [ ] T019 [P] `sweeper_engine.sql` — `reap_expired_leases()`, `requeue_retryable_work()`, `requeue_stale_assessments()`
- [ ] T020 [P] `lead_revision.sql` — `advance_lead_revision()` with effective-change detection + impact-rule routing (self-requeue excluded)
- [ ] T021 `paid_operations.sql` — `authorize_paid_operation()` (atomic max-billable budget + permit), **`authorize_enrichment_operation()` (ONE transaction: work-item fence + opportunity/assessment-revision + approval + suppressions + campaign state + budget + permit — gate provenance recorded; failing gate → blocked/skipped_gate, no retry consumed; replaces the separate revalidate-then-authorize pair)**, `settle_paid_operation()` (actual ≤ maximum), `release_paid_operation()`, `renew_provider_permit()`, `reconcile_expired_reservations()`
- [ ] T022 [P] `outbox_engine.sql` — claim/complete/fail deliveries with in-transaction consumption receipts, dead-letter, per-destination fan-out
- [ ] T023 `campaign_lifecycle.sql` — `create_campaign(request, caller_identity, trigger_source)`, `commit_discovery_results()` (fenced), `cancel_campaign()`
- [ ] T024 [P] `human_actions.sql` — `issue_approval_token()`, `record_approval()`, `record_sales_status()`, `record_lead_disposition()`, `record_suppression()`
- [ ] T025 `finalization.sql` — `begin/complete/abort_campaign_finalization()` with state-revision fence, blocks_finalization check, deadline-policy resolution
- [ ] T026 `config_admin.sql` — `activate_config_set()`, `evaluate_chain_rules()`
- [ ] T027 `100_privileges.sql` migration — revoke direct DML; EXECUTE grants per role per function; privilege audit inside `healthcheck()`
- [ ] T028 [P] Seeds `db/seeds/activate-v1.sql` — scoring_config from `contracts/scoring-defaults.md`, thresholds, chain_rules (asset-collector rule present but disabled), revision_impact_rules, vertical policy, deadline + retry policies, service_config, provider_limits, unit costs
- [ ] T029 Race/failure-injection suite `db/tests/race_tests.sql` + `scripts/run-race-tests.ps1` — all quickstart V1 assertions: concurrency semaphore, discovery poke storm, fence rejection incl. lease expiry, atomic enrichment authorization (gate+budget+permit in one transaction — no TOCTOU window), settle-above-max raises, retry lifecycle, permit renewal/expiry, duplicate delivery/verification no-ops, finalization abort, deadline resolution, cancellation (tokens invalidated, settlement survives, spend history intact)
- [ ] T030 Transport workflows `workflows/event-relay.json` (delivery claiming loop, destination dispatch) + `workflows/error-handler.json` (global Error Trigger → Slack + ledger)

**Checkpoint**: `scripts/run-race-tests.ps1` fully green + `healthcheck()` green.

---

## Phase 3: User Story 1 — On-demand research campaign (Priority: P1) 🎯 MVP

**Goal**: Form request → discovered, analyzed businesses with four evidence-backed fit scores, opportunity ranking, `hot_candidate` flags, and a completed campaign with snapshot export. **No contacts, no Hot classification, no notifications — those are US2/US4.**

**Independent Test**: Submit one form request for a known business type/area; verify an opportunity-ranked list where every fit score traces to verified evidence via score_components, mismatches were filtered, a planted fabricated quote died at the quote-checker, and the campaign reached a defined terminal state — all without any US2/US3/US4 functionality existing.

- [ ] T031 [US1] `workflows/intake-form.json` — n8n Form → canonical validation → `create_campaign()` (internal caller identity, trigger_source=form)
- [ ] T032 [P] [US1] Fixtures for the golden vertical: `fixtures/places/`, `fixtures/serpapi/`, `fixtures/apify-reviews/` (incl. planted fabricated quote), `fixtures/psi/` + `golden/request.json`
- [ ] T033 [US1] `workflows/discovery.json` — claim campaign-scoped item, geocode, Places (depth 20/60/grid, renew_lease on grid) ∥ SerpAPI (ranks → discovery_observations), merge/dedup (place_id→phone→fuzzy), typed `business_relationships` (confidence + evidence + sales_target_level, FR-009), **`photo_asset_count` evidence from Places photo metadata**, hard filter (category/geo/exclusions/suppressions/sales-status), volume_cap by evidence richness, `commit_discovery_results()`
- [ ] T034 [P] [US1] `workflows/fetch-page.json` — shared hardened fetch sub-workflow (SSRF cage per contracts §7: private-IP block post-DNS, ≤3 re-validated redirects, size cap, sanitization)
- [ ] T035 [US1] `workflows/website-auditor.json` Tier 1 — reachability, SSL, PSI Lighthouse lab scores, viewport, tech fingerprints, **and marketing-presence checks: `ad_presence` (Meta Ad Library + Google Ads Transparency lookups) + `social_inactive_90d` (latest-post recency probe)** — all as typed evidence (these are the ads-fit producers; scoring-defaults ownership table is the contract)
- [ ] T036 [US1] Website auditor Tier 2 in `workflows/website-auditor.json` — caged Claude agent over `fetch-page` (cap 6 calls, `authorize_paid_operation()` for token spend, post-hoc schema validation)
- [ ] T037 [US1] `workflows/review-miner.json` Tier 1 — Apify newest-200 (authorized spend), oldest→newest, deterministic stats (`review_volume`, `rating`, trajectory, `owner_response_rate`) as typed evidence
- [ ] T038 [US1] Review miner Tier 2 in `workflows/review-miner.json` — cheap-model theme extraction (4 product tags, short quotes) + quote checker → verification events; corpora ephemeral (FR-026)
- [ ] T039 [US1] `workflows/phone-presence.json` — dependency-blocked passive analyzer; derived evidence with `derived_from` links; watermark reruns via impact rules
- [ ] T040 [US1] `workflows/scorer.json` — deterministic Code-node scoring from confirmed evidence under pinned config: four fits, opportunity, evidence_confidence, score_components, is_current publication rule, warm/cold/disqualified classification, **`hot_candidate` flag only (promotion + critic are US2)** via `complete_scorer_work_item()`
- [ ] T041 [US1] `workflows/sweeper.json` — scheduled engine calls (T019/T021 reconciliation), deadline enforcement, fenced finalization, quality_state, Sheets snapshot export
- [ ] T042 [US1] US1 dry-run validation: `scripts/validate-us1-dryrun.ps1` + `db/tests/us1_dryrun_assertions.sql` — submit via `intake-form` (Execute Workflow) into `leadgen_dryrun`; assert: zero production writes, fabricated quote rejected, every fit point traceable to a confirmed evidence item, hot_candidate set exactly where the candidate condition holds (opportunity ≥75 ∧ evidence_confidence ≥60, per scoring-defaults), campaign terminal (**webhook intake is deliberately NOT used — it doesn't exist until US3**)
- [ ] T043 [US1] US1 golden campaign live at `quick` depth: `golden/expectations.json` (fit-score tolerance bands, opportunity ranking order, invariant facts — **no contact/Hot/digest/Slack expectations**) + deterministic replay check `db/tests/replay_assertions.sql` (stored evidence → exact score equality, SC-007)

**Checkpoint**: US1 independently deliverable — evidence-backed opportunity research from a form.

---

## Phase 4: User Story 2 — Verified contacts, Hot promotion, spend control (Priority: P2)

**Goal**: Above-gate leads get verified decision-makers under hard caps and approval; the hot-lead critic resolves; leads become **Hot** for the first time.

**Independent Test**: Small-budget campaign with approval required: zero spend before approval; only above-gate leads enriched; cap never exceeded; planted wrong-business contact demoted; suppressed channels never stored outreach-usable; a lead crosses to Hot only after critic resolution with all three dimensions passing.

- [ ] T044 [US2] `workflows/approval-form.json` — signed one-time links (`record_approval()`), issuance + Slack delivery on `awaiting_approval`
- [ ] T045 [US2] `workflows/contact-enricher.json` stage 1 — gate-blocked claim; **`authorize_enrichment_operation()`** (single-transaction gate+budget+permit) before every paid tier; Apollo lookup with vertical-policy title filter
- [ ] T046 [US2] DM-hunter caged agent in `workflows/contact-enricher.json` — web_search + `fetch-page` (cap 6), explicit `not_found` rewarded; fixture `fixtures/apollo/dm-miss.json` drives the fallback path
- [ ] T047 [US2] Verification + persistence in `workflows/contact-enricher.json` — identity/role/channel verification rows with expiry (deterministic attestation checks; LLM assists matching only), `campaign_contact_findings`, 5-level suppression checks, Hunter deliverability tier, settle within maximum
- [ ] T048 [US2] Hot promotion + critic in `workflows/scorer.json` — contactability dimension from verified+unexpired findings; when contactability also passes the Hot gate, hot_candidate leads open `critic_reviews` (cross-family critic) → disputes → deterministic re-verification → recompute → promotion to Hot or `contested` at deadline; `lead.hot` event only post-resolution; critic fixtures in `fixtures/critics/hot-candidate-objections.json`
- [ ] T049 [P] [US2] Fixtures `fixtures/apollo/` + `fixtures/hunter/` incl. planted wrong-business contact and planted suppressed email (per fixtures/README)
- [ ] T050 [US2] US2 validation: `scripts/validate-us2-spend.ps1` + `db/tests/us2_gate_budget_assertions.sql` — SC-005 (cap never exceeded incl. concurrent authorizations), SC-006 (suppressed email never outreach-usable; unverified channel = zero contactability; delivered emails deliverability-verified), approval-expiry finalizes without enrichment, approval link single-use + expiry rejection (quickstart V3a), Hot AND-gate holds (75/60/60), wrong-contact demoted

**Checkpoint**: First true Hot leads exist, financially controlled.

---

## Phase 5: User Story 3 — Standing campaigns & integration (Priority: P3)

**Goal**: Scheduled ICP-sheet campaigns and authenticated API triggers; cross-campaign dedup; idempotent submissions.

**Independent Test**: One standing profile, two scheduled runs — second links/refreshes instead of duplicating, older campaign results frozen; replayed API request yields one campaign; unauthenticated/over-budget/oversize requests rejected.

- [ ] T051 [US3] Cursor infrastructure: `db/migrations/095_standing_profile_cursors.sql` (standing_profile_cursors: profile_source, profile_row_id, last_scheduled_slot, last_campaign_id, version) + `db/functions/schedule_cursors.sql` (`claim_scheduled_profile_slot()` — atomically prevents two schedule executions creating the same campaign)
- [ ] T052 [US3] `workflows/intake-schedule.json` — ICP sheet reader (the only machine-read sheet), `claim_scheduled_profile_slot()` per row, derived request_id (row+slot), requires_approval=false
- [ ] T053 [US3] `workflows/intake-webhook.json` — authenticated intake, caller identity → trusted `create_campaign()` args, caller-bound budget limits, 4xx contract violations (incl. `region` geo rejection)
- [ ] T054 [US3] Rediscovery integration test `db/tests/rediscovery_campaign.sql` — run golden vertical twice: ≥98% rediscoveries link to existing businesses (SC-008), evidence refreshed, prior campaign's snapshots/assessments byte-identical (FR-008/FR-025)
- [ ] T055 [US3] Intake validation `scripts/validate-us3-intake.ps1` — request_id replay → `creation_status=existing`; volume_cap 500 / EUR / region / over-authorization → rejected; schedule double-fire → one campaign (cursor claim)

**Checkpoint**: Always-warm pipeline, externally composable.

---

## Phase 6: User Story 4 — Visibility, delivery & full end-to-end (Priority: P4)

**Goal**: Live dashboard, milestone notifications, hot-lead digest — then the first full-system live validation.

**Independent Test**: During a running campaign, dashboard updates within one poll interval; milestones fire at correct moments (no `lead.hot` before critic resolution); digest lists exactly the post-critic Hot leads with snapshot-accurate details, evidence, objections.

- [ ] T056 [US4] Slack destinations in `workflows/event-relay.json` — milestone formatting: started, first Hot (post-critic, + top evidence line), complete (quality_state + spend), dead work items, budget alerts, reconciliation_required
- [ ] T057 [US4] Digest generation in `workflows/sweeper.json` finalization — Hot leads (post-critic only) with best_angle, verified evidence quotes, contested objections, spend summary; produced before `complete_campaign_finalization()`; secondary-delivery failures never block completion (FR-024)
- [ ] T058 [US4] `workflows/dashboard-sync.json` + Airtable base/Interface — one-way mirror (campaigns, leads, per-service statuses, fit bars); documented read-only
- [ ] T059 [US4] `workflows/sales-action-form.json` — authenticated `record_sales_status()` / `record_lead_disposition()` (FR-027); SC-009 view `db/migrations/096_sc009_view.sql`
- [ ] T060 [US4] Delivery timing tests `scripts/test-dashboard-latency.ps1` — analyzer completion visible within one poll interval; milestone ordering assertions (no premature `lead.hot`)
- [ ] T061 [US4] **Full live end-to-end validation** (quickstart V4-full): golden campaign at `quick` depth exercising US1+US2+US4 together — Hot leads with verified contacts, digest, Slack milestones, dashboard; extend `golden/expectations.json` with contact/Hot/digest expectations

---

## Phase 7: Polish & Production Readiness

- [ ] T062 Scale rehearsal (quickstart V5): 300-lead standard campaign p95 < 2h on reference deployment; 3 concurrent campaigns; record actuals in `golden/baseline.md` (SC-001/SC-005/SC-010/SC-011)
- [ ] T063 [P] Automated critic-eval harness `db/tests/critic_evals.sql` — quote-checker and DM-verifier must catch seeded plants on every run
- [ ] T064 [P] Data-rights audit `db/tests/data_rights_audit.sql` — no full review corpora persisted, excerpt length limits enforced, all assets `reference_only` with `storage_ref` NULL (FR-026)
- [ ] T065 Ops runbook `docs/runbook.md` — dead work items, dead-letter deliveries, reconciliation_required, over-deadline campaigns, config-set rollout (new version + activate, never edit)

---

## Dependencies

```
Setup ──► Foundational ──► US1 (P1) ──► US2 (P2) ──► US4 (P4) ──► Polish
                              │            ▲
                              └──► US3 (P3) — depends only on US1; runs parallel to US2
```

- **US2 requires US1** (scorer + gate exist) and **delivers Hot** (contactability is US2's product).
- **US3 requires US1 only** — can run in parallel with US2 (disjoint files).
- **US4 requires US2** (digest/milestones are Hot-centric); T061 is the first moment the full system is validated live.
- Within Phase 2: T008–T016 before T017–T027; T028/T029 after functions; T030 after T022.
- T007 (provider verification) strictly before T033/T035 (provider workflows).

## Parallel Execution Examples

- **Phase 2**: T011–T015 in parallel; then T019/T020/T022/T024 in parallel after T017–T018.
- **US1**: T032 + T034 parallel with T031; analyzers T035–T039 in parallel after T033 (separate workflow files).
- **US2 ∥ US3** after the US1 checkpoint: one track T044–T050, the other T051–T055.

## Implementation Strategy

**MVP = Setup + Foundational + US1**: form-triggered, evidence-backed, opportunity-ranked market research with snapshot export — already replaces the manual research hours, honestly scoped without Hot claims it can't yet gate. US2 turns candidates into Hot, US3 automates intake, US4 delivers polish, and T061 is the single moment everything is proven live together. Deferred from v1: Asset Collector workflow (schema + disabled chain rule ship now; collector is a v2 task), region geography, probe-caller, vision tagging.
