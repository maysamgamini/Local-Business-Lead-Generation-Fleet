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

Credential names workflows expect (create in n8n, values from /home/ubuntu/n8n/leadgen-db.env):
- `Postgres account` (user kept default name; the relay/edge credential) — host `postgres`, port 5432, db `leadgen_db`, user `leadgen_relay`
- (US1 will add: analyzer / scorer / enricher / sweeper role credentials + provider creds)
