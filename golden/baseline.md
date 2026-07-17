# Reference Deployment Baseline

SC-001/SC-011 are measured against THIS deployment. Update the "actuals" section at each rehearsal (T062); never edit historical entries.

## Target host

AWS Lightsail, Ubuntu 24.04, `44.200.15.197` (serves n8n.hiwebenterprise.com via Caddy). SSH: `ubuntu@` with the Lightsail default key (untracked, see .gitignore).

## Current state (verified live 2026-07-16)

| Component | State |
|---|---|
| n8n | **2.30.4** (custom image `local/n8n-claude:2.30.4`) — single main, NO queue mode |
| Task runners | ✅ `n8nio/runners:2.30.4` container running (external task-runner mode active) |
| Postgres | ✅ 16, healthy (`n8n-postgres-1`) — target for `leadgen_db` |
| Caddy | ✅ TLS proxy |
| Redis / workers | ❌ **absent — queue-mode migration required (T004)** |

## Pinned reference deployment (for SC measurements)

| Parameter | Value |
|---|---|
| n8n version | **2.30.4** (pin exactly; upgrade = new baseline entry) |
| Topology | 1 main + 2 workers + Redis (1 GB), worker concurrency 10 |
| Host | 4 vCPU / 8 GB (n8n stack); Postgres shares instance (2 GB effective) |
| Measurement | p95 request→digest, approval waiting excluded, ≤60 enrichment-eligible per 300-lead campaign |
| Provider quota assumptions | recorded at first rehearsal alongside actuals |

## Queue-mode migration procedure (T004 — REQUIRES MAINTENANCE WINDOW: restarts live n8n)

Base: the locally modified `n8n-hosting/docker-compose/withPostgresAndWorker/` compose (already adapted to the custom image). Steps:

1. Snapshot the Lightsail instance (rollback point).
2. Copy the compose + `.env` deltas to the host; key env additions to ALL n8n containers:
   `EXECUTIONS_MODE=queue`, `QUEUE_BULL_REDIS_HOST=redis`, `QUEUE_HEALTH_CHECK_ACTIVE=true`,
   `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`, keep `N8N_RUNNERS_ENABLED=true` (runners already in use),
   `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=336` (14 days).
3. `docker compose up -d redis` first; verify; then recreate main + add `worker-1`, `worker-2` (same custom image, `command: worker`, concurrency 10).
4. Verify: `docker ps` shows main+2 workers+runner+redis; run a manual test workflow; confirm execution shows a worker hostname.
5. Record actual topology + date below.

## Rehearsal actuals (append-only)

| Date | n8n | Topology | Campaign | p95 | Notes |
|---|---|---|---|---|---|
| _pending T062_ | | | | | |
