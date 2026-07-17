# Initial Scoring Configuration (v1 draft)

Source data for the `scoring_config` v1 config set seeded in T027. Derived from the original lead-qualification point table (industry 20 / area 10 / problem 25 / size 15 / decision-maker 15 / verified contact 15) mapped onto the four-fit + three-dimension model of design §6.6. **These are starting weights, not truth**: the golden campaign (T043) is the tuning loop; changes ship as new config-set versions, never edits.

General rules: every entry scores only latest-event-`confirmed` evidence; `missing_policy = no_points` unless stated; each fit is capped at 100 after summing; `lineage_policy = count_roots_only` everywhere except where noted.

## Feature ownership (every scored feature has exactly one contracted producer)

| feature_key | Producer |
|---|---|
| website_present, photo_asset_count, firmographics, serp_rank | Discovery |
| pagespeed_*, design_age_estimate, seo_gaps, conversion_blockers, booking_widget_present, tech fingerprints, **ad_presence**, **social_inactive_90d** | Website Auditor (Tier 1 for deterministic incl. marketing presence; Tier 2 for agent findings) |
| review_volume, rating, review trajectory, owner_response_rate, complaint themes/quotes | Review Miner |
| phone_pain_score, ai_receptionist_likelihood, hours_gap | Phone Presence (derived; lineage-linked) |
| contactability inputs (verified roles/channels) | Contact Enricher (US2 — contactability is 0 until then, which is why Hot cannot exist at the US1 checkpoint) |
| fits_in_midband_count, best/second fit, completeness | Scorer-internal derived features — computed from other scored values during assessment, no external producer |

## fit_web_seo (max 100)

| feature_key | transform | params | max points |
|---|---|---|---|
| website_present = false | boolean_points | — | **85** (near-max signal; remaining website features then n/a) |
| pagespeed_performance | inverse_linear | in 0–100 | 25 |
| pagespeed_seo | inverse_linear | in 0–100 | 15 |
| serp_rank (best observed for own category+geo) | step | rank >20 → 20 · 11–20 → 12 · 4–10 → 5 · ≤3 → 0 | 20 |
| design_age_estimate (agent) | step | dated/legacy → 15 · aging → 8 · modern → 0 | 15 |
| seo_gaps[] count | linear | 3 pts each | 15 |
| conversion_blockers[] count | linear | 5 pts each | 10 |

## fit_voice_ai (max 100)

| feature_key | transform | params | max points |
|---|---|---|---|
| phone_pain_score (derived; count_roots_only vs. its review roots) | linear | in 0–1 | 40 |
| phone/scheduling complaint share of confirmed themes | linear | in 0–1 | 25 |
| booking_widget_present = false | boolean_points | — | 15 |
| hours_gap_vs_category_norm | linear | in 0–1 | 10 |
| owner_response_rate < 0.2 | boolean_points | — | 10 |

## fit_ads_video (max 100)

| feature_key | transform | params | max points |
|---|---|---|---|
| ad_presence = none (Meta/Google checks) | boolean_points | — | 30 |
| review_volume (demand proof) | log | 25→0pts floor, 100→15, 400+→25 | 25 |
| social_inactive_90d | boolean_points | — | 25 |
| photo_asset_count ≥ 10 | boolean_points | — | 10 |
| rating ≥ 4.0 (good product, weak marketing) | boolean_points | — | 10 |

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
| Warm / Cold / Disqualified | opportunity ≥60 / ≥40 / <40 |
| Enrichment gate | opportunity ≥60 |
| Quality floor (campaign degraded) | >20% dead work items OR mean confidence <40 |

**Traceability note**: the original table's "clear business problem = 25" became the problem-evidence weights inside each fit; "industry 20 + area 10 + size 15" became the 30-point firmographic block (rebalanced 15/5/10 since discovery hard-filters category/geo mismatches before scoring); "DM 15 + contact 15" became the separate contactability dimension per the round-3 correction that reachability must not inflate opportunity.
