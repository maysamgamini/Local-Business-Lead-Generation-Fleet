# Workflows

Source of truth for fleet workflows is **n8n Workflow SDK code** (`*.sdk.ts`), deployed
via the n8n MCP server (`create_workflow_from_code` / `update_workflow`). The deployed
instance IDs are recorded below. `import-workflows.ps1` remains for JSON-export
round-trips if ever needed.

| Workflow | File | Instance ID |
|---|---|---|
| Leadgen — Event Relay | event-relay.sdk.ts | D2O53VaniWo0i6T7 |
| Leadgen — Error Handler | error-handler.sdk.ts | YebUjdNTwGqPy4M9 |
| Leadgen — Intake Form | intake-form.sdk.ts | SzTS1b6tJHnQmvY3 |
| Leadgen — Discovery | discovery.sdk.ts | bGlPRpKMRxnnxPm3 |
| Leadgen — Scorer | scorer.sdk.ts | r0K3xkLN2XtUceTF |
| Leadgen — Website Auditor v2 | website-auditor.sdk.ts | KKjPDVVMIHl6n5MD |
| Leadgen — Review Miner | review-miner.sdk.ts | trDsKi1XVraj3b1i |
| Leadgen — Phone Presence | phone-presence.sdk.ts | S07IwoUAxOANCHXR |
| Leadgen — Report Generator | report-generator.sdk.ts | LD2ujo15iFNfrhEM |
| Leadgen — Social Activity | social-activity.sdk.ts | vwVPshHYWl4t8fzH |
| ~~Website Auditor v1~~ (retired) | — | ecfwEfnWOCn9hPN4 (unpublished) |
| Leadgen — Sweeper | sweeper.sdk.ts | f5xBdfjMchJgJOzq |
| Leadgen — API Intake | intake-webhook.sdk.ts | stTulzWEWMCS9qPS |
| Leadgen — Phone Probe (fleet) | phone-probe-service.sdk.ts | BP3pMFyvJ0n0bPLX |
| Leadgen — Ops Console | ops-console.sdk.ts | k3EJWaGRnGg8tl3p |
| Leadgen — Scheduler | scheduler.sdk.ts | zSW7lriZbXptYpz1 |
| Leadgen — Ad Verification | ads-verification.sdk.ts | Ts7fpKJQacm8uhkX |
| Leadgen — Competitor Gap-Finder | competitors-gap.sdk.ts | gYE23EUlVMC9QtGp |

**Campaign-volume and stuck-analysis repair (2026-07-21)** — Discovery no longer
treats Google Places' 20-result page limit as the campaign limit. It now requests
enough SerpApi Maps pages to cover `volume_cap` (20/page, max 15 pages for the
supported cap of 300), merges SerpApi candidates into the Places set, deduplicates,
ranks, and commits up to the requested cap. Review Miner temporarily bypasses its
Yelp Code node, and Social Activity runs in a safe degraded mode, because synchronous
Apify actors exceeded n8n's 60-second JavaScript task limit. The Sweeper now calls
`reconcile_blocked_dependencies()` so a review item that becomes `dead` still
unblocks dependent `phone` work instead of leaving the campaign in `analyzing`.

**Dynamic report-headline repair (2026-07-21)** — `gemini-flash-latest` began
resolving to Gemini 3.6 Flash. The old `thinkingConfig:{thinkingBudget:0}` request
became invalid, so every Compose Pitch call returned HTTP 400 and the HTML builder
used its fixed fallback headline. Compose Pitch now sends a compatible request and
allows 5,000 output tokens because Gemini 3.6 reasoning tokens count against the
response budget. Personalized headlines, ledes, sections, and recommendations are
generated again.

**Competitor-selection correction (2026-07-21)** — the gap finder now ranks the
businesses already discovered in the same campaign before using a new Places
search. Candidates still require at least 15 reviews and are ordered by
`rating × ln(1 + reviews)`. Places is fallback-only for campaigns without peers,
and the common `HVAX` typo is normalized to `HVAC contractor`. Previously,
`locationBias` was not a hard boundary, so a typo could return and select an
unrelated company such as HVAX Technologies Ltd.

**Free homepage-signal detection (2026-07-18)** — the Website Auditor now parses the
already-fetched homepage (no extra API) for three signal classes, all written as typed
evidence: **social presence** (`social_links`, `social_platform_count`), **marketing/tracking
pixels** (`marketing_pixels`, `pixel_count` — Meta Pixel / GA4 / GTM / Google Ads / TikTok
Pixel / LinkedIn Insight), and **chat + booking widgets** (`chat_widget_present`,
`booking_widget_present`, `web_features{chat_vendor,booking_vendor}`). `booking_widget_present`
fills the pre-existing `voice_ai` scoring rule (`when:false → +15`).

**Social Activity** (`social` service, warm-gated) — the Scorer opens a `social` work item
when a lead turns warm/hot; the worker reads `social_links` and scrapes Apify
`apify/instagram-scraper` + `apify/facebook-pages-scraper` + `clockworks/tiktok-scraper` for
`social_followers`, `social_last_post_days`, and `social_inactive_90d` (`ads_video`,
`when:true → +25`) → re-score. Ships behind `service_config.social.enabled` (flip to true once
Apify credit is available). SerpApi profile-discovery (find profiles the homepage doesn't link)
is a documented v2 enhancement.

**Ops Console** (`ops-console.sdk.ts`, 2026-07-20) — internal operator dashboard served by n8n
over the **prod** ledger, read-only (SELECT on existing tables — no DML, no new DB). A
self-contained SPA (`GET /webhook/leadgen-console`, prompts once for `x-leadgen-key`, stored in
the browser) backed by two gated JSON endpoints: `GET /webhook/leadgen-console-data` (fleet KPIs,
campaigns with per-class lead counts + settled spend computed from **direct** `campaign_leads`/
`budget_transactions` subqueries — NOT `campaign_progress`, whose leads/hot/spent are fan-out
inflated, and `work_items` state matrix + `stuck_work_overview` count) and
`GET /webhook/leadgen-console-leads?campaign=<uuid>` (opportunity-ranked leads: 4 fit scores,
opp/contact/confidence, latest-per-feature evidence signals, and `report_url`). Both data endpoints
require the `x-leadgen-key` header (same secret as the API Intake; redacted `<<INTAKE_API_KEY>>` in
the archive, set live via `update_workflow`). "+ New campaign" reuses the API Intake webhook.
Requires `db/migrations/150_lead_reports_grant.sql` (grants SELECT on `lead_reports`, which
post-dated `100_privileges.sql`). Visual: Fraunces/IBM Plex, heat-as-semantic (hot/warm/cold/dq)
separate from the beacon-azure accent; theme-aware.

**Active-ad detection — Tier 1 LIKELY (2026-07-20)** — the Website Auditor's `detectPixels` now
flags ad-intent pixels across Meta (`fbq`/`fbevents`), Google Ads (`AW-`/googleadservices/
doubleclick), Yelp CAPI (`ndclid`/yelp-capi), Nextdoor (`js.nextdoor.com`), TikTok, LinkedIn, and
X (`static.ads-twitter.com`) → `marketing_pixels` evidence (analytics like GA4/GTM stay analytics).
The **Report** renders an "Advertising" section from `marketing_pixels` — detected platforms
(LIKELY) or a "not advertising yet → consultation" pitch when none are found; the **Ops Console**
lead board shows an `ads: <platforms>` / `no ads` chip. Report/console nodes deployed via the n8n
**public REST API** (scripted PUT) — the console page + the AWS-keyed report node had outgrown the
inline MCP deploy. **Tier 2 CONFIRMED (2026-07-20)** — new warm-gated **`ads`** service (`ads-verification.sdk.ts`,
`Ts7fpKJQacm8uhkX`): migration 180 (+`ads` to work_items CHECK), `service_config.ads` enabled,
created `blocked` at discovery + opened by the Scorer on warm/hot (complete_scorer ads gate),
`complete_analysis` allowlist +`ads`, 30-day cache reuse. Worker: Meta Ad Library API (active
creatives by name; token inline, redacted) + SerpApi `google_ads_transparency_center` (by domain) +
SerpApi `yelp` (`find_desc`/`find_loc`) → `ad_status` {tier CONFIRMED, summary{meta,google,yelp},
live_ad_urls} + `ad_active` evidence → re-score. **Matching (ads-v2.1):** a platform is CONFIRMED only
when an ad's page/title contains EVERY significant token of the business name (len≥3, minus stopwords) —
Meta/Yelp/Google results surface competitors bidding on the same terms, so first-word matching (e.g. a
city name) produced false CONFIRMEDs that would wrongly disqualify a good lead; each `live_ad_url` is
pushed only when its own platform is confirmed (Google is domain-scoped so needs no name match).
Idempotency keys are version-pinned (`:ads-v2.1`) so a matcher bump appends a corrective observation
(latest-wins). Verified E2E (Austin Med Spa: 2 Yelp ads returned were both competitors — "BestLaser",
"Rejuvenate Austin" — correctly rejected → all NONE, `overall false`, a valid consultation lead).
**Nextdoor is LIKELY-only (by design):** unlike Meta/Google/Yelp, Nextdoor has **no public ad
transparency library** — its ads are shown in-feed to logged-in neighbors and can't be enumerated
from outside, and Apify's Nextdoor actors return business-directory data (name/address/ratings/
reviews/category), not ad or Local-Deals data. So Nextdoor advertising stays a LIKELY signal via the
free `nextdoor_pixel` (js.nextdoor.com / nextdoorpixel / ndpixel) already detected by the Website
Auditor. A CONFIRMED Nextdoor arm was evaluated and dropped: the only defensible source (active Local
Deals) needs an unproven, paid Apify actor with low SMB yield, and a shaky proxy would risk a false
CONFIRMED that wrongly disqualifies a good lead.
The **report Advertising section + console `ads` chip prefer `ad_status`** (CONFIRMED per platform +
clickable live-ad links) when the worker has verified, else fall back to LIKELY (pixels), else the
"not advertising → consultation" pitch.
Deploys use the n8n REST API (patch scripts) — Meta token patched server-side, never in a tool call.

**Ops Console actions (2026-07-20)** — three operator actions layered on the console (all through
`SECURITY DEFINER` fns, `x-leadgen-key`-gated): **Run now** (per-campaign, clones config → intake
API → fresh campaign); **Re-analyze** (per-lead `POST /leadgen-console-action` {action:reanalyze} →
`requeue_lead_analysis` reopens website/reviews/phone/social + assessment, bypassing the 30-day
cache, excluding phone_probe); **Target mode** (New-campaign "Analyze one business" → `create_campaign`
`target` + Discovery Places text search). **Scheduler** (`scheduler.sdk.ts`, hourly + poke) calls
`fire_due_schedules()` → launches due `campaign_schedules` rows via `create_campaign(schedule)`;
console "Schedule…" (`schedule_campaign`) + "Schedules" drawer (`cancel_campaign_schedule`). Cadences
once/weekly/monthly; prod-only. Migrations 150/160/170; functions reanalyze.sql/schedules.sql +
create_campaign target mode.

**phone_probe enabled (prod, 2026-07-20)** — `service_config.phone_probe.enabled` flipped `true`
in the `leadgen` namespace (runtime UPDATE; the seed still ships it disabled). The Scorer now opens
a `phone_probe` gate on newly-warm/hot leads and the fleet worker (`BP3pMFyvJ0n0bPLX`) auto-probes
them (Twilio AMD + greeting classification). Not enabled in `leadgen_dryrun` (dry-run isn't isolated
— probing there would place real calls).

**Competitor Gap-Finder (`competitors` service, warm-gated, 2026-07-21)** — new fleet worker
(`competitors-gap.sdk.ts`, `gYE23EUlVMC9QtGp`) that turns the report's abstract "your competitors
are capturing customers" line into a concrete, named side-by-side. Migration `190_competitors_service.sql`
(+`competitors` to the work_items CHECK), `service_config.competitors` enabled, wired exactly like `ads`:
created `blocked` at discovery (`commit_discovery_results` service list + 30-day `_reuse_fresh_evidence`),
opened `blocked→pending` by the Scorer on warm/hot (`complete_scorer_work_item` competitors gate),
`complete_analysis` allowlist +`competitors`. Worker: Get Target (category from `campaigns.business_type`
+ latest `rating`/`review_volume` evidence) → **Google Places Text Search** (`places:searchText`,
`locationBias` circle around the target, "Header Auth account" cred) → **Rank** (exclude the target by
place_id/all-token name, require ≥15 reviews, score = `rating × ln(1+reviews)`, pick the single best +
2 runners-up) → deep-dive the BEST rival's live ads (Meta Ad Library + SerpApi Google/Yelp, **reusing the
hardened all-token matcher** so a named rival is only called "advertising" when CONFIRMED) → `competitor_set`
evidence `{target{rating,reviews}, best{name,rating,reviews,website,ads{summary,confirmed,live_ad_urls}},
others[]}` → `complete_analysis` (cause `competitors_evidence`) → re-score. Bounded cost (warm leads only,
one deep-dived rival). The **Report** renders a "How you stack up" section (Reviews / Rating / Running ads
side-by-side) with a pitch that adapts to the widest sellable gap — competitor ads if the prospect isn't
advertising, else review-volume, else market-leader framing. Verified E2E (Austin Med Spa 204 reviews vs.
Skin Envy Austin 1,171 — ~6× review-volume gap, both ads NONE). Report competitor section deployed via the
n8n REST API patch (like the Advertising section); `report-generator.sdk.ts` is now synced with the deployed
competitor-enabled report behavior. NOTE: the Places cred is the n8n credential named "Header Auth account" (id `p6TPEFGKhcDgCCwv`), not
"Google Places API"; HTTP-node creds + the Meta token are patched server-side after `create_workflow_from_code`.

Credential names workflows expect (create in n8n, values from /home/ubuntu/n8n/leadgen-db.env):
- `Postgres account` (default name; role `leadgen_relay`) — host `postgres`, port 5432, db `leadgen_db`. **v1 role consolidation**: `leadgen_relay` holds the full WORKER function surface (db/functions/zz_worker_consolidation.sql), so ALL worker workflows run under this one credential. Preserved boundaries: no direct DML; human-actions (approval/sales-status/disposition/suppression/cancel) stay on `leadgen_human`; config-admin isolated; dashboard read-only. To restore the per-role split later, create per-role credentials and reassign. All role passwords: `ssh ... "cat /home/ubuntu/n8n/leadgen-db.env"`.
- `Google Places API` — **HTTP Header Auth** credential: Name = `X-Goog-Api-Key`, Value = your Google Cloud API key with Places API (New) enabled. **REQUIRED for live Discovery.**
- `SerpApi account` — SerpApi credential (already present in n8n).
- **AWS S3 bucket** (Report Generator) — reports upload to the Lightsail bucket `n8n-leadgen-reports` (us-east-1) via AWS SigV4 signed directly in the "Build & Upload Report" Code node (`require('crypto')` + `this.helpers.httpRequest`). The access key/secret live inline in that node (n8n DB), redacted to `<<AWS_KEY>>`/`<<AWS_SECRET>>` in git — **never commit them**. Bucket permission = "individual objects can be made public"; each report is uploaded `x-amz-acl:public-read` at an unguessable key (secret-link delivery). No n8n AWS credential is needed.
- **Yelp Fusion API key** (Review Miner v2 Yelp arm) — Bearer token used in the "Yelp Enrich" Code node for `/businesses/matches` + `/businesses/{id}`; inline in the node, redacted `<<YELP_KEY>>` in git, **never commit**. Base plan gives rating/count/url only (reviews endpoint is NOT_FOUND on Base); Yelp review text comes from the Apify `tri_angle~yelp-review-scraper`.
- **Apify + Gemini tokens** (Review Miner + Social Activity) — placed directly in the request URLs / Code nodes, same pattern as PSI. Apify actors in use: `compass~google-maps-reviews-scraper` + `tri_angle~yelp-review-scraper` (Review Miner), and `apify~instagram-scraper` + `apify~facebook-pages-scraper` + `clockworks~tiktok-scraper` (Social Activity). Redacted to `<<APIFY_TOKEN>>` / `<<GEMINI_KEY>>` in the `.sdk.ts` archives; use real values when validating/creating (the `<<...>>` tokens break the SDK parser). NOTE: Apify enforces a per-account monthly USD cap — a free-tier `$5/mo` cap returns `403 platform-feature-disabled "Monthly usage hard limit exceeded"` and blocks ALL actors; raise the plan/limit before enabling `social`.
- `Google PSI API` — **HTTP Query Auth** credential: Name = `key`, Value = the PageSpeed Insights key (`AIzaSy...zmpw`, restricted to pagespeedonline on n8n-hiwebenterprise). Required for the Website Auditor.
- (later: analyzer / scorer / enricher / sweeper role creds + Apify / Hunter / Apollo / PSI / Anthropic / Gemini provider creds)

## Activation checklist (per workflow, after credentials assigned)
Event Relay ✓ active · Intake Form (activate to accept submissions) · Discovery (needs Google Places API cred, then activate) · Error Handler (set as each workflow's Error Workflow in Settings).
