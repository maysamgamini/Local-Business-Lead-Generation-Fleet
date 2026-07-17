# Phase 0 Research: Local Business Lead Generation Fleet

**Status**: Complete — no NEEDS CLARIFICATION markers remained after `/speckit-clarify`. This document consolidates the decisions already made and stress-tested during design (three external review rounds; full history in the design doc's Decisions Log). Each entry: Decision / Rationale / Alternatives considered.

## R-01 Runtime & coordination model

- **Decision**: Fleet of 11 independent n8n workflows (self-hosted, queue mode) coordinating via a PostgreSQL ledger — pull-based work queue + transactional outbox. No central orchestrator.
- **Rationale**: Services stay independently invocable/reusable (auditor doubles as a sales tool); completion is detected, not orchestrated; n8n queue mode provides instance-level spike protection while SQL claim functions provide per-service concurrency control.
- **Alternatives**: single AI-agent-with-tools per lead (unpredictable cost, unenforceable gates); central orchestrator workflow (execution-duration walls, poor fit for async work); pure webhook choreography without a ledger queue (no concurrency caps, no stuck-lead visibility).

## R-02 Transactional integrity in n8n

- **Decision**: All state mutations behind ~25 SECURITY DEFINER PL/pgSQL functions, each called from a single n8n Postgres node; workflows hold SELECT + EXECUTE only (no direct DML on protected tables).
- **Rationale**: Separate n8n Postgres nodes run separate autocommit transactions — multi-node write sequences are not atomic. Fencing, budget reservation, and outbox writes must commit or roll back together. Function-only access also closes the privilege-escalation surface.
- **Alternatives**: multi-node write sequences (rejected: non-atomic); one generic `complete_work_item(jsonb)` (rejected: privilege surface — per-service completion functions instead); external service layer (rejected: violates n8n-purist runtime).

## R-03 Work queue semantics

- **Decision**: Generic `work_items` table; claim via SQL function computing `available_slots = max_concurrency − running-with-unexpired-leases`, batch `FOR UPDATE SKIP LOCKED`; lease + fencing token; universal fence `state='running' AND claim_token=? AND lease_expires_at > now()`; poke webhooks trigger immediate polls without breaking caps.
- **Rationale**: `LIMIT` alone caps batches, not concurrency; fencing without lease-expiry check leaves a zombie-commit window between expiry and reaper.
- **Alternatives**: per-analyzer status columns (shared claim metadata corrupts under concurrency); Redis/BullMQ queue (second source of truth outside the ledger); n8n queue mode alone (no per-service caps).

## R-04 Rerun & watermark model

- **Decision**: `requested/processing/completed_version` coalescing on work items; monotonic `lead_revision` (never timestamps); `revision_impact_rules` route which causes re-queue which services; self-requeue forbidden by default; stale assessments publish `is_current = false` and never move the authoritative pointer.
- **Rationale**: Coalesces event bursts into minimum recomputation; prevents self-triggering loops (phone evidence must not re-trigger Phone Presence); never exposes known-stale classifications.
- **Alternatives**: single input_version (loses mid-run events or invalidates live workers); global revision bump to all services (waste + loops); timestamp watermarks (clock skew, non-monotonic).

## R-05 Evidence model

- **Decision**: Immutable `evidence_items` with typed values (`value_jsonb`/`value_type`/`unit`/`confidence`), scoped idempotency `UNIQUE(campaign_id, service, idempotency_key)` with defined key derivation; event-sourced verification (`evidence_verification_events`, latest wins, only `confirmed` scores, idempotency-keyed); lineage via `evidence_links` relation table (PK + self-link CHECK + cycle prevention in function).
- **Rationale**: Deterministic scoring needs machine-readable values, not parsed excerpts; append-only + mutable flag was self-contradictory; retries must not duplicate evidence or inflate revisions; derived evidence (Phone Presence from reviews) must not double-count roots.
- **Alternatives**: mutable `verified` boolean (contradiction); parent-ID arrays (no FK, no recursion); global idempotency (cross-campaign collisions).

## R-06 Scoring & qualification

- **Decision**: Deterministic scoring in one Code node from confirmed evidence only, driven entirely by expanded `scoring_config` (transform_type, direction, bounds, point_cap, missing/source/lineage policies), pinned per campaign via immutable `config_sets`. Three separate dimensions — opportunity, contactability, evidence-confidence — AND-gated for classification (Hot ≥75/≥60/≥60). `score_components` explain every point.
- **Rationale**: "Why is this 83?" must be answerable from data (SC-003); contact reachability must not inflate opportunity; frozen config sets keep past campaigns reproducible (SC-007).
- **Alternatives**: LLM-assigned holistic scores (unexplainable, non-reproducible); single 0–130 composite (reachability masqueraded as opportunity); editable versioned config rows (history rewritten in place).

## R-07 Critic architecture

- **Decision**: Three bounded critics, always cross-model-family from their generator: evidence-quote checker (string-match gate at Review Miner), decision-maker verification (deterministic attestation checks, LLM assists source matching only), hot-lead critic as **prosecutor** — opens `critic_reviews`, marks evidence `disputed`, deterministic source verifiers re-run, Scorer recomputes; unresolved judgment objections ship `contested`. One review per hot-crossing.
- **Rationale**: Cross-family critics have uncorrelated blind spots; an LLM must never directly invalidate deterministically verified facts or touch points; unbounded critique loops eat budgets.
- **Alternatives**: critic emits verification outcomes directly (LLM overruling deterministic verification); unlimited revision loops; same-model critique.

## R-08 Budget safety

- **Decision**: `authorize_paid_operation()` atomically allocates a budget reservation of the **maximum billable amount** (provider-enforceable: capped tokens × pinned price table, actor limits) AND the provider permit — both or neither; `settle` enforces `actual_usd ≤ maximum` (the hard cap has no overrun path); reservations expire and the Sweeper reconciles (release / settle via `provider_request_id` / flag `reconciliation_required`); available = cap − settled − active-reserved; enrichment gate revalidated atomically immediately before every authorization (gate provenance recorded); settlement survives campaign cancellation; operations with no enforceable maximum do not run under the strict cap.
- **Rationale**: Sum-at-claim has a TOCTOU race (two workers both see the last $8); best-effort estimates with settle-overrun contradict SC-005 outright; separate reserve-then-permit can strand reserved money waiting on provider capacity; crashed workers must not strand reserved funds; a score can drop between gate-opening and spending; canceled campaigns still owe for started calls (SC-005: zero overruns ever).
- **Alternatives**: spend counters (not atomic); sum + 10% headroom (probabilistic, not a guarantee); estimate-based reservation with overrun settlement (violates the hard cap); sequential reserve→permit (deadlock-prone); gate checked only at unblock time (stale justification spends real money).

## R-09 Provider rate limiting

- **Decision**: Global per-credential token bucket (`provider_limits`) + leased `provider_permits` tied to service_runs, allocated atomically with budget inside `authorize_paid_operation()`; permits carry `permit_token` and support `renew_provider_permit()` (fenced — expired permits can't renew, slots reclaim crash-safely); deferrals return `retry_at` and increment `provider_deferral_count`, never failure counts.
- **Rationale**: Multiple services share credentials (Claude: auditor + critic) — per-service throttling lets combined traffic exceed quota; counter-based semaphores leak slots on crash; a cooldown is not an error.
- **Alternatives**: per-service throttle only; concurrency counters; treating 429 deferrals as retryable failures (leads die from provider weather).

## R-10 Discovery sources & strategy

- **Decision**: Google Places Text Search (quick=20 / standard=60 / deep=grid over sub-circles) merged with SerpAPI Maps (exact join on place_id; adds local-pack rank → `discovery_observations`). Volume cap ranks by evidence richness (review count × recency). Location = unit of discovery; typed evidence-backed `business_relationships` (never bare shared-domain inference — booking platforms/Linktree share domains). Rediscovery links + refreshes, never duplicates; snapshots preserve per-campaign identity.
- **Rationale**: SerpAPI's unique value is rank-as-SEO-evidence, not coverage; 2–10-location brands are the ICP, so franchise modeling is core; review-rich businesses give analyzers material (better evidence per dollar).
- **Alternatives**: single source; domain-first dedup (merges franchises); rank stored on businesses (it's query/geo/date-relative); "underserved-first" ranking (starves analyzers of evidence — revisit post-pilot).

## R-11 Analysis tiers per product line

- **Decision**: Website — PageSpeed Insights API (Lighthouse lab) + tech fingerprints deterministically, then caged Claude agent (fetch_page, cap 6 calls). Reviews — Apify newest-200 processed oldest→newest, deterministic stats (trajectory, owner response rate), cheap-model theme extraction, quote verification gate. Phone — v1 passive from sibling evidence with `derived_from` lineage; v2 probe-caller drops in behind the same contract (compliance review first). Ads/creative — presence checks + rights-labeled asset references only.
- **Rationale**: Cheap deterministic tiers gate expensive LLM tiers (waterfall); passive phone signals ("nobody answers the phone" reviews) are strong and compliance-free in v1; CrUX field data via separate CrUX API if ever needed (Google discontinuing PSI passthrough — verify at implementation).
- **Alternatives**: agent-first analysis (cost unbounded); warehousing full review corpora (data-rights exposure — ephemeral corpora + derived work product instead); licensed B2B data replacing review mining (rejected: review pain is the differentiator and licensed databases don't carry it).

## R-12 Contact enrichment & verification

- **Decision**: Apollo by domain (title filter per business_type from vertical policy) → caged DM-hunter on miss (web_search + fetch_page, cap 6, explicit `not_found` rewarded) → three referential verification tables (identity / channel / role — no polymorphic FKs) with `expires_at`; `campaign_contact_findings` for campaign provenance; suppression enforced at all five levels pre-storage; Hunter deliverability last.
- **Rationale**: Local SMBs are Apollo's weak spot — the hunter agent covers the gap but must be allowed to fail honestly; verification decays; later campaigns' discoveries must not rewrite older campaigns' contactability; separate dimensions (identity_matched / role_source_attested / channel_deliverable) instead of one LLM verdict.
- **Alternatives**: single dm_* columns (one DM, no decay); polymorphic verification subject (not FK-enforceable); LLM as verification authority.

## R-13 Security model

- **Decision**: DB roles per service class, EXECUTE-only on approved functions, SECURITY DEFINER with pinned `search_path`; agent cage — no credentials in agent context, private-IP/localhost blocking post-DNS, ≤3 re-validated redirects, size caps, HTML→text sanitization, post-hoc schema validation; `chain_rules.target_service` allowlisted via registry; hashed one-time expiring approval tokens; authenticated webhook intake with caller-bound budget limits; external task runners for Code nodes.
- **Rationale**: Agents ingest hostile web content by design (SSRF/prompt-injection surface); raw URLs in config tables are an SSRF + credential-leak vector; approval links leak.
- **Alternatives**: trust-the-workflow DML access; URL-based chain config; boolean dry_run without schema isolation (rejected — isolated `leadgen_dryrun` schema instead).

## R-14 Human surfaces

- **Decision**: Airtable Interface as read-only dashboard (Dashboard Sync mirror, one-way); Google Sheets ICP input sheet (read by Scheduled Intake only) strictly separate from output snapshots (write-only); Slack milestones; approval via n8n Form + signed link writing straight to Postgres.
- **Rationale**: Machines never read mirrors (Airtable's ~5 req/s ceiling and non-atomicity disqualify it as a ledger); approval inside Airtable would contradict the read-only-mirror rule.
- **Alternatives**: Airtable as system of record (rejected round 1); NocoDB/Grafana dashboards (viable later swap; Airtable wins on polish now).

## R-15 Verification items deferred to implementation (tracked, not blocking)

- Confirm current Places Text Search pagination ceiling (documented 60/3×20 — "subject to change").
- Confirm PSI API field-data status vs. CrUX API split at build time.
- Set contact-PII retention windows per target-geo requirements (assumption documented in spec).
- n8n LTS version pin + external task-runner configuration flags at deploy time.
