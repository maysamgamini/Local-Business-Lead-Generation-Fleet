<#
.SYNOPSIS
  Runs the US1 checkpoint validation (T042/T043) against the n8n host DB over SSH.
  Pipes db/tests/us1_assertions.sql into the leadgen_db Postgres container; any
  failed assertion RAISEs and psql exits nonzero (ON_ERROR_STOP).

.PARAMETER Schema
  Namespace to validate. Default 'leadgen' (where live US1 campaigns ran). Pass
  'leadgen_dryrun' to validate the dry-run copy once a campaign has run there.

.EXAMPLE
  ./scripts/validate-us1.ps1
  ./scripts/validate-us1.ps1 -Schema leadgen_dryrun
#>
param(
    [string]$SshHost   = "98.83.124.239",
    [string]$KeyFile   = "n8n-hosting/LightsailDefaultKey-us-east-1 (2).pem",
    [string]$Container = "n8n-postgres-1",
    [string]$DbUser    = "n8n_root",
    [string]$Database  = "leadgen_db",
    [string]$Schema    = "leadgen"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$sql  = Join-Path $root "db/tests/us1_assertions.sql"
if (-not (Test-Path $sql)) { throw "missing $sql" }

Write-Host "US1 validation against schema '$Schema' on $SshHost ..."
# -v schema=... sets the psql var the assertion file reads; stdin carries the SQL.
$remote = "sudo docker exec -i $Container psql -U $DbUser -d $Database -v schema=$Schema"
Get-Content -Raw $sql | & ssh -i $KeyFile -o BatchMode=yes "ubuntu@$SshHost" $remote
if ($LASTEXITCODE -ne 0) { throw "US1 assertions FAILED (exit $LASTEXITCODE)" }
Write-Host "US1 validation PASSED for schema '$Schema'."
