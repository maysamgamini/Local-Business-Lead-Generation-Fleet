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

**phone_probe enabled (prod, 2026-07-20)** — `service_config.phone_probe.enabled` flipped `true`
in the `leadgen` namespace (runtime UPDATE; the seed still ships it disabled). The Scorer now opens
a `phone_probe` gate on newly-warm/hot leads and the fleet worker (`BP3pMFyvJ0n0bPLX`) auto-probes
them (Twilio AMD + greeting classification). Not enabled in `leadgen_dryrun` (dry-run isn't isolated
— probing there would place real calls).

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
