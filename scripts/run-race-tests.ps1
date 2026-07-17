<#
.SYNOPSIS
  Runs the T029 race/failure-injection suite on the n8n host over SSH.
  Wrapper around scripts/run-race-tests.sh (the suite needs true parallel psql
  sessions next to the database).
#>
param(
    [string]$SshHost = "98.83.124.239",
    [string]$KeyFile = "n8n-hosting/LightsailDefaultKey-us-east-1 (2).pem"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
& scp -i $KeyFile -o BatchMode=yes "$root/db/tests/race_tests.sql" "ubuntu@${SshHost}:/home/ubuntu/leadgen-db/db/tests/race_tests.sql"
& scp -i $KeyFile -o BatchMode=yes "$root/scripts/run-race-tests.sh" "ubuntu@${SshHost}:/home/ubuntu/leadgen-db/scripts/run-race-tests.sh"
& ssh -i $KeyFile -o BatchMode=yes "ubuntu@$SshHost" "chmod +x /home/ubuntu/leadgen-db/scripts/run-race-tests.sh && /home/ubuntu/leadgen-db/scripts/run-race-tests.sh"
if ($LASTEXITCODE -ne 0) { throw "race suite failed (exit $LASTEXITCODE)" }
