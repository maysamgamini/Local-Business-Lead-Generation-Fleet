# Initial Scoring Configuration (v1 draft)

Source data for the `scoring_config` v1 config set seeded in T027. Derived from the original lead-qualification point table (industry 20 / area 10 / problem 25 / size 15 / decision-maker 15 / verified contact 15) mapped onto the four-fit + three-dimension model of design §6.6. **These are starting weights, not truth**: the golden campaign (T043) is the tuning loop; changes ship as new config-set versions, never edits.

General rules: every entry scores only latest-event-`confirmed` evidence; `missing_policy = no_points` unless stated; each fit is capped at 100 after summing; `lineage_policy = count_roots_only` everywhere except where noted.

## Feature ownership (every scored feature has exactly one contracted producer)

| feature_key | Producer |
|---|---|
| website_present, photo_asset_count, firmographics, serp_rank | Discovery |
| pagespeed_* (perf/seo/accessibility), staleness_years, mobile_friendly, website_reachable, design_findings | Website Auditor v2 Tier 1 (deterministic: PSI + HTML freshness/viewport) |
| design_age_estimate, visual_appeal | Website Auditor v2 — **Gemini Flash vision** on a screenshot |
| **social_links, social_platform_count, marketing_pixels, pixel_count, chat_widget_present, booking_widget_present, web_features** | Website Auditor v2 — **free homepage parse** (2026-07-18): social profile links; tracking/ad pixels (Meta Pixel/GA4/GTM/Google Ads/TikTok Pixel/LinkedIn Insight); chat + booking widget vendors. `booking_widget_present=false` now feeds the voice_ai rule that previously had no producer |
| **social_followers, social_last_post_days, social_inactive_90d** | **Social Activity** (`social` service, warm-gated — 2026-07-18): Apify IG/FB/TikTok scrape of the detected `social_links`. `social_inactive_90d` = most-recent IG/TikTok post >90 days, or TRUE when no social presence at all |
| seo_gaps, conversion_blockers, ad_presence | Website Auditor Tier 2 text/marketing (future enhancement) |
| review_volume, rating, review trajectory, owner_response_rate, complaint themes/quotes | Review Miner — **NOTE (2026-07-18): the Review Miner no longer emits `review_volume`**; Discovery's Places `user_ratings_total` is the authoritative count (the miner's Apify google-reviews scrape returned 0/null on empty/capped runs and was clobbering it via latest-wins). Yelp: `yelp_rating`, `yelp_review_count`, `yelp_url`, `reputation_gap` |
| phone_pain_score, ai_receptionist_likelihood, hours_gap | Phone Presence (derived; lineage-linked) |
| **domain_hard_to_recall** | **Scorer-internal derived** (2026-07-18) — from `businesses.website_domain`: TRUE when the registrable label is ≥20 alpha chars OR contains a hyphen/digit → +25 fit_web_seo (evidence_id null, like fits_in_midband_count) |
| contactability inputs (verified roles/channels) | Contact Enricher (US2 — contactability is 0 until then, which is why Hot cannot exist at the US1 checkpoint) |
| fits_in_midband_count, best/second fit, completeness | Scorer-internal derived features — computed from other scored values during assessment, no external producer |

## fit_web_seo (max 100) — REDESIGN-FOCUSED (v2)

The product is selling redesigns, so web_seo rewards **outdated / visually weak** sites. Visual age + staleness + mobile carry the weight; PSI/SEO are supporting evidence. Producer: Website Auditor v2 (deterministic Tier-1 + Gemini-Flash vision).

| feature_key | transform | params | max points | source |
|---|---|---|---|---|
| website_present = false | boolean_points | — | **85** (no site = near-max; other website features n/a) | Discovery |
| **visual_appeal** | step | poor → 25 · average → 12 · good → 0 | **25** | Gemini vision |
| **staleness_years** | linear | 0–6 yrs → 0–25 | **25** | Last-Modified + copyright year |
| **mobile_friendly = false** | boolean_points | no viewport → 20 | **20** | HTML extract |
| pagespeed_performance | inverse_linear | in 0–100 | 25 | PSI |
| pagespeed_seo | inverse_linear | in 0–100 | 15 | PSI |
| **pagespeed_accessibility** | inverse_linear | in 0–100 | 10 | PSI |
| design_age_estimate | step | dated → 15 · aging → 8 · modern → 0 | 15 | Gemini vision |
| serp_rank (best for own category+geo) | step | >20 → 20 · 11–20 → 12 · 4–10 → 5 · ≤3 → 0 | 20 | SerpApi |
| seo_gaps[] count | linear | 3 pts each | 15 | (Tier-2 text, future) |
| conversion_blockers[] count | linear | 5 pts each | 10 | (Tier-2 text, future) |
| **domain_hard_to_recall** | boolean_points | — | **25** | Scorer-internal (registrable label ≥20 alpha OR has hyphen/digit) — unmemorable domain = rebrand/redesign angle |

Each fit clamps at 100, so a dated + stale + mobile-broken site maxes web_seo — exactly the "call them today" redesign prospect. `design_findings` (screenshot URL, redesign_rationale, brand_colors, issues) is written as informational evidence (no config row → 0 points) to feed the sales report and the redesign step.

**Vision model**: Gemini Flash (`gemini-flash-latest`; `gemini-2.0/2.5-flash` were retired on fresh projects) — cheapest production multimodal, image input included, ~fraction-of-a-cent per lead; already credentialed. Requires `thinkingConfig.thinkingBudget:0` (it is a thinking model). Claude reserved for the hot-lead critic (cross-family). See [research R-11].

## fit_voice_ai (max 100)

| feature_key | transform | params | max points |
|---|---|---|---|
| phone_pain_score (derived; count_roots_only vs. its review roots) | linear | in 0–1 | 40 |
| phone/scheduling complaint share of confirmed themes | linear | in 0–1 | 25 |
| booking_widget_present = false | boolean_points | — | 15 | *(producer wired 2026-07-18: Website Auditor homepage widget detection — Calendly/Acuity/Square/Booksy/Vagaro/Zocdoc/Housecall Pro/ServiceTitan/… + strong phrases)* |
| hours_gap_vs_category_norm | linear | in 0–1 | 10 |
| owner_response_rate < 0.2 | boolean_points | — | 10 |

## fit_ads_video (max 100)

| feature_key | transform | params | max points |
|---|---|---|---|
| **ad_active = false** | boolean_points | verified Meta/Google/Yelp checks found no active campaign | **25** |
| **social_platform_count < 2** | boolean_points | fewer than two owned social links detected on the homepage | **20** |
| review_volume (demand proof) | log | 25→0pts floor, 100→15, 400+→25 | 25 |
| social_inactive_90d | boolean_points | — | 25 | *(producer wired 2026-07-18: Social Activity service — Apify IG/TikTok last-post recency, or TRUE when no social presence)* |
| photo_asset_count ≥ 10 | boolean_points | — | 10 |
| rating ≥ 4.0 (good product, weak marketing) | boolean_points | — | 10 |

`ad_active=false` means no active Meta, Google, or Yelp campaign was found by the
sources checked; it is not universal proof that the business runs no advertising.
Nextdoor has no public ad-transparency source, so its homepage pixel is a
detected/likely signal only and absence is reported as “not detected.” The social
footprint rule is deliberately available before the paid activity scrape so Social
Media Management is represented in the initial evaluation. Each fit remains capped
at 100.

## fit_consulting (max 100)

| feature_key | transform | params | max points |
|---|---|---|---|
| fits_in_midband_count ≥ 2 (fits in 40–70) | boolean_points | breadth-without-dominance signal | 40 |
| tech_fragmentation ≥ 3 disparate tools | boolean_points | — | 30 |
| multi_location_parent = true | boolean_points | — | 15 |
| owner_responds_to_reviews (engaged operator) | boolean_points | — | 15 |

## opportunity_score (0–100)

`0.55 × best_fit + 0.15 × second_best_fit + firmographics (0–30)`

| firmographic | points |
|---|---|
| category exact match to requested business_type | 15 |
| inside requested geo (not fuzzy-boundary) | 5 |
| size proxy in ICP band (review_volume 25–500 OR 2–10 locations) | 10 |

## contactability_score (0–100) — verified + unexpired only

| component | points |
|---|---|
| role_source_attested decision-maker | 40 |
| channel_deliverable email | 40 |
| direct phone | 10 |
| LinkedIn profile matched | 10 |

## evidence_confidence (0–100)

| component | points |
|---|---|
| completeness (share of applicable analyzers done) | 40 |
| confirmed evidence volume | linear, cap at 20 items | 30 |
| recency (≥60% of evidence <12 months old) | 20 |
| source diversity (≥3 distinct providers) | 10 |

## Thresholds (classification & gates — pinned in same config set)

| Threshold | v1 value |
|---|---|
| **hot_candidate** | opportunity ≥75 AND evidence_confidence ≥60 — the US1-computable dimensions; contactability pending. Set by the Scorer whenever this condition holds and the lead is not yet Hot |
| Hot | opportunity ≥75 AND contactability ≥60 AND confidence ≥60 — evaluated once contactability exists (US2); promotion only after critic resolution |
| Warm / Cold / Disqualified | **opportunity ≥40 / 30–39 / <30** (warm threshold updated to ≥40 on 2026-07-21 — opportunity ≥40 is warm) |
| Enrichment gate | opportunity ≥60 |
| Quality floor (campaign degraded) | >20% dead work items OR mean confidence <40 |

> **Implementation note (2026-07-21):** the warm/cold/disqualified thresholds AND the opportunity formula (`0.55×best + 0.15×second + firmographics`) are currently **hardcoded in the Scorer's "Compute Scores" Code node** (deployed workflow `r0K3xkLN2XtUceTF`), NOT read from these `scoring_config` rows. The `scoring_config` threshold rows document intent and are kept in sync (`activate-v1.sql` `warm_opportunity` = 40); a future refactor should have the Scorer read them. `domain_hard_to_recall` (+25 web_seo) is likewise computed in-Scorer.

**Traceability note**: the original table's "clear business problem = 25" became the problem-evidence weights inside each fit; "industry 20 + area 10 + size 15" became the 30-point firmographic block (rebalanced 15/5/10 since discovery hard-filters category/geo mismatches before scoring); "DM 15 + contact 15" became the separate contactability dimension per the round-3 correction that reachability must not inflate opportunity.
