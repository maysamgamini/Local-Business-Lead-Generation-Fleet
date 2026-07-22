# AGENTS.md — System Context & Guidelines

System context, architecture specifications, codebase navigation, development commands, and agent guardrails for the **Local Business Lead Generation Fleet**.

---

## Project Overview

The **Local Business Lead Generation Fleet** is an agentic lead-research system built for a digital-marketing and AI-voice-assistant agency. Given a business type and geography, the system discovers local businesses, evaluates them across four core product offerings (Web/SEO, AI Voice Assistants, Ads/AI Video, and Consulting), verifies decision-maker contact details under strict budget caps, and delivers scored, evidence-backed leads.

### Core Architectural Principles
- **n8n owns behavior, Postgres owns correctness**: All state machine transitions, budget calculations, and queue operations are strictly enforced by PostgreSQL.
- **SECURITY DEFINER PL/pgSQL functions**: Every state mutation occurs via a dedicated PL/pgSQL function called from a *single* n8n Postgres node. Direct DML (`INSERT`, `UPDATE`, `DELETE`) on protected tables is prohibited.
- **Atomic Execution**: n8n Postgres nodes autocommit each query. Multi-node write sequences are never used for multi-table mutations.
- **Fenced Pull Queue**: Work items in `work_items` are claimed via `claim_work_items(service, worker_id)` using a `claim_token` and `lease_expires_at`. Queue completion enforces `state = 'running' AND claim_token = ? AND lease_expires_at > now()`.
- **Immutable Evidence Ledger**: The `evidence_items` table is append-only per `(business_id, campaign_id, feature_key)`. Evidence is never updated or deleted; repairs are made by appending corrective observations via `leadgen._insert_evidence`.
- **Dual Namespace Isolation**: Production (`leadgen`) and Dry-Run (`leadgen_dryrun`) namespaces operate side-by-side with identical function signatures and isolated search paths.

---

## Tech Stack & Key Libraries

- **Database**: PostgreSQL 16 (`leadgen_db`) hosted in Docker (`n8n-postgres-1`) on AWS Lightsail. PL/pgSQL transactional logic.
- **Orchestration**: Self-hosted n8n (Queue mode with main process, worker nodes, and Redis) hosted at `https://n8n.hiwebenterprise.com`.
- **Workflow Definitions**: n8n Workflow SDK TypeScript files (`workflows/*.sdk.ts`).
- **Scripting & Tooling**: PowerShell (`.ps1`), Bash (`.sh`), TypeScript (`ts-node`), Python 3 (`python`).
- **External Providers & APIs**:
  - **Places & Discovery**: Google Places API (Text Search, Place Details), SerpApi (Google Maps, Bing Search Ads).
  - **Enrichment & Social**: Apify (`instagram-scraper`, `facebook-pages-scraper`, `tiktok-scraper`), Apollo, Hunter.
  - **Performance & Audits**: PageSpeed Insights (PSI), Yelp Fusion API, Twilio (Phone Probe / AMD).
  - **AI / LLMs**: Google Gemini (Gemini 3.6 Flash / Gemini Vision / Flash Latest), Anthropic Claude, OpenAI GPT.
- **Frontend / Dashboard**: Ops Console (`workflows/ops-console.sdk.ts`), a self-contained SPA embedded in an n8n webhook node with IBM Plex / Fraunces styling.

---

## Codebase Navigation

```
.
├── AGENTS.md                                # System context & agent instructions (this file)
├── CLAUDE.md                                # Quick reference & architectural rules
├── README.md                                # System overview & documentation sitemap
├── addon.py                                 # Custom integrations & CLI helpers
├── db/
│   ├── functions/                           # PL/pgSQL functions with @@SCHEMA@@ placeholders
│   │   ├── 00_helpers.sql                   # Schema helpers & type definitions
│   │   ├── campaign_lifecycle.sql           # Campaign state transition RPCs
│   │   ├── claim_work_items.sql             # Queue claim & lease logic
│   │   ├── complete_work_items.sql          # Worker completion & evidence ingestion
│   │   ├── finalization.sql                 # Campaign completion & sweeper logic
│   │   ├── paid_operations.sql              # Budget authorization & transactions
│   │   └── sweeper_engine.sql               # Dependency reconciliation & stale item cleanup
│   ├── migrations/                          # Sequential SQL migrations (000 to 180+)
│   ├── seeds/                               # System configuration seed SQL
│   └── tests/                               # Database assertion & concurrency test suites
│       ├── race_tests.sql                   # Concurrency / failure injection suite
│       └── us1_assertions.sql               # US1 validation assertion suite
├── docs/                                    # System design & architecture specifications
├── fixtures/                                # Places/enrichment test fixtures
├── golden/                                  # Golden dataset expectations JSON
├── n8n-hosting/                             # Caddy, Docker Compose, AWS CloudFormation, & SSL keys
├── scripts/                                 # Maintenance, test, and deployment scripts
│   ├── deploy-db.ps1                        # Applies migrations & renders functions into both schemas
│   ├── import-workflows.ps1                 # Workflow JSON import helper
│   ├── patch_workflow_secrets.ts            # Local secret patcher for SDK workflow files
│   ├── redeploy_ops_console_cors.py         # CORS patch script for Ops Console
│   ├── run-race-tests.ps1 / .sh             # Concurrency suite runner over SSH
│   └── validate-us1.ps1                     # Runs US1 database assertions
├── specs/001-leadgen-fleet/                 # Feature specs, contracts, & data model
│   ├── contracts/                           # Request, SQL API, and service contracts
│   ├── data-model.md                        # Database schema & entity-relationship specs
│   ├── plan.md                              # Implementation roadmap
│   ├── quickstart.md                        # Fleet validation guide
│   ├── spec.md                              # Functional requirements & user stories
│   └── tasks.md                             # Phase-by-phase task breakdown
└── workflows/                               # n8n Workflow SDK TypeScript source code
    ├── README.md                            # Workflow inventory & deployed instance IDs
    ├── discovery.sdk.ts                     # Google Places & SerpApi discovery service
    ├── website-auditor.sdk.ts               # Website Auditor (PSI, Tech Stack, Pixels)
    ├── review-miner.sdk.ts                  # Google & Yelp Review Miner
    ├── phone-presence.sdk.ts                # Phone presence & Twilio probe service
    ├── social-activity.sdk.ts               # Apify Instagram/Facebook/TikTok scraper
    ├── ads-verification.sdk.ts              # SerpApi Bing Search Ads verification
    ├── competitors-gap.sdk.ts               # Competitor gap finder & peer comparison
    ├── scorer.sdk.ts                        # Multi-product fit & opportunity scoring
    ├── report-generator.sdk.ts              # Personalized pitch/audit HTML report generator
    ├── sweeper.sdk.ts                       # Campaign finalization sweeper
    └── ops-console.sdk.ts                   # Internal operator dashboard SPA
```

---

## Development Commands

### 1. Database Operations
- **Deploy Full Database** (Migrations + render functions to `leadgen` & `leadgen_dryrun` + seeds):
  ```bash
  pwsh ./scripts/deploy-db.ps1 -Database leadgen_db -WithSeeds
  ```
- **Update Functions / Schema Only** (Skip cluster roles):
  ```bash
  pwsh ./scripts/deploy-db.ps1 -Database leadgen_db -SkipRoles
  ```
- **Ad-hoc Function Render & Apply** (Single file to production schema):
  ```bash
  sed "s/@@SCHEMA@@/leadgen/g" db/functions/complete_work_items.sql | psql -d leadgen_db
  ```
- **SSH Tunnel to Remote Lightsail Postgres**:
  ```bash
  ssh -i "n8n-hosting/LightsailDefaultKey-us-east-1 (2).pem" -L 5433:localhost:5432 ubuntu@98.83.124.239
  ```
- **Execute psql inside Docker Container on Remote Host**:
  ```bash
  sudo docker exec -it n8n-postgres-1 psql -U n8n_root -d leadgen_db
  ```

### 2. Testing & Validation
- **Run US1 Assertion Suite (PowerShell)**:
  ```bash
  pwsh ./scripts/validate-us1.ps1 -Schema leadgen
  ```
- **Run Concurrency / Race Test Suite**:
  ```bash
  pwsh ./scripts/run-race-tests.ps1
  ```

### 3. Workflow Deployment & Patching
- **Patch Workflow Secrets into Local TypeScript SDK Archives**:
  ```bash
  npx ts-node scripts/patch_workflow_secrets.ts
  ```
- **Redeploy Ops Console CORS Headers**:
  ```bash
  python scripts/redeploy_ops_console_cors.py
  ```
- **Deploy Workflow Code via n8n MCP**:
  Use `create_workflow_from_code` or `update_workflow` followed by `publish_workflow`.

---

## Agent Guidelines & Guardrails

### 1. SQL & Mutation Rules
- **NEVER** write direct DML (`INSERT`, `UPDATE`, `DELETE`) on core tables (`campaigns`, `campaign_leads`, `work_items`, `evidence_items`, `budget_transactions`) in n8n nodes or ad-hoc scripts. All state changes MUST be encapsulated in PL/pgSQL functions located in `db/functions/`.
- **Function Placeholders**: SQL function source files in `db/functions/*.sql` MUST use `@@SCHEMA@@` for schema names so `deploy-db.ps1` can render them into both `leadgen` and `leadgen_dryrun`.

### 2. Queue & Fencing Discipline
- Worker completion RPCs (`complete_work_items`, `fail_work_item`) MUST verify that the item is currently claimed (`state = 'running'`), matching the active `claim_token`, and that the lease has not expired (`lease_expires_at > now()`).

### 3. Evidence Immutability
- **DO NOT** modify existing evidence rows. `evidence_items` is append-only.
- To correct faulty or outdated evidence, call `leadgen._insert_evidence` with a new observation.

### 4. Secret & Credential Protections
- **NEVER** commit API tokens (Apify, Gemini, Yelp, SerpApi, Apollo, Hunter), AWS credentials, DB passwords, SSH keys, or n8n Bearer tokens.
- Redact secrets in TypeScript SDK workflow files (`workflows/*.sdk.ts`) to `<<PLACEHOLDER>>`.
- **NEVER** commit `.mcp.json`, `.env`, or `.pem` files.
- Commits must use `--no-gpg-sign` and branch off `main`.

### 5. Protected Paths (DO NOT MODIFY without explicit permission)
- `n8n-hosting/*.pem` (SSH private keys for Lightsail)
- `.mcp.json` (Local MCP server credentials)
- `db/migrations/000_database_roles.sql` (Database role definitions)
- Deployed n8n credentials in the n8n database instance
