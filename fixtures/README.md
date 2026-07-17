# Fixtures

Provider response fixtures for dry-run campaigns and contract tests. Dry-run mode (`dry_run: true` → `leadgen_dryrun` namespace) routes every paid provider call to these files; LLM calls run for real.

## Supported fixture request_ids

| request_id | Scenario |
|---|---|
| `fixture-medspa-78613` | Primary golden vertical: 10 MedSpas near 78613 (Cedar Park, TX). Full coverage across all providers |
| `fixture-empty-99999` | Zero-discovery campaign → must complete with `completion_reason = no_results` |
| `fixture-lowbudget-78613` | Same vertical, `budget.amount: 2` → exercises `skipped_budget` labeling |

## Provider fixtures used

| Directory | Provider | Contents |
|---|---|---|
| `places/` | Google Places Text Search + Details | 10 businesses, incl. 1 with no website (web-fit signal), 2 sharing a domain (relationship typing), photo metadata for `photo_asset_count` |
| `serpapi/` | SerpAPI Google Maps engine | Same 10 with local-pack ranks 1–20+, exact place_id join keys |
| `apify-reviews/` | Google reviews actor | Newest-200-shaped payloads; per-business review sets incl. phone-complaint clusters |
| `apollo/` | Org + people search | Hits for 7 businesses; `dm-miss.json` forces the DM-hunter fallback path for 3 |
| `hunter/` | Email finder + verifier | Deliverable, risky, and undeliverable outcomes |
| `psi/` | PageSpeed Insights | Lab scores spanning 25–95 performance |
| `critics/` | Critic eval inputs | `hot-candidate-objections.json` seeded objection cases |

## Planted failure cases (the evals — these MUST be caught)

| Plant | Location | Expected outcome |
|---|---|---|
| Fabricated review quote (text absent from corpus) | `apify-reviews/medspa-radiance.json` → theme-extraction output trap | Quote-checker emits `rejected`; zero score contribution (V2a) |
| Wrong-business contact ("owner" whose source URL describes a different company) | `apollo/wrong-contact-plant.json` | Role verification fails; `contact_verified` demoted (V2b) |
| Suppressed email (`blocked@fixture-medspa.example` on email-level suppression) | `hunter/suppressed-plant.json` + seed suppression row | Never stored outreach-usable (SC-006, T050) |

## Expected synthetic charges

Dry-run fixture calls settle synthetic amounts so budget math is exercised: Places $0.017/call, SerpAPI $0.01, Apify review batch $0.25, Apollo lookup $0.40, Hunter verify $0.10, LLM per pinned unit-cost table (real token spend). `fixture-lowbudget-78613` exhausts its $2 cap mid-analysis by design.

## Expected evidence & scores

`golden/expectations.json` is the authoritative expected-output file (fit tolerance bands ±10, opportunity ranking order, invariant facts). Fixtures and expectations are versioned together — changing a fixture REQUIRES updating expectations in the same commit.
