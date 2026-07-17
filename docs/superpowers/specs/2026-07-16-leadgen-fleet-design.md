# Lead Generation Fleet — Design (v4 + plan-consistency addendum)

**Date:** 2026-07-16 (v4 after third external design review; addendum after fourth review round against the speckit plan artifacts — see §14. The speckit contracts in `specs/001-leadgen-fleet/contracts/` are authoritative where they extend this document.)
**Status:** Final design; speckit plan artifacts generated
**System:** Local Business Research & Lead Generation for a digital-marketing / AI-voice-assistant agency

---

## 1. Purpose & Scope

Automate the work of a Lead Generation Specialist: given a business type and geography, discover local businesses, analyze each against the agency's four product lines, identify and verify decision-makers, score and classify leads, and deliver evidenced, qualified opportunities.

**The deliverable per lead is a fit-profile**: four product-fit scores, each backed by verifiable evidence, plus verified contact data and a recommended sales angle. "A smaller list with clear reasons" — provenance is the product.

**Agency product lines (all four scored on every lead):**
1. Web design + SEO improvement
2. AI voice assistant / receptionist
3. Advertisement campaigns incl. AI-generated video
4. Consultation / custom AI assistants & agents

**In scope:** discovery → analysis → contact enrichment → scoring → storage → digest.
**Out of scope (separate future projects, contracts reserved):** outreach/sequencing; active phone probe-caller (V2 swap-in for Phone Presence, same contract); vision-model asset tagging (V2 bolt-on).

## 2. Architecture

**Style:** choreographed fleet of independent n8n services over a Postgres ledger; pull-based work queue; transactional outbox; **every state mutation behind SECURITY DEFINER SQL functions** — workflows hold no direct DML rights on protected tables.

- Every service is an independent n8n workflow with a documented JSON contract and two entry points (webhook, Execute Workflow).
- No central orchestrator: coordination through the ledger; Event Relay delivers events; completion is detected under a finalization fence, not orchestrated.
- **Runtime philosophy:** 100% n8n workflows, no external application code. Transactional invariants live in Postgres functions called from single Postgres nodes (separate n8n Postgres nodes are separate autocommit transactions — multi-node write sequences are forbidden for state mutation). Code nodes limited to scoring math, dedup normalization, merge logic; external task-runner mode in production.

### 2.1 Ledger & human surfaces

**Postgres — shared self-hosted cluster, separate database `leadgen_db`, separate users/roles, separate backup/migration lifecycle.** n8n execution pruning enabled on its own DB.

Write-only mirrors (never read by machines): **Airtable dashboard** (Dashboard Sync); **Google Sheets** — the **ICP definition sheet** is an *input* read only by Scheduled Intake (cursors in the ledger), output **snapshot sheets** are never read back; **Slack** milestones/alerts.

**Approval:** durable `approval_tokens` (hash only, never the raw token) issued by `issue_approval_token()`; signed, one-time-use, expiring, replay-protected link → n8n Form → `record_approval()` locks the token row and rejects expired/reused/revoked tokens and finalized campaigns.

**Dry-run isolation:** `dry_run` requests are routed by the SQL functions to an isolated schema (`leadgen_dryrun`) — a boolean flag alone is not isolation; production tables are unreachable for dry-run writes.

**Currency:** v1 accepts `USD` only; any other currency is rejected at intake with an explicit error.

### 2.2 Transactional API (complete)

All functions: SECURITY DEFINER, `SET search_path = pg_catalog, leadgen`, no dynamic SQL from workflow-supplied values, payload size/shape/state-transition validation inside. **Universal fence:** every completion/renewal/delivery/permit operation requires `state = 'running' AND claim_token = :token AND lease_expires_at > now()` — zero rows ⇒ the caller discards its result.

| Function | Guarantees |
|---|---|
| `create_campaign(request)` | Validates schema_version, authn-derived budget limit, USD-only; idempotent on `request_id` (replay returns existing campaign); pins active `config_sets` (scoring, chain rules, vertical policy, model policy, service policy) |
| `commit_discovery_results(campaign_id, payload)` | ONE idempotent transaction: business upserts + snapshots + campaign_leads + discovery_observations + initial evidence + work-item graph (correct initial states) + campaign status + outbox events |
| `claim_work_items(service, worker_id)` | Locks service row; `available_slots = max_concurrency − count(running, unexpired leases)`; claims `min(claim_batch_size, slots)` FOR UPDATE SKIP LOCKED; sets lease + new claim_token; `processing_version := requested_version`; **creates a `service_runs` row per claimed item** and returns (work_item_id, claim_token, service_run_id, processing_version) |
| `renew_lease(work_item_id, claim_token)` | Fenced (incl. expiry) — post-expiry renewal fails; worker discards result |
| `complete_*_work_item(...)` per service class — `complete_analysis_work_item`, `complete_scorer_work_item`, `complete_enrichment_work_item`, `complete_collector_work_item` | Fenced (incl. expiry). ONE transaction: service-specific validated payload → evidence items + links (cycle check), verification events, assessment/contact records, service_run finalization, chain evaluation via `evaluate_chain_rules()`, outbox events, fenced work-item update. Version rule: `requested_version > processing_version ⇒ state = pending` (rerun), else `done` |
| `fail_work_item(work_item_id, claim_token, error)` | Fenced failure; finalizes service_run as failed; schedules retry (`available_at` backoff); increments `retryable_failure_count` |
| `defer_work_item(work_item_id, claim_token, retry_at, cause)` | Provider cooldown / capacity / waiting conditions — increments `provider_deferral_count`, **not** a failure |
| `advance_lead_revision(campaign_lead_id, cause_type)` | `lead_revision++` **only when effective state changes** (idempotent replays no-op); bumps `requested_version` **only for services mapped by `revision_impact_rules`**; a service's own output never requeues itself unless explicitly configured |
| `reserve_budget(campaign_id, service_run_id, est, idem_key)` | Locks budget row; `available = cap − settled − active_reserved`; reservation with `expires_at`, linked to the exact service_run |
| `settle_budget(reservation_id, actual, provider_request_id)` / `release_budget(reservation_id)` | Settlement remains valid after work-item cancellation (spend history is never erased); overrun: settle actual, log variance, recompute budget_state |
| `revalidate_enrichment_gate(work_item_id, claim_token)` | Atomically, immediately before reserve: latest opportunity score + assessment revision + approval + suppressions + campaign state + budget. Passing ⇒ records `gate_assessment_id, gate_revision, gate_threshold_version`. Failing ⇒ `blocked` (more analysis may come) or `skipped_gate` (analysis final) — no retry consumed. In-flight policy: a started provider call finishes and settles; the next paid tier always rechecks |
| `acquire_provider_permit(provider, scope, service_run_id)` / `release_provider_permit(permit_id)` | Locks provider row; enforces RPM; counts **unexpired** permits for concurrency (crash-safe — no counters); returns leased permit or `retry_at` |
| `evaluate_chain_rules(campaign_lead_id, event, input_revision)` | Inserts `chain_rule_evaluations` (UNIQUE per lead+rule+revision — idempotent under duplicate delivery); outcome fired/suppressed/not_applicable/error; fired ⇒ outbox event |
| `begin_campaign_finalization(campaign_id)` | Locks campaign; verifies all work terminal, all `latest_assessment` current with `lead_revision`, critic reviews resolved, no undelivered state-changing events, budget reconciliation clean; captures `campaign_state_revision`; issues finalization token |
| `complete_campaign_finalization(campaign_id, token, payload)` / `abort_campaign_finalization(...)` | Succeeds only if `campaign_state_revision` unchanged; any score-affecting mutation during finalizing invalidates the token and returns the campaign to `analyzing` |
| `record_approval(token, decision)` · `issue_approval_token(...)` · `record_suppression(...)` · `cancel_campaign(...)` · `activate_config_set(...)` | As named; `cancel_campaign` invalidates running claim tokens (fence rejects late commits) but never blocks budget settlement |

### 2.3 Work queue

`work_items` — one row per (campaign_lead, service); `service_config` knobs: `claim_batch_size`, `max_concurrency`, `rate_limit_per_minute`, `lease_ttl_s`. n8n queue mode underneath.

**States:** non-terminal `blocked | pending | running | failed_retryable | waiting_approval` · terminal `done | dead | skipped_gate | skipped_budget | skipped_prerequisite | canceled`.

**Counters, separated:** `execution_attempt_count` (real attempts), `provider_deferral_count` (cooldowns/capacity — never fatal), `retryable_failure_count` (drives `dead` at threshold).

**Versioned reruns:** `requested_version / processing_version / completed_version` coalescing (§2.2). **`lead_revision` is the watermark — never timestamps.** **Routing:** `revision_impact_rules (cause_type, affected_service, enabled)` — e.g. review evidence → Phone Presence + Scorer; contact verification → Scorer only; phone evidence → Scorer (never Phone Presence itself); suppression → Enricher + Scorer; evidence dispute → source verifier + Scorer.

**Dependencies & gates:** website+reviews `pending` at creation; Phone Presence `blocked` until both terminal (reruns via impact rules); Enrichment `blocked` → `pending`/`waiting_approval`/`skipped_gate` — and **revalidated at spend time** (§2.2); Assets via chain rules. Missing prerequisite ⇒ `skipped_prerequisite` + evidence fact (`website_present=false`).

### 2.4 Transactional outbox

`outbox_events` written inside completion functions; `outbox_deliveries` fan-out **UNIQUE(event_id, destination)**, each with own state/lease/claim_token (universal fence applies). At-least-once; **consumers record their idempotency receipt in the same transaction as the action the event caused**; exponential retry → `dead_letter` + alert; retention window; no ordering guarantee.

### 2.5 Provider limits

`provider_limits` (quotas, cooldowns) + **`provider_permits`** (leased concurrency slots tied to service_runs — crash-expired, never counted). Shared-credential services (Claude: auditor+critic; single Apify/Hunter keys) draw from one bucket. Deferral ⇒ `retry_at`, not failure.

### 2.6 Configuration: immutable, campaign-pinned

`config_sets (config_type, version, content_hash, activated_at, retired_at)` — **activated sets are never modified; changes create a new version.** Campaigns pin exact set IDs at creation (scoring, chain rules, vertical policy — title mappings, category allowlists, quality floors — model policy, service policy — tool caps, retry policies). `service_runs` record the set IDs they executed under. Old campaigns stay reproducible forever.

### 2.7 Cost waterfall

Discovery (cents) → deterministic tiers (~free) → LLM tiers → gated, reserved, revalidated contact enrichment. `depth` gates multipliers (grid search, Yelp, crawl width).

## 3. The Fleet

| # | Service | Entry | Role |
|---|---------|-------|------|
| 1 | Intake ×3 | form / schedule+sheet / authenticated webhook | Validate + normalize → `create_campaign()`; idempotent on request_id |
| 2 | Discovery | webhook / Execute WF | Sources → merge/dedup/filter → `commit_discovery_results()` (one transaction) |
| 3 | Website Auditor | queue | Lighthouse tier + caged agent |
| 4 | Review Miner | queue | 200 newest reviews, typed stats, themes, quote verification |
| 5 | Phone Presence | queue (dependency-blocked) | Passive signals, lineage-linked |
| 6 | Contact Enricher | queue (gate-blocked, spend-time revalidated) | Apollo → DM-hunter → verifications → Hunter |
| 7 | Scorer | queue (event-driven) | Sole assessment writer; deterministic; critic-as-prosecutor |
| 8 | Asset Collector | chain-resolved | References + rights status |
| 9 | Sweeper | schedule | Lease reaper, retries, watermarks, budget reconciliation, fenced finalization |
| 10 | Event Relay | schedule + poke | Outbox delivery worker (leased claims) |
| 11 | Dashboard Sync | delivery-nudged | Postgres → Airtable one-way |

## 4. Canonical Request

```json
{
  "schema_version": "1.0",
  "request_id": "caller-generated-unique-id",
  "business_type": "dentist",
  "geo": { "type": "city_radius", "city": "Austin, TX", "radius_m": 25000 },
  "depth": "quick",
  "volume_cap": 50,
  "budget": { "amount": 25, "currency": "USD" },
  "requires_approval": true,
  "exclusions": { "domains": [], "names": [] },
  "dry_run": false
}
```

`trigger_source` set by intake, never trusted from caller; webhook intake authenticated, caller identity bounds `budget.amount`; `request_id` dedupes retries; non-USD rejected; **`volume_cap > 300` rejected at intake (v1 system maximum)**. Capacity target: **3 concurrent campaigns × 300 leads** with all guarantees intact (per spec clarifications 2026-07-16).

## 5. Ledger Schema (`leadgen_db`; dry-run mirror schema `leadgen_dryrun`)

```sql
campaigns (
  id, request_id UNIQUE, created_at, trigger_source, business_type,
  geo_lat, geo_lng, geo_radius_m, depth, volume_cap, budget_cap_usd,
  requires_approval, approval_status,  -- n/a|pending|approved|rejected|expired
  exclusions jsonb, dry_run bool,
  scoring_config_set_id, chain_rule_set_id, vertical_policy_set_id,
  model_policy_set_id, service_policy_set_id,       -- pinned at creation
  status,        -- created|discovering|analyzing|awaiting_approval|finalizing|complete|failed|canceled
  budget_state,  -- within_budget|near_limit|exhausted
  quality_state, -- healthy|partial|degraded|unusable
  campaign_state_revision, finalization_token,      -- finalization fence
  completed_at, completion_reason, digest_url, sheet_snapshot_url
)

businesses (id, place_id UNIQUE, business_name, website_domain, phone_e164,
            address, lat, lng, dedup_key,
            latest_assessment_id, latest_summary jsonb,   -- convenience only
            sales_status,      -- untouched|contacted|in_talks|customer|bad_lead
            do_not_contact bool,   -- both HUMAN-owned: system reads, never writes
            first_seen_campaign_id, last_updated)          -- CURRENT identity

campaign_business_snapshots (      -- what was true at discovery; digests read THIS
  campaign_lead_id UNIQUE, business_name, website_domain, phone_e164,
  address, lat, lng, captured_at
)

business_relationships (id, business_id, related_business_id,
  relationship_type,  -- same_brand|franchise|parent_org|shared_platform|unknown
  confidence, evidence_id, sales_target_level)  -- location|franchisee|regional|hq

campaign_leads (
  id, campaign_id, business_id, UNIQUE(campaign_id, business_id),
  rediscovered bool, priority int,
  lead_revision int,                -- monotonic watermark
  latest_assessment_id,             -- points ONLY at is_current assessments
  classification, classification_reason, classified_at, contested bool
)

work_items (
  id, campaign_lead_id, service, UNIQUE(campaign_lead_id, service),
  state, priority, available_at,
  execution_attempt_count, provider_deferral_count, retryable_failure_count,
  claimed_at, lease_expires_at, claim_token, worker_id,
  requested_version, processing_version, completed_version,
  gate_assessment_id, gate_revision, gate_threshold_version,  -- enrichment gate record
  error_code, error_detail, completed_at
)

service_runs (
  id, work_item_id, work_attempt, UNIQUE(work_item_id, work_attempt),
  service, input_version, workflow_version, prompt_version,
  model_provider, model_name,
  scoring_config_set_id, /* + other relevant pinned set ids */
  started_at, completed_at, status, tool_call_count,
  input_hash, output_hash, estimated_cost, actual_cost, error_code
)   -- created by claim_work_items(); finalized by complete_*/fail_

discovery_observations (id, campaign_lead_id, provider, query,
                        geo_lat, geo_lng, radius_m, rank, observed_at)

evidence_items (            -- IMMUTABLE
  id, business_id, campaign_id, service, feature_key, product_tag,
  value_jsonb, value_type,  -- boolean|integer|decimal|string|enum|object
  unit, confidence, calculation_version,
  source_provider, source_record_id, source_url, source_fetched_at,
  observed_at, content_hash, excerpt, service_run_id REFERENCES service_runs,
  idempotency_key,          -- hash(campaign_id, service, feature_key, source_provider,
                            --      source_record_id, observed_at, calculation_version,
                            --      content_hash)
  UNIQUE (campaign_id, service, idempotency_key)
)

evidence_links (
  parent_evidence_id, child_evidence_id, relationship_type,
  PRIMARY KEY (parent_evidence_id, child_evidence_id, relationship_type),
  CHECK (parent_evidence_id <> child_evidence_id)
)   -- derived_from|supports|contradicts|supersedes|aggregates
    -- cycle prevention enforced in the insertion function

evidence_verification_events (
  id, evidence_id, status,  -- confirmed|rejected|superseded|disputed
  reason, verifier, verified_at,
  idempotency_key UNIQUE    -- duplicate deliveries never re-insert or bump revision
)

lead_assessments (
  id, campaign_lead_id, scoring_version,
  fit_web_seo, fit_voice_ai, fit_ads_video, fit_consulting,
  opportunity_score, contactability_score, evidence_confidence, completeness,
  best_angle, evidence_watermark, scored_at,
  is_current bool, superseded_at
)   -- stale-version results insert with is_current=false and never
    -- update latest_assessment_id (§6.6)

score_components (id, assessment_id, product, feature_key,
                  observed_value, transformed_value, weight, points, evidence_id)
score_log (id, campaign_lead_id, previous_assessment_id, current_assessment_id,
           change_reason, ts)
critic_reviews (id, campaign_lead_id, assessment_id, critic_type, input_version,
                state,  -- open|reverifying|resolved
                objections_json, resolution, created_at, resolved_at)

budget_transactions (
  id, campaign_id, business_id, service_run_id REFERENCES service_runs,
  service, provider, operation,
  state,   -- reserved|settled|released
  estimated_usd, actual_usd, reserved_at, expires_at, settled_at,
  reconciliation_status,   -- n/a|reconciliation_required|reconciled
  provider_request_id, idempotency_key UNIQUE
)

contacts (id, full_name, linkedin_url, created_at)
contact_business_links (id, contact_id, business_id, title, role_type,
                        relevant_products text[], confidence,
                        source_evidence_id, active)
contact_channels (id, contact_id, channel, value, value_normalized, created_at)

-- referentially-enforced verification (separate tables, no polymorphic subject):
contact_identity_verifications (id, contact_id, method, status,
                                verified_at, expires_at, idempotency_key UNIQUE)
contact_channel_verifications  (id, contact_channel_id, method, status,
                                verified_at, expires_at, idempotency_key UNIQUE)
contact_role_verifications     (id, contact_business_link_id, method, status,
                                verified_at, expires_at, idempotency_key UNIQUE)

campaign_contact_findings (id, campaign_lead_id, contact_business_link_id,
                           contact_channel_id, service_run_id, discovered_at)
suppressions (id, level,  -- email|phone|contact|business|domain
              value, reason, created_at, idempotency_key UNIQUE)

approval_tokens (id, campaign_id, token_hash, issued_to, issued_at,
                 expires_at, used_at, decision, revoked_at)

outbox_events (id, event_type, aggregate_id, payload jsonb, created_at)
outbox_deliveries (id, event_id, destination, UNIQUE(event_id, destination),
                   state,  -- pending|running|delivered|dead_letter
                   available_at, claimed_at, lease_expires_at, claim_token,
                   attempt_count, delivered_at, last_error)

chain_rules (id, source_service, event, field, operator, value,
             target_service,   -- allowlisted via registry
             enabled)
chain_rule_evaluations (
  id, campaign_lead_id, rule_id, input_revision,
  UNIQUE (campaign_lead_id, rule_id, input_revision),
  outcome,  -- fired|suppressed|not_applicable|error
  target_service, evaluated_at, event_id, error_detail
)
revision_impact_rules (cause_type, affected_service, enabled)

provider_limits (provider, credential_scope, requests_per_minute,
                 concurrent_requests, cooldown_until, throttle_state jsonb)
provider_permits (id, provider, credential_scope, service_run_id, operation,
                  acquired_at, expires_at, released_at,
                  state)  -- active|released|expired

config_sets (id, config_type, version, content_hash,
             created_at, activated_at, retired_at)   -- immutable once activated
scoring_config (config_set_id, business_type NULLABLE, product, feature_key,
                transform_type, direction, input_min, input_max, weight,
                point_cap, missing_policy, source_policy, lineage_policy)
service_config (service, claim_batch_size, max_concurrency,
                rate_limit_per_minute, lease_ttl_s, throttle_state, unit_costs)
assets (id, business_id, source, source_url, storage_ref NULLABLE, page_context,
        license_status, ts)
```

**Database security:** workflows connect as roles with **no direct INSERT/UPDATE/DELETE on protected tables** — SELECT plus EXECUTE on approved functions only; separate roles for analyzers / scoring / admin / dashboard-read; service identity validated inside service-specific functions; SECURITY DEFINER functions pin `search_path = pg_catalog, leadgen`.

**Indexes & constraints:** claim path `(service, state, available_at, priority DESC)`; expired-lease partial index (`WHERE state='running'`); `outbox_deliveries(state, available_at)`; `evidence_items(campaign_id, business_id, feature_key)`; `evidence_verification_events(evidence_id, verified_at DESC, id DESC)`; `budget_transactions(campaign_id, state)`; CHECKs: scores 0–100, positive money, nonnegative counters; state transitions enforced in functions.

## 6. Service Designs

Template: *claim (creates service_run) → deterministic tier → LLM tier (permit-gated, schema-validated post-hoc, `renew_lease` for long tiers) → `complete_*_work_item()`.* Paid calls: gate revalidation (where applicable) → `reserve_budget` → `acquire_provider_permit` → call → `settle`/`release`.

**6.1 Discovery** — manifest via `create_campaign()` upstream; geocode; parallel Places (quick 20 / standard 60 / deep grid) + SerpAPI (ranks → `discovery_observations`); normalize/merge/dedup (place_id, phone, fuzzy name+geo); hard filter + suppressions + human sales-status exclusions (contacted/in_talks/customer/do_not_contact skipped unless request overrides; batched cheap-model call for ambiguous categories); volume_cap by evidence richness; **everything lands via one `commit_discovery_results()` transaction** including identity snapshots and the work-item graph.

**6.2 Website Auditor** — Tier 1 deterministic (reachability, SSL, PSI Lighthouse lab scores — CrUX API separately if field data ever needed — viewport, tech fingerprints) as typed evidence; Tier 2 caged agent (Claude, `fetch_page`, cap 6, §7 cage).

**6.3 Review Miner** — newest 200 (Apify; Yelp per vertical policy), oldest→newest; typed stats (`owner_response_rate = 0.18`); cheap-model themes with short quotes; quote checker → verification events (idempotent). Corpora ephemeral (§10).

**6.4 Phone Presence (V1 passive)** — dependency-blocked; derived evidence with `derived_from` links; reruns only via impact rules (its own output never re-triggers it). V2 probe-caller: same contract + `call_transcript_ref`; compliance review first.

**6.5 Contact Enricher** — gate-blocked; **`revalidate_enrichment_gate()` immediately before every reserve** (records gate provenance; failing gate → blocked/skipped_gate, no retry consumed; started calls finish and settle, next tier rechecks). Apollo → (miss) caged DM-Hunter (cap 6, `not_found` rewarded) → **verification dimensions, not a monolithic verdict:** `identity_matched`, `role_source_attested` (LLM may assist source matching; the attestation check itself is deterministic), `channel_deliverable` (Hunter), `verification_expired` (time). Rows land in the three verification tables; findings in `campaign_contact_findings`; suppressions checked at all levels pre-storage.

**6.6 Scorer** — event-driven; recomputes from full ledger state under pinned `scoring_config_set`; one `complete_scorer_work_item()` writes assessment + components + score_log + outbox. **Publication rule:** pointer/classification update only when `processing_version = current lead_revision`; otherwise the assessment inserts `is_current = false`, the pointer stays, and the item returns to pending. Dimensions: opportunity / contactability / evidence_confidence; Hot `≥75 ∧ ≥60 ∧ ≥60`, Warm `opp ≥60`, Cold `≥40`, else disqualified; ranking score for sort only; enrichment gate reads opportunity. **Critic = prosecutor:** `critic_reviews` row on first hot-crossing; objections mark evidence `disputed`; deterministic source verifiers re-run and emit outcomes; Scorer recomputes; unresolved judgment objections → `contested` in digest. Critic never touches points or verification outcomes.

**6.7 Asset Collector** — chain-resolved; references + attribution for Places (never rehosted); default `reference_only`; `storage_ref` only for rights-cleared statuses.

**6.8 Sweeper** — lease reaper (work items, deliveries, permits — fence already blocks zombie commits); retries (`retryable_failure_count ≥ 3` → dead + alert); watermark checks via impact rules; **budget reconciliation** (expired reservations → release / settle via `provider_request_id` / `reconciliation_required` + alert); **fenced finalization**: `begin_campaign_finalization()` → digest (reads snapshots, contested objections, spend) → snapshot sheet → `complete_campaign_finalization()`; state-revision drift aborts back to `analyzing`. Digest failure retries finalization only; snapshot failure = warning. Sets `quality_state` from dead-item ratio + evidence confidence.

**Edge cases:** approval rejected → enrichment `skipped_gate`, campaign finalizes without contacts; approval expired → configurable wait, then finalize-without-enrichment; cancel → pending `canceled`, running tokens invalidated, settlements still honored; zero discoveries → `complete` + `completion_reason = no_results`; quality floor breach → `degraded`/`unusable` + alert.

## 7. Agent & Configuration Security

No credentials in agent context; tools run in credential-holding nodes. `fetch_page`: http/https only, private-IP/localhost/link-local blocked post-DNS, ≤3 re-validated redirects, size cap, HTML→text sanitization. No agent-controlled destinations; no n8n-internal APIs; post-hoc schema validation (failure = work-item failure). `chain_rules.target_service` allowlisted. Authenticated intakes; hashed one-time approval tokens. DB privilege model per §5. External task runners for Code nodes.

## 8. Error Handling

Every failure is a fenced state + error_code; deferrals ≠ failures; provider cooldowns shared via permits/limits; global Error Trigger workflow → Slack + ledger; partial evidence first-class (`completeness`, `evidence_confidence`, `quality_state`).

## 9. Cost Controls

Reserve (gate-revalidated, run-linked) → permit → call → settle/release; Sweeper reconciliation; `budget_state` recompute on settle; `exhausted` → `skipped_budget` + alert. Structural LLM bounds: tool caps, cheap-tier bulk, once-per-crossing critics, `depth` gates. `service_runs` carries per-run cost; digest reports campaign spend.

## 10. Data Rights & Retention

Review corpora ephemeral (typed derived stats + short excerpts persist; `place_id` durable). Places content referenced + attributed, never rehosted; third-party assets `reference_only` by default. Contact PII: expiring verifications, pre-storage suppression checks, geo-appropriate retention set at implementation.

## 11. Testing & Evals

Contract tests (fixtures + pinned data); dry-run campaigns in isolated schema (real LLM calls, fixture providers); golden campaign (~10 hand-labeled businesses) on any config-set change, diffed via `service_runs`; critic evals with seeded failures (planted fake quote → rejected; planted wrong contact → demoted); race/failure injection: worker kill mid-run (exactly one committed result), concurrent claims (never exceed max_concurrency), reservation races at cap boundary, crash between reserve and call (reconciliation), duplicate outbox delivery (idempotent consumers), **finalization race (late event during finalizing → abort + return to analyzing)**, **permit leak on crash (expiry recovers the slot)**.

## 12. Build Order

1. **Database foundation** — migrations; typed evidence; service_runs; revisions + impact rules; **config_sets + pinning**; **DB roles/privilege model**; indexes + constraints.
2. **Queue engine** — claim (semaphore + run creation), renew, per-service completes, fail/defer, counters, **minimal lease reaper**.
3. **Outbox engine** — deliveries, leased claiming, idempotent receipts, retry/dead-letter.
4. **Budget + permit engines** — reserve/settle/release, expiry reconciliation; provider permits/limits.
5. **Intake ×3 + Discovery** (`create_campaign`, `commit_discovery_results`; golden-campaign fixtures ride the engines from here).
6. **Review Miner + Scorer v1** (publication rule, impact routing proven).
7. **Website Auditor + Phone Presence** (dependency/watermark mechanics).
8. **Approval flow + Contact Enricher** (tokens, gate revalidation, verification tables).
9. **Hot-lead critic** (prosecutor flow, critic_reviews).
10. **Finalization** — fenced completion, digest (snapshots), Dashboard Sync, snapshot sheet, Asset Collector.
11. **Golden campaigns, race tests, failure injection → first production campaign at `quick` depth.**

## 13. Decisions Log (v4 additions; v1–v3 history retained in git)

| Decision | Choice | Rejected |
|---|---|---|
| Attempt lifecycle | `service_runs` created at claim; budget references `service_run_id` | Undefined `work_attempt_id` (v3) |
| Completion fence | + `lease_expires_at > now()` on every fenced op (items, deliveries, permits) | Token+state only (v3 — zombie window between expiry and reaper) |
| Revision propagation | `revision_impact_rules` routing; self-requeue forbidden by default | Global bump (v3 — waste + self-trigger loops) |
| Stale publication | `is_current` + pointer-at-current-revision-only | Latest-write pointer (v3 — exposed stale classifications) |
| Finalization | Fenced begin/complete/abort with state revision | Unfenced Sweeper completion (v3 — race with late events) |
| Chain audit | `chain_rule_evaluations`, idempotent per revision | Uncheckable "no decision unevaluated" (v3) |
| Enrichment gate | Revalidated atomically at spend time, provenance recorded | Gate-at-unblock only (v3 — TOCTOU on score drop) |
| Provider concurrency | Leased permits (expiry = crash recovery); deferrals ≠ failures | Counters (v3 — leak on crash) |
| Config | Immutable `config_sets`, campaign-pinned, run-recorded | Editable versioned rows (v3 — irreproducible history) |
| SQL API | Complete incl. create_campaign / commit_discovery_results / finalization / tokens; per-service completes; DEFINER + pinned search_path; no direct DML for workflows | Generic jsonb completion (privilege surface); partial API (v3) |
| Contact verification | Three referential tables + dimension terminology | Polymorphic subject_type/id (no FK); "verifier critic" monolithic verdict |
| History | `campaign_business_snapshots` for digests | Digests reading mutable current identity |
| Idempotency | Defined key derivations; events/verifications/suppressions keyed; revision advances only on effective change | Unkeyed events (duplicate delivery inflating revisions) |
| Currency / dry-run | USD-only reject; isolated dry-run schema | Silent conversion; boolean-only dry-run |

## 14. Plan-Consistency Addendum (fourth review round, 2026-07-16)

Corrections adopted during speckit planning; full contract detail lives in `specs/001-leadgen-fleet/contracts/` (authoritative where it extends this document):

1. **Discovery is fenced work**: `work_items.scope_type (campaign|lead)`; Discovery claims a campaign-scoped item; `commit_discovery_results()` takes work_item_id + claim_token — at-least-once pokes can no longer duplicate provider spend.
2. **Hard budget cap, no overrun path**: `authorize_paid_operation()` atomically allocates budget reservation (of the **maximum billable amount**, provider-enforceable) + provider permit — both or neither; settle enforces `actual ≤ maximum`. Replaces reserve-then-permit.
3. **Dry-run via duplicated function namespaces** (`leadgen.*` / `leadgen_dryrun.*`, own roles, own pinned search_path); schema never a parameter.
4. **Sales state completed**: audited `business_sales_state` + per-delivery `campaign_lead_dispositions` (SC-009 = accepted ÷ reviewed); `record_sales_status()` / `record_lead_disposition()`; bad_lead excluded by default; do-not-contact derived from active suppression, never overridable by campaign parameters.
5. **Caller-scoped idempotency**: `create_campaign(request, caller_identity, trigger_source)` with trusted args; `UNIQUE(caller_identity, request_id)`; response splits `creation_status` from `campaign_status`.
6. **`region` geography removed from v1** (rejected at intake; circles only).
7. **Outbox completed**: `event_class` (state_change|dependency|notification|mirror|audit), `blocks_finalization` only for the first two, event idempotency keys, `event_consumptions` receipts committed with consumer mutations.
8. **Retry transition explicit**: `failed_retryable → pending` via Sweeper `requeue_retryable_work()`; threshold → dead.
9. **Deadlines everywhere**: campaign/approval/critic/reconciliation/finalization-retry deadlines with pinned resolution policies — nothing waits forever.
10. **Permit tokens + `renew_provider_permit()`**: permits fully under the universal fence.
11. **Hot timing**: threshold crossing → `warm + hot_candidate + critic pending`; only critic resolution (or deadline → contested) promotes to hot and fires `lead.hot`.
12. **Config pinning completed**: all policy (chain rules, impact rules, vertical policy, thresholds, quality floors, model assignments, tool limits, retry/deadline policies) in immutable `service_policy_entries` config sets; mutable throttles in `service_runtime_state`.
13. **SC-007 split**: deterministic replay (stored evidence → exact equality) vs. fresh golden regression (tolerance bands).
14. **Assets v1 reference-only**: `storage_ref` NULL in v1; binary storage (S3/MinIO, scanning, retention) explicitly deferred; assets campaign-scoped.
15. **Ops contracted**: `healthcheck()`, `stuck_work_overview`, `campaign_progress`; exact n8n version + reference deployment pinned in `golden/baseline.md`; SC-001 measured p95 excluding approval wait.

**Fifth review round (task-graph audit, 2026-07-16):**

16. **Story boundaries corrected**: US1 = opportunity-ranked fit profiles + `hot_candidate` only; US2 = verified contacts + critic resolution + **first Hot promotion** (Hot is AND-gated on contactability, which only US2 produces); full live end-to-end validation moves after US4. Quickstart V2/V4 split into a/b stages accordingly.
17. **Gate merged into authorization**: `authorize_enrichment_operation()` validates fence + score + approval + suppressions + campaign state AND allocates budget + permit in ONE transaction — separate revalidate-then-authorize calls from separate n8n nodes reopened the TOCTOU the architecture forbids. `revalidate_enrichment_gate()` no longer exists.
18. **Work-item uniqueness in DDL**: scope CHECK + partial unique indexes (`(campaign_id, service) WHERE scope_type='campaign'`, `(campaign_lead_id, service) WHERE scope_type='lead'`) + `one_current_assessment_per_lead` partial unique.
19. **Ads-fit producers assigned**: `ad_presence` + `social_inactive_90d` → Website Auditor Tier 1 (marketing-presence checks); `photo_asset_count` → Discovery metadata. **Asset Collector deferred to v2** (schema ships, chain rule disabled; 16 workflow definitions). `standing_profile_cursors` + `claim_scheduled_profile_slot()` added for scheduled intake.
20. **Source-of-truth precedence declared** (spec → contracts → data-model → tasks → plan → this document): where older sections here contradict the speckit contracts, the contracts win. Spec language updates: durable-not-permanent records, required-vs-nonblocking deliveries, SC-008 as two metrics, Hot-vs-Warm gating explicit, do-not-contact derived solely from suppression.
