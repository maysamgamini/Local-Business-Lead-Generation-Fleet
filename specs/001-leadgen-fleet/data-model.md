# Data Model: Local Business Lead Generation Fleet

Authoritative DDL lives in the design doc §5 (v4) and will be materialized in `db/migrations/`. This document is the planning view: entities, relationships, state machines, and validation rules. Database: `leadgen_db` (dry-run mirror schema: `leadgen_dryrun`). **All writes via the SQL function API** ([contracts/sql-api.md](./contracts/sql-api.md)) — workflows have no direct DML.

## Entity groups

### 1. Campaign & request

| Entity | Purpose | Key fields | Notes |
|---|---|---|---|
| `standing_profile_cursors` | Scheduled-intake slot claiming | profile_source, profile_row_id, last_scheduled_slot, last_campaign_id, updated_at, version | Claimed atomically via `claim_scheduled_profile_slot()` — two schedule firings can never create the same campaign (deployed with US3) |
| `campaigns` | One research request + lifecycle | `caller_identity`, `request_id`, `UNIQUE(caller_identity, request_id)` (caller-scoped idempotency; caller_identity is a trusted intake argument), geo (lat/lng/radius — v1 circles only; `region` geography removed from v1), `depth`, `volume_cap` (≤300), `budget_cap_usd`, `approval_status`, pinned `*_config_set_id` for ALL policy types, `status`, `budget_state`, `quality_state`, `campaign_state_revision`, `finalization_token`, `completion_reason`, deadlines (`campaign_deadline_at`, `approval_deadline_at`, `critic_deadline_at`, `reconciliation_deadline_at`, `finalization_retry_deadline_at`) | Lifecycle, budget condition, and quality are separate fields; every wait is deadline-bounded (SC-010) |
| `approval_tokens` | Durable one-time approval links | `token_hash` (never raw), `expires_at`, `used_at`, `decision`, `revoked_at` | Consumed under row lock by `record_approval()` |
| `business_sales_state` | Audited human sales-status changes | business_id, sales_status, changed_by, changed_at, reason | Append-only audit; current status derived from latest row; set via `record_sales_status()` only |
| `campaign_lead_dispositions` | Per-delivered-lead sales review | campaign_lead_id, outcome (accepted\|rejected\|not_reviewed), reviewed_by, reviewed_at, rejection_reason | SC-009 source: accepted ÷ (accepted+rejected), not_reviewed excluded |

**Campaign lifecycle**: `created → discovering → analyzing → [awaiting_approval] → finalizing → complete | failed | canceled`. `budget_state` (`within_budget | near_limit | exhausted`) and `quality_state` (`healthy | partial | degraded | unusable`) are orthogonal conditions, not lifecycle states.

### 2. Business identity & campaign participation

| Entity | Purpose | Key fields | Notes |
|---|---|---|---|
| `businesses` | Current identity of a real-world location | `place_id UNIQUE`, domain, phone_e164, `dedup_key`, `latest_assessment_id` + `latest_summary` (convenience), `sales_status` (derived from latest `business_sales_state` row) | Location = unit of discovery. **Do-not-contact is derived from the active business-level suppression record** — one source of truth, never overridable by campaign parameters. Eligibility defaults: untouched eligible; contacted / in_talks / customer / bad_lead excluded (authorized request may override sales-status exclusions only, never suppressions) |
| `business_relationships` | Multi-location / franchise links | `relationship_type` (same_brand\|franchise\|parent_org\|shared_platform\|unknown), `confidence`, `evidence_id`, `sales_target_level` | Never inferred from shared domain alone |
| `campaign_business_snapshots` | Identity as observed during the campaign | name/domain/phone/address at `captured_at` | Digests read snapshots, never current identity (FR-025) |
| `campaign_leads` | One business in one campaign | `UNIQUE(campaign_id, business_id)`, `lead_revision` (monotonic watermark), `latest_assessment_id`, `classification` + reason + timestamp, `hot_candidate` + `critic_state`, `contested` | Classification is campaign-relative. Hot timing: crossing thresholds sets `classification=warm, hot_candidate=true, critic_state=pending`; only critic resolution (or deadline → contested) promotes to `hot` and fires the `lead.hot` event |
| `discovery_observations` | Query/geo/date-scoped facts | provider, query, geo, `rank`, `observed_at` | serp rank lives here, not on businesses |

**Dedup & rediscovery**: join on `place_id` (exact) → phone_e164 → fuzzy name+geo. Rediscovered businesses are linked into the new campaign and refreshed; earlier campaigns' delivered results never change (snapshots + campaign-scoped assessments).

### 3. Work queue & execution

| Entity | Purpose | Key fields | Notes |
|---|---|---|---|
| `work_items` | One unit of work, campaign- or lead-scoped | **`scope_type` (campaign\|lead), `campaign_id`, `campaign_lead_id NULLABLE`** with **scope CHECK** (campaign ⇒ lead_id NULL; lead ⇒ both NOT NULL) and **partial unique indexes** — `(campaign_id, service) WHERE scope_type='campaign'`, `(campaign_lead_id, service) WHERE scope_type='lead'` (a plain UNIQUE over nullable columns would not prevent duplicate campaign-scoped Discovery rows); `state`, `priority`, `available_at`, 3 counters, lease fields, versions, gate provenance | Universal fence: `state='running' AND claim_token=? AND lease_expires_at>now()`. Retry: `failed_retryable → pending` via `requeue_retryable_work()`; threshold → `dead` |
| `service_runs` | One execution attempt | `UNIQUE(work_item_id, work_attempt)`, workflow/prompt versions, model, config-set ids, tool_call_count, input/output hashes, costs, status | Created by `claim_work_items()`; finalized by complete/fail |
| `revision_impact_rules` | Which cause re-queues which service | `cause_type`, `affected_service`, `enabled` | Self-requeue forbidden by default |

**Work-item states**: non-terminal `blocked | pending | running | failed_retryable | waiting_approval`; terminal `done | dead | skipped_gate | skipped_budget | skipped_prerequisite | canceled`.

**Initial states at discovery commit**: website+reviews → `pending`; phone → `blocked` (deps: website & reviews terminal); enrichment → `blocked` (resolves via scorer events + approval); assets → `blocked` (chain rules); missing prerequisite → `skipped_prerequisite` + evidence fact.

**Version coalescing**: on evidence event `requested_version = max(requested_version, lead_revision)`; claim sets `processing_version := requested_version`; completion: `requested_version > processing_version ? pending : done`.

### 4. Evidence & verification

| Entity | Purpose | Key fields | Notes |
|---|---|---|---|
| `evidence_items` | Immutable typed finding | `feature_key`, `value_jsonb` + `value_type` + `unit` + `confidence`, `calculation_version`, source fields, `content_hash`, `excerpt` (human explanation only), `service_run_id` FK, `UNIQUE(campaign_id, service, idempotency_key)` | Key = hash(campaign, service, feature_key, provider, source_record, observed_at, calc_version, content_hash) |
| `evidence_links` | Lineage | `PK(parent, child, relationship_type)`, `CHECK(parent<>child)`, cycle check in function | `derived_from` prevents double-counting roots |
| `evidence_verification_events` | Event-sourced verification | `status` (confirmed\|rejected\|superseded\|disputed), `verifier`, `idempotency_key UNIQUE` | Latest event wins; only `confirmed` scores; duplicates never advance revision |

### 5. Assessment & scoring

| Entity | Purpose | Key fields | Notes |
|---|---|---|---|
| `lead_assessments` | Point-in-time scoring | 4 fit scores, `opportunity_score`, `contactability_score`, `evidence_confidence`, `completeness`, `best_angle`, `evidence_watermark`, `scoring_version`, `is_current`, `superseded_at`; **partial unique index `(campaign_lead_id) WHERE is_current = true`** | Stale results (`processing_version < lead_revision`) insert `is_current=false`, never move the pointer |
| `score_components` | Per-point explanation | product, feature_key, observed→transformed value, weight, points, `evidence_id` | SC-003: every point traceable |
| `score_log` | Assessment transitions | `previous_assessment_id`, `current_assessment_id`, `change_reason` | |
| `critic_reviews` | Durable prosecutor record | `critic_type`, `input_version`, `state` (open\|reverifying\|resolved), `objections_json`, `resolution` | One per hot-crossing; critic never writes scores/verifications |

**Classification rule** (campaign-relative): Hot `opportunity ≥75 AND contactability ≥60 AND confidence ≥60`; Warm `opp ≥60`; Cold `≥40`; else disqualified. Thresholds come from the pinned scoring config set.

### 6. Contacts & suppression

| Entity | Purpose | Notes |
|---|---|---|
| `contacts` / `contact_business_links` / `contact_channels` | Person / role-at-business (title, role_type, relevant_products, confidence, source evidence) / email+phone channels | Multiple DMs per business; buyer differs per product |
| `contact_identity_verifications`, `contact_channel_verifications`, `contact_role_verifications` | Separate referential tables (no polymorphic FK), each with `method`, `status`, `verified_at`, `expires_at`, idempotency key | Dimensions: identity_matched / role_source_attested / channel_deliverable; expiry removes contactability credit |
| `campaign_contact_findings` | Which campaign discovered what | Later campaigns never rewrite older campaigns' contactability |
| `suppressions` | Do-not-contact at 5 levels | email \| phone \| contact \| business \| domain; checked before storing outreach-usable data |

### 7. Money

| Entity | Purpose | Notes |
|---|---|---|
| `budget_transactions` | authorize (max-billable) → settle \| release | Created only by `authorize_paid_operation()` **atomically with a provider permit** (both or neither); reservation = **maximum billable amount** (enforceable provider-side: capped tokens × pinned prices, actor limits); **`actual_usd ≤ maximum` enforced at settle — no overrun path (SC-005)**; `expires_at` for crash recovery; `reconciliation_status`; `provider_request_id`; `idempotency_key UNIQUE`; settlement valid after cancellation. Available = cap − settled − active-reserved |

### 8. Events, chaining, limits, config

| Entity | Purpose | Notes |
|---|---|---|
| `outbox_events` + `outbox_deliveries` + `event_consumptions` | Transactional outbox, per-destination fan-out, receipts | Events carry `event_class` (state_change \| dependency \| notification \| mirror \| audit), `blocks_finalization` (true only for state_change/dependency), `effective_revision`, `idempotency_key UNIQUE`. Deliveries: `UNIQUE(event_id, destination)`, leased claims. Consumptions: PK (event_id, destination), receipt committed with the consumer's mutation. Failed Slack/mirror deliveries never block completion |
| `chain_rules` + `chain_rule_evaluations` | Conditional service chaining, durably audited | `UNIQUE(campaign_lead_id, rule_id, input_revision)`; `target_service` allowlisted; chain rules belong to a pinned config set |
| `provider_limits` + `provider_permits` | Global per-credential RPM + leased concurrency slots | Permits carry **`permit_token`** — release/renew fenced like all ownership operations (`renew_provider_permit()` for long calls); expiry reclaims slots crash-safely; deferrals return `retry_at` |
| `config_sets` + `scoring_config` + `service_policy_entries` + `service_config` + `service_runtime_state` | Immutable pinned policy vs. mutable runtime state | Config sets cover ALL policy: scoring, chain rules, revision impact rules, vertical policy (titles, category allowlists), classification/enrichment thresholds, quality floors, model assignments, agent tool limits, retry + deadline policies (`service_policy_entries`). `service_runtime_state` holds throttles/cooldowns — mutable, never pinned. Activated sets never modified |
| `assets` | Rights-labeled references, campaign-scoped | + `campaign_lead_id`, `service_run_id`, `observed_at`; `license_status` default `reference_only`. **v1 is reference-only: `storage_ref` stays NULL; the Asset Collector workflow itself is deferred to v2** (schema ships now, chain rule disabled; `photo_asset_count` evidence comes from Discovery metadata) |

## Cross-cutting validation rules

- Scores constrained 0–100 (CHECK); money positive; counters nonnegative; state transitions enforced inside functions only.
- Only evidence whose **latest** verification event is `confirmed` may contribute score points; derived evidence counts only as its pinned lineage_policy allows.
- `lead_revision` advances only on effective state change (idempotent replays no-op) and only via `advance_lead_revision()`.
- Every paid call: `authorize_paid_operation()` — or for enrichment, `authorize_enrichment_operation()`, which validates the gate (score, approval, suppressions, campaign state) **inside the same transaction** that reserves budget and allocates the permit — → call (renewing permit/lease as needed) → settle (`actual ≤ maximum` enforced) or release. No exceptions, no overrun path, no gate/spend TOCTOU window.
- Required indexes: claim path `(service, state, available_at, priority DESC)`; expired-lease partial (`WHERE state='running'`); `outbox_deliveries(state, available_at)`; `evidence_items(campaign_id, business_id, feature_key)`; `evidence_verification_events(evidence_id, verified_at DESC, id DESC)`; `budget_transactions(campaign_id, state)`.
