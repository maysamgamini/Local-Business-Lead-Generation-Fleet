<#
.SYNOPSIS
  Deploys the leadgen ledger: ordered migrations, then SQL functions into BOTH
  namespaces (leadgen, leadgen_dryrun), then optional seed activation.

.DESCRIPTION
  Idempotent: migrations use IF NOT EXISTS / guarded DO blocks; functions use
  CREATE OR REPLACE. Safe to re-run.

  Connection: standard PG* environment variables (PGHOST, PGPORT, PGUSER,
  PGPASSWORD) or a -ConnectionUri. Against the Lightsail box, open a tunnel first:
    ssh -i n8n-hosting/LightsailDefaultKey-us-east-1.pem -L 5433:localhost:5432 ubuntu@44.200.15.197
  then: $env:PGHOST='localhost'; $env:PGPORT='5433'

  Role passwords are NEVER stored in SQL. 000_database_roles.sql reads them from
  psql variables supplied here via environment:
    LEADGEN_PW_ANALYZER, LEADGEN_PW_SCORER, LEADGEN_PW_ENRICHER, LEADGEN_PW_SWEEPER,
    LEADGEN_PW_RELAY, LEADGEN_PW_HUMAN, LEADGEN_PW_DASHBOARD

.EXAMPLE
  ./scripts/deploy-db.ps1 -Database leadgen_db
  ./scripts/deploy-db.ps1 -Database leadgen_db -WithSeeds
#>
param(
    [string]$Database = "leadgen_db",
    [switch]$WithSeeds,
    [switch]$SkipRoles   # roles are cluster-level; skip when re-deploying schema only
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$mig  = Join-Path $root "db/migrations"
$fun  = Join-Path $root "db/functions"
$seed = Join-Path $root "db/seeds"

function Invoke-Psql {
    param([string]$Db, [string]$File, [string[]]$ExtraArgs = @())
    $args = @("-v", "ON_ERROR_STOP=1", "-X", "-q", "-d", $Db, "-f", $File) + $ExtraArgs
    Write-Host "  psql -d $Db -f $(Split-Path -Leaf $File)"
    & psql @args
    if ($LASTEXITCODE -ne 0) { throw "psql failed on $File (exit $LASTEXITCODE)" }
}

# --- 0. Ensure database exists (connect via maintenance db) -------------------
$exists = & psql -X -A -t -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$Database';"
if ($exists -ne "1") {
    Write-Host "Creating database $Database"
    & psql -X -d postgres -c "CREATE DATABASE $Database;"
    if ($LASTEXITCODE -ne 0) { throw "CREATE DATABASE failed" }
}

# --- 1. Roles (cluster-level; passwords from env) -----------------------------
if (-not $SkipRoles) {
    $pwVars = @()
    foreach ($r in "ANALYZER","SCORER","ENRICHER","SWEEPER","RELAY","HUMAN","DASHBOARD") {
        $v = [Environment]::GetEnvironmentVariable("LEADGEN_PW_$r")
        if (-not $v) { throw "Missing env var LEADGEN_PW_$r (role passwords are supplied via environment, never committed)" }
        $pwVars += @("-v", "pw_$($r.ToLower())=$v")
    }
    Invoke-Psql -Db $Database -File (Join-Path $mig "000_database_roles.sql") -ExtraArgs $pwVars
}

# --- 2. Ordered migrations (skip 000, handled above) ---------------------------
Get-ChildItem $mig -Filter "*.sql" | Where-Object { $_.Name -ne "000_database_roles.sql" } |
    Sort-Object Name | ForEach-Object { Invoke-Psql -Db $Database -File $_.FullName }

# --- 3. Functions into BOTH namespaces ----------------------------------------
# Function files are written schema-agnostic with a @@SCHEMA@@ token; we render
# each file per namespace to a temp copy and apply. Static search_path per copy.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "leadgen-fn-render"
New-Item -ItemType Directory -Force $tmp | Out-Null
foreach ($ns in "leadgen", "leadgen_dryrun") {
    Write-Host "Deploying functions into namespace: $ns"
    Get-ChildItem $fun -Filter "*.sql" | Sort-Object Name | ForEach-Object {
        $rendered = Join-Path $tmp "$ns-$($_.Name)"
        (Get-Content $_.FullName -Raw).Replace("@@SCHEMA@@", $ns) | Set-Content $rendered -NoNewline
        Invoke-Psql -Db $Database -File $rendered
    }
}

# --- 4. Seeds (config sets) -----------------------------------------------------
if ($WithSeeds) {
    Get-ChildItem $seed -Filter "*.sql" | Sort-Object Name | ForEach-Object {
        Invoke-Psql -Db $Database -File $_.FullName
    }
}

# --- 5. Smoke check --------------------------------------------------------------
& psql -X -A -t -d $Database -c "SELECT leadgen.healthcheck();"
Write-Host "deploy-db complete."
