# Provider Behavior Verification (T007)

Verified 2026-07-16, before implementing provider workflows (T033/T035). Re-verify at major provider announcements or when fixtures drift from live shapes.

## Google Places — Text Search pagination

**Verified**: Text Search (New) returns **max 60 results total**, paginated at **≤20 per page** via `nextPageToken`; `pageSize` caps at 20; all parameters except `pageToken`/`pageSize` must match across page requests; Google explicitly notes the 60 cap is "subject to change."

**Design impact**: matches spec/design assumptions exactly (`quick`=20, `standard`=60, `deep`=grid over sub-circles). Discovery (T033) must hold query parameters constant across page-token calls. No contract change.

Sources: [Text Search (New) — Places API](https://developers.google.com/maps/documentation/places/web-service/text-search), [places.searchText reference](https://developers.google.com/maps/documentation/places/web-service/reference/rest/v1/places/searchText)

## PageSpeed Insights — CrUX field data

**Verified**: Google is discontinuing CrUX real-user field data (`loadingExperience`) in the PSI API; the CrUX API / CrUX History API are the supported field-data paths. Lab (Lighthouse) data in PSI is unaffected.

**Design impact**: matches design — Website Auditor Tier 1 (T035) consumes **lab scores only** (`lighthouseResult`), never `loadingExperience`. If field data is ever wanted for scoring, that's a new evidence feature via the CrUX API with its own scoring-config entries — not a change to existing ones.

Sources: [PSI API Get Started](https://developers.google.com/speed/docs/insights/v5/get-started), [PSI release notes](https://developers.google.com/speed/docs/insights/release_notes), [Core Web Vitals with PSI + CrUX APIs](https://developers.google.com/codelabs/chrome-web-vitals-psi-crux)

## Fixture implications

- `fixtures/places/`: Text Search (New) response shape — `places[]` with `nextPageToken` on pages 1–2; 20-per-page structure.
- `fixtures/psi/`: `lighthouseResult.categories.{performance,seo,accessibility,best-practices}.score` only; no `loadingExperience` object (mirrors post-deprecation responses).
