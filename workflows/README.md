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
| ~~Website Auditor v1~~ (retired) | — | ecfwEfnWOCn9hPN4 (unpublished) |
| Leadgen — Sweeper | sweeper.sdk.ts | f5xBdfjMchJgJOzq |

Credential names workflows expect (create in n8n, values from /home/ubuntu/n8n/leadgen-db.env):
- `Postgres account` (default name; role `leadgen_relay`) — host `postgres`, port 5432, db `leadgen_db`. **v1 role consolidation**: `leadgen_relay` holds the full WORKER function surface (db/functions/zz_worker_consolidation.sql), so ALL worker workflows run under this one credential. Preserved boundaries: no direct DML; human-actions (approval/sales-status/disposition/suppression/cancel) stay on `leadgen_human`; config-admin isolated; dashboard read-only. To restore the per-role split later, create per-role credentials and reassign. All role passwords: `ssh ... "cat /home/ubuntu/n8n/leadgen-db.env"`.
- `Google Places API` — **HTTP Header Auth** credential: Name = `X-Goog-Api-Key`, Value = your Google Cloud API key with Places API (New) enabled. **REQUIRED for live Discovery.**
- `SerpApi account` — SerpApi credential (already present in n8n).
- **Apify + Gemini tokens** (Review Miner) — placed directly in the request URLs (`api.apify.com/v2/acts/compass~google-maps-reviews-scraper/run-sync-get-dataset-items?token=...` and the Gemini `generateContent?key=...`), same pattern as PSI. Redacted to `<<APIFY_TOKEN>>` / `<<GEMINI_KEY>>` in `review-miner.sdk.ts`; use real values when validating/creating (the `<<...>>` tokens break the SDK parser).
- `Google PSI API` — **HTTP Query Auth** credential: Name = `key`, Value = the PageSpeed Insights key (`AIzaSy...zmpw`, restricted to pagespeedonline on n8n-hiwebenterprise). Required for the Website Auditor.
- (later: analyzer / scorer / enricher / sweeper role creds + Apify / Hunter / Apollo / PSI / Anthropic / Gemini provider creds)

## Activation checklist (per workflow, after credentials assigned)
Event Relay ✓ active · Intake Form (activate to accept submissions) · Discovery (needs Google Places API cred, then activate) · Error Handler (set as each workflow's Error Workflow in Settings).
