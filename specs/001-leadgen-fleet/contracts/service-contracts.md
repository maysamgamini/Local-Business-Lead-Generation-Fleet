# Contract: Fleet Service Interfaces

**Active service roles (Asset Collector deferred to v2; `social` added 2026-07-18), deployed n8n workflow definitions** — plus the **Report Generator** (`report-generator.sdk.ts`, `LD2ujo15iFNfrhEM`; per-prospect audit/pitch, auto-fired by the Sweeper on finalization for warm/hot leads — see tasks T057b) and **Social Activity** (`social-activity.sdk.ts`, `vwVPshHYWl4t8fzH`). (3 intakes + 9 operational including dashboard-sync + approval form + sales-action form + shared fetch-page sub-workflow + global error handler). Dashboard Sync is delivery-nudged by the Event Relay but deploys as its own workflow. Every service is an independent n8n workflow with two entry points — webhook (poke / external invocation) and Execute Workflow (testing / composition) — plus, for queue workers, an interval trigger. Standard worker loop: `claim_work_items()` → do work → `complete_* / fail / defer`. Pokes only trigger an immediate poll; caps hold because claiming is fenced. **Discovery is a queue worker too** — campaign-scoped work item, same lease/fence, so duplicate pokes can never cause duplicate provider spend.

Common rules: all LLM outputs schema-validated post-generation (failure = work-item failure); long tiers call `renew_lease()` (and `renew_provider_permit()` for long provider calls); every paid call follows gate → `authorize_paid_operation()` (atomic max-billable budget + permit) → call → settle (`actual ≤ maximum`) or release; all provider calls use retry-with-backoff; deferrals are not failures.

## Intake (×3)

| | Contract |
|---|---|
| In | Channel-specific (form fields / ICP sheet row / authenticated JSON) |
| Out | `create_campaign(canonical_request, trusted_caller_identity, trusted_trigger_source)` → `{campaign_id, creation_status: created\|existing, campaign_status: created, dashboard_url}` |
| Guarantees | Canonical validation per canonical-request.md; caller identity + trigger_source are trusted workflow-context arguments, never from the payload; idempotent on `(caller_identity, request_id)`; scheduled intake additionally claims its slot via `claim_scheduled_profile_slot()` before creating |

## Discovery (queue: `discovery`, campaign-scoped work item)

| | Contract |
|---|---|
| In | Claims the campaign-scoped `discovery` work item created by `create_campaign()` (poke = immediate poll; at-least-once pokes are harmless — `SKIP LOCKED` + fence guarantee one execution owns the item) |
| Work | Geocode → Places (depth-mapped: 20/60/grid) ∥ SerpAPI (ranks) → normalize/merge/dedup → hard filter (category, geo, exclusions, suppressions, sales-status) → volume_cap by evidence richness. Long grid sweeps call `renew_lease()` |
| Out | `commit_discovery_results(campaign_id, work_item_id, claim_token, payload)` — **fenced**, one transaction; outbox: analyzer pokes + "campaign started" milestone |
| Evidence written | `website_present`, category resolution, `discovery_observations` ranks, firmographic basics |

## Website Auditor (queue: `website`)

| | Contract |
|---|---|
| Tier 1 (deterministic) | Reachability, SSL/redirects, PSI Lighthouse lab scores, viewport, freshness (`staleness_years`), Gemini-Flash vision (`design_age_estimate`, `visual_appeal`, `design_findings`), and — **all parsed free from the already-fetched homepage (2026-07-18)** — **social presence** (`social_links`, `social_platform_count`), **marketing/tracking pixels** (`marketing_pixels`, `pixel_count`: Meta Pixel/GA4/GTM/Google Ads/TikTok Pixel/LinkedIn Insight), and **chat + booking widgets** (`chat_widget_present`, `booking_widget_present`, `web_features{chat_vendor,booking_vendor}`) → typed evidence. `booking_widget_present` is the producer for that voice_ai rule; `ad_presence` (Meta Ad Library / Google Ads Transparency) remains a Tier-2 future enhancement |
| Tier 2 (caged agent, Claude, cap 6 `fetch_page` calls) | `{design_age_estimate, seo_gaps[], conversion_blockers[], missing_capabilities[], rebuild_vs_refresh, confidence}` |
| Cage | No credentials in context; http/https only; private-IP block post-DNS; ≤3 redirects; size cap; HTML→text sanitization |

## Review Miner (queue: `reviews`)

| | Contract |
|---|---|
| Tier 1 | Apify newest-150 Google reviews (`compass~google-maps-reviews-scraper`) + Yelp (`tri_angle~yelp-review-scraper` gated on Fusion match ≥3 reviews) → typed stats: `rating`, trajectory, `owner_response_rate`, `owner_responds_to_reviews`, `yelp_rating`, `yelp_review_count`, `yelp_url`, `reputation_gap`. **NOTE (2026-07-18): no longer emits `review_volume`** — Discovery's Places `user_ratings_total` is authoritative; the scrape returned 0/null on empty/capped runs and clobbered it via latest-wins |
| Tier 2 (cheap model) | Complaint themes mapped to 4 product lines + short verbatim quotes with dates |
| Verification gate | Every quote string-matched against fetched corpus → `confirmed`/`rejected` verification events (idempotent). Corpora are ephemeral: derived stats + short excerpts persist, full text does not |

## Phone Presence (queue: `phone`, dependency-blocked)

| | Contract |
|---|---|
| Unblocks | When website + reviews work items are terminal; reruns only via `revision_impact_rules` |
| In | Sibling evidence (read-only) + Places data |
| Out | `{ai_receptionist_likelihood, phone_pain_score, evidence_refs[]}` as derived evidence with `derived_from` links (lineage prevents double-count) |
| V2 swap | Probe-caller: same contract + `call_transcript_ref`; compliance review before build |

## Social Activity (queue: `social`, warm-gated) — added 2026-07-18

| | Contract |
|---|---|
| Gate | Created `blocked` at discovery commit (or `skipped_prerequisite` when `service_config.social.enabled=false`). The **Scorer opens it** (`blocked → pending`) in `complete_scorer_work_item` when the lead is **warm/hot**; non-warm terminal analysis → `skipped_gate`. No approval branch — public data, not contact spending |
| In | Claims `social`; reads the `social_links` evidence produced by the Website Auditor |
| Work | Apify per-profile scrape of detected profiles — `apify~instagram-scraper` (followers + latest-post timestamp), `apify~facebook-pages-scraper` (followers/likes), `clockworks~tiktok-scraper` (fans + latest video). Gated to warm leads to control Apify cost |
| Out | `complete_analysis_work_item(..., cause_type='social_evidence')` → `social_followers` (object), `social_last_post_days` (object), `social_inactive_90d` (boolean, `ads_video`; TRUE when most-recent IG/TikTok post >90d or no social presence). `social_evidence → assessment` impact rule re-scores the lead |
| v2 | SerpApi Google-search profile discovery (find profiles the homepage doesn't link); Yelp/Nextdoor supplement. Similarweb was evaluated and **dropped** (needs ~5k monthly visits — no data for SMBs; see research) |

## Contact Enricher (queue: `enrichment`, gate-blocked)

| | Contract |
|---|---|
| Gate | `authorize_enrichment_operation()` before every paid tier — gate + budget + permit validated and allocated in ONE transaction (no separate revalidate call exists) |
| Pipeline | Apollo by domain (title filter from vertical policy) → on miss: caged DM-hunter (web_search + fetch_page, cap 6, explicit `not_found` rewarded) → verification dimensions (identity_matched / role_source_attested / channel_deliverable — deterministic checks; LLM assists source-matching only) → Hunter deliverability |
| Out | Contacts + role links + channels + verification rows (with `expires_at`) + `campaign_contact_findings`; suppressions checked at all 5 levels pre-storage |

## Scorer (queue: `assessment`, event-driven)

| | Contract |
|---|---|
| In | Assessment work items created/reset by evidence events via impact rules |
| Work | Recompute from full ledger state under pinned scoring config set; only latest-event-`confirmed` evidence; lineage policy governs derived evidence. **Also (2026-07-18): derives `domain_hard_to_recall` (+25 web_seo) from the business domain, and opens the warm-gated `social` work item when the lead is warm/hot.** Warm threshold = opportunity ≥45 (thresholds + opportunity formula are hardcoded in the Code node — see scoring-defaults implementation note) |
| Out | `complete_scorer_work_item()`: assessment + score_components + score_log + classification + pointer update (only when `processing_version = lead_revision`; else `is_current=false`, item → pending) + outbox |
| Critic & hot timing | `hot_candidate = true` when the candidate condition holds (opportunity ≥75 AND evidence_confidence ≥60 — contactability pending; see scoring-defaults thresholds); classification stays `warm`. When contactability also passes the Hot gate (≥60, US2 enrichment), `critic_reviews` opens (`critic_state = pending`); cross-family critic marks evidence `disputed`; deterministic verifiers re-run; recompute. Only on critic resolution (or `critic_deadline_at`, resolving as `contested`) does classification become `hot` — and only then does `lead.hot` and the first-hot Slack milestone fire. An unresolved candidate never enters a digest as hot |

## Asset Collector — **deferred to v2**

No v1 workflow ships. The `assets` schema exists (reference-only, `storage_ref` always NULL in v1 — consistent with the data model), the chain rule ships **disabled**, and `photo_asset_count` scoring evidence comes from Discovery metadata instead. The v2 collector will gather rights-labeled references (Places content never downloaded/rehosted).

## Sweeper (schedule)

`reap_expired_leases()` (items, deliveries, permits) → `requeue_retryable_work()` (failed_retryable → pending when due; threshold → dead + alert) → `requeue_stale_assessments()` → `reconcile_expired_reservations()` → **deadline enforcement** (approval/critic/reconciliation/campaign deadlines resolved per pinned policy) → fenced finalization: `begin_` → digest (reads snapshots; includes contested objections + spend summary) → snapshot sheet → `complete_campaign_finalization()`. Digest failure retries finalization only; snapshot failure = warning. Sets `quality_state`.

## Event Relay (schedule, tight + poke)

Claims `outbox_deliveries` per destination with lease + fence; delivers pokes / Slack / dashboard-sync nudges; at-least-once; consumers idempotent on `event_id`; max attempts → dead_letter + alert. No business logic.

## Dashboard Sync (delivery-nudged)

One-way Postgres → Airtable mirror (campaign summaries, hot/warm leads, statuses derived from work_items). Never read back.

## Outbox event types (v1), with `event_class` (only `state_change` and `dependency` block finalization)

| Event | Class |
|---|---|
| `campaign.created`, `discovery.committed`, `assessment.published`, `approval.granted`, `approval.rejected`, `campaign.finalizing`, `campaign.completed` | state_change |
| `evidence.added`, `chain.fired` | dependency |
| `lead.hot` (post-critic only), `budget.state_changed`, `workitem.dead` | notification |
| dashboard-sync nudges | mirror |

Consumers record receipts in `event_consumptions` (PK event_id+destination); DB-mutating consumers commit receipt + mutation in one transaction. A failed Slack or mirror delivery retries but never blocks campaign completion.

## Milestone notifications (Slack)

campaign started (lead count) · first hot lead (+ top evidence line) · campaign complete (digest link, quality_state, spend) · work item dead · budget near_limit/exhausted · reconciliation_required
