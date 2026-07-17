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

## DEPLOYED topology (T004 applied 2026-07-17, ~2 min downtime)

| Parameter | Actual |
|---|---|
| n8n version | **2.30.4** (`local/n8n-claude:2.30.4`) |
| Mode | **EXECUTIONS_MODE=queue** ✅ — verified: Bull keys in Redis, worker consuming |
| Topology | 1 main + **1 worker (concurrency 5)** + worker-runner + Redis 7 + Caddy + Postgres 16 |
| Main runner | **Removed by design**: with `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` the main executes nothing and starts no task broker (verified: port 5679 refused on main, healthy on worker); all executions incl. manual run on the worker, whose runner registered both launchers (js + py) |
| Host | **2 vCPU / 2 GB RAM** (⚠️ smaller than the originally pinned 4 vCPU/8 GB reference) + **2 GB swapfile added** (persistent via fstab); post-deploy: ~1.0 GiB used / ~870 MiB available |
| Pruning | EXECUTIONS_DATA_PRUNE=true, MAX_AGE=336h |
| Rollback | `docker-compose.yml.bak-pre-queue-*` in `/home/ubuntu/n8n/` |

## ⚠️ Capacity note for SC-001/SC-011

The 2 GB host CANNOT hold the originally pinned 2-worker/concurrency-10 reference. Current capacity (1 worker × 5) is adequate for US1 development, dry-runs, and `quick`-depth golden campaigns. **Before the T062 rehearsal (300 leads, 3 concurrent campaigns), upgrade the Lightsail plan to ≥4 GB (ideally 8 GB), add the second worker + runner pair (copy the n8n-worker/-runner service blocks), and raise concurrency to 10 — then record the new baseline entry here.** SC-001's p95 promise is only measured against the upgraded topology.

## Reference measurement parameters

p95 request→digest, approval waiting excluded, ≤60 enrichment-eligible per 300-lead campaign; provider quota assumptions recorded at first rehearsal.

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
