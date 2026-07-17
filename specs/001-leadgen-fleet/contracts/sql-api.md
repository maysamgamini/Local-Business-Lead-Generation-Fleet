# Contract: Transactional SQL Function API

The core contract of the system. Every state mutation goes through these SECURITY DEFINER PL/pgSQL functions, each invoked from a **single** n8n Postgres node (n8n Postgres nodes autocommit per node — multi-node write sequences are forbidden for state mutation). Workflow DB roles hold SELECT + EXECUTE only; no direct DML on protected tables.

**Dual namespaces**: the full function set exists twice — `leadgen.*` (production) and `leadgen_dryrun.*` (dry-run) — each statically bound to its own schema via pinned `search_path` and callable only by its own DB roles. The intake workflow selects credential + namespace **after** validating `dry_run`; a schema name is never a function parameter.

**Universal fence** — every completion / renewal / release / delivery operation requires:
`state = 'running' AND <ownership_token> = :token AND lease_expires_at > now()` (work items: `claim_token`; deliveries: `claim_token`; provider permits: `permit_token`).
Zero rows affected ⇒ the caller lost ownership and MUST discard its result (the entire write rolls back — a stale worker leaves no trace).

**Work scope**: `work_items` carries `scope_type` (`campaign | lead`) — Discovery runs as a **campaign-scoped work item** under the same claim/lease/fence discipline as every analyzer. Nothing that spends provider money runs outside the fence.

## Campaign lifecycle

| Function | Contract |
|---|---|
| `create_campaign(request jsonb, caller_identity uuid, trigger_source intake_source) → (campaign_id, creation_status)` | `caller_identity` and `trigger_source` are **trusted arguments** supplied by the intake workflow from authentication/context — never from the JSON body. Validates canonical request; idempotent on `UNIQUE(caller_identity, request_id)` (replay → `creation_status='existing'`); pins active config sets; creates the campaign-scoped `discovery` work item (`pending`); sets deadline columns from pinned deadline policy |
| `commit_discovery_results(campaign_id, work_item_id, claim_token, payload jsonb) → summary` | **Fenced** like every completion. ONE idempotent transaction: business upserts, snapshots, campaign_leads, discovery_observations, initial evidence, lead-scoped work-item graph with correct initial states, campaign status, outbox events |
| `issue_approval_token(campaign_id, issued_to)` / `record_approval(raw_token, decision)` | Hash-only storage; locked one-time consumption; rejects expired/reused/revoked/finalized |
| `record_sales_status(business_id, sales_status, changed_by, reason)` | Appends to audited `business_sales_state`; humans only (dedicated role); dashboard mirror is never a write path |
| `record_lead_disposition(campaign_lead_id, outcome, reviewed_by, rejection_reason)` | Per-delivery accepted/rejected review — the SC-009 data source |
| `cancel_campaign(campaign_id)` | Pending → canceled; running claim tokens invalidated; budget settlement remains possible; spend history preserved |
| `begin_campaign_finalization(campaign_id) → finalization_token` | Locks campaign; verifies: all work terminal, latest assessments cover current `lead_revision`, critic reviews resolved **or past `critic_deadline_at`** (deadline policy applies: unresolved → `contested`), no undelivered events **with `blocks_finalization = true`**, budget reconciliation clean or past `reconciliation_deadline_at` (→ flagged, quality degraded); captures `campaign_state_revision` |
| `complete_campaign_finalization(campaign_id, token, payload)` / `abort_campaign_finalization(...)` | Complete succeeds only if state revision unchanged; score-affecting mutation during finalizing invalidates token → back to `analyzing` |

**Deadlines (pinned per campaign from deadline policy)**: `campaign_deadline_at`, `approval_deadline_at`, `critic_deadline_at`, `reconciliation_deadline_at`, `finalization_retry_deadline_at`. At each, the pinned policy resolves: finalize without enrichment / mark contested / complete as partial-degraded / flag for admin / fail as unusable. Nothing waits forever (SC-010).

## Queue engine

| Function | Contract |
|---|---|
| `claim_work_items(service, worker_id) → setof (work_item_id, claim_token, service_run_id, processing_version, scope refs)` | Locks service_config row; `slots = max_concurrency − count(running, unexpired)`; claims `min(claim_batch_size, slots)` FOR UPDATE SKIP LOCKED over `pending` items with `available_at <= now()`; creates `service_runs` row; `processing_version := requested_version`; increments `execution_attempt_count` |
| `renew_lease(work_item_id, claim_token)` | Fenced; post-expiry renewal fails — worker discards result |
| `complete_discovery_work_item` (via `commit_discovery_results`), `complete_analysis_work_item`, `complete_scorer_work_item`, `complete_enrichment_work_item`, `complete_collector_work_item` | Fenced; service-specific payload validation; ONE transaction: evidence + links (cycle check) + verification events + assessments/contacts + service_run finalization + `evaluate_chain_rules()` + outbox events (with `event_class`) + work-item update. Version rule: `requested > processing ⇒ pending` else `done`. Scorer variant enforces is_current publication + hot-candidate flow (see service-contracts) |
| `fail_work_item(work_item_id, claim_token, error_code, detail)` | Fenced; run finalized failed; `state = failed_retryable` with exponential `available_at`; increments `retryable_failure_count` |
| `defer_work_item(work_item_id, claim_token, retry_at, cause)` | Cooldown/capacity/waiting — increments `provider_deferral_count` only; never the failure counter |
| `requeue_retryable_work() → count` | **Explicit Sweeper transition**: `failed_retryable` with `available_at <= now()` → `pending`; `retryable_failure_count >= threshold` → `dead` + alert event. Without this call, failed items are unclaimable by design (claim only takes `pending`) |
| `advance_lead_revision(campaign_lead_id, cause_type)` | Effective-change detection (idempotent replays no-op); bumps `requested_version` only per `revision_impact_rules`; self-requeue excluded by default |

## Money & providers — atomic authorization

| Function | Contract |
|---|---|
| `authorize_paid_operation(work_item_id, claim_token, service_run_id, provider, credential_scope, operation, maximum_billable_usd, idem_key) → (authorization_id, permit_id, permit_token, expires_at) \| 'insufficient_budget' \| retry_at` | **Atomic**: budget reservation of the **maximum billable amount** AND provider permit allocated together, or neither. `maximum_billable_usd` must be enforceable provider-side (capped input size, capped output tokens × pinned price table, actor limits); operations with no enforceable maximum MUST NOT run under the strict cap. Available = cap − settled − active-reserved. For non-gated spends (analyzer LLM calls, review fetches) |
| `authorize_enrichment_operation(work_item_id, claim_token, service_run_id, provider, credential_scope, operation, maximum_billable_usd, idem_key) → same as above \| 'gate_failed:blocked' \| 'gate_failed:skipped_gate'` | **The gated variant — ONE transaction** (separate revalidate-then-authorize calls from separate n8n nodes would reopen the TOCTOU the design forbids): work-item fence → latest opportunity score + assessment revision → approval state → suppressions → campaign state → budget reservation (max-billable) → provider permit. All-or-nothing; gate provenance (`gate_assessment_id`, `gate_revision`, `gate_threshold_version`) recorded on pass; gate failure returns `blocked` (analysis may still arrive) or `skipped_gate` (analysis final) and consumes no retry |
| `settle_paid_operation(authorization_id, permit_token, actual_usd, provider_request_id)` | **`actual_usd <= maximum_billable_usd` enforced** — the hard-cap guarantee (SC-005) has no overrun path; violations raise and flag `reconciliation_required` for admin. Valid after work-item cancellation; recomputes `budget_state` |
| `release_paid_operation(authorization_id, permit_token)` | Provably-uncharged calls; frees reservation + permit together |
| `renew_provider_permit(permit_id, permit_token)` | For provider calls outliving the permit lease; fenced — expired permits cannot renew, and their concurrency slot is reclaimable |
| `reconcile_expired_reservations()` | Sweeper: expired authorizations → release (provably uncharged) / settle (cost known via `provider_request_id`) / `reconciliation_required` + alert |

## Events, chaining, config, ops

| Function | Contract |
|---|---|
| `evaluate_chain_rules(campaign_lead_id, event, input_revision)` | `chain_rule_evaluations` UNIQUE per (lead, rule, revision) — idempotent; fired ⇒ outbox event to allowlisted `target_service` |
| `claim_outbox_deliveries(destination, worker_id)` / `complete_outbox_delivery(delivery_id, claim_token, result_hash)` / `fail_outbox_delivery(...)` | Lease + fence; completion records the **consumption receipt** (`event_consumptions`, PK (event_id, destination)) in the same transaction; DB-mutating consumers commit receipt + mutation together; max attempts → dead_letter. Only `event_class IN (state_change, dependency)` events block finalization; notification/mirror/audit classes never do |
| `record_suppression(level, value, reason)` | Idempotency-keyed; business-level suppression is the single source from which visible do-not-contact is derived |
| `activate_config_set(config_type, version)` | Immutable once activated; covers ALL pinned policy: scoring, chain rules, revision impact rules, vertical policy (title mappings, category allowlists), classification/enrichment thresholds, quality floors, model assignments, agent tool limits, retry + deadline policies. Mutable runtime state (throttles, cooldowns) lives separately in `service_runtime_state` and is never pinned |
| `claim_scheduled_profile_slot(profile_source, profile_row_id, scheduled_slot) → 'claimed' \| 'already_claimed'` | Locks the `standing_profile_cursors` row; atomically prevents two schedule executions from creating the same campaign; records `last_scheduled_slot` + `last_campaign_id` (deployed with US3) |
| `reap_expired_leases()` | Sweeper: work items, deliveries, permits past lease → recoverable states |
| `requeue_stale_assessments()` | Sweeper: assessments behind `lead_revision` → re-queue per impact rules |
| `healthcheck() → jsonb` | Verifies roles, function set, active config sets, seed presence — contracted for quickstart smoke test |

**Contracted views**: `stuck_work_overview` (non-terminal items with stale leases/deadlines), `campaign_progress` (dashboard source). Defined in `db/migrations/*views.sql`.

## Required uniqueness constraints (enforced in DDL, not just convention)

```sql
-- exactly one campaign-scoped work item per service (nullable-column UNIQUE won't do this)
CREATE UNIQUE INDEX one_campaign_work_item_per_service
  ON work_items (campaign_id, service) WHERE scope_type = 'campaign';
CREATE UNIQUE INDEX one_lead_work_item_per_service
  ON work_items (campaign_lead_id, service) WHERE scope_type = 'lead';
ALTER TABLE work_items ADD CHECK (
  (scope_type = 'campaign' AND campaign_id IS NOT NULL AND campaign_lead_id IS NULL) OR
  (scope_type = 'lead'     AND campaign_id IS NOT NULL AND campaign_lead_id IS NOT NULL));

-- at most one current assessment per lead
CREATE UNIQUE INDEX one_current_assessment_per_lead
  ON lead_assessments (campaign_lead_id) WHERE is_current = true;
```

## Security requirements (every function, both namespaces)

- SECURITY DEFINER, pinned `search_path` (`pg_catalog, leadgen` or `pg_catalog, leadgen_dryrun`); no dynamic SQL from workflow-supplied values; payload size/shape/state-transition validation inside; service identity validated in service-specific functions; human-action functions (`record_sales_status`, `record_lead_disposition`, `record_approval`) restricted to the human-actions role.
- Typed errors (`insufficient_budget`, `fence_violation`, `invalid_transition`, `max_billable_exceeded`, …) that workflows map to defer/fail semantics.
