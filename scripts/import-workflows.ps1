<#
.SYNOPSIS
  Imports/updates all workflows/*.json into the n8n instance via the public API.

.DESCRIPTION
  Uses the n8n REST API (POST /api/v1/workflows, PUT for existing — matched by
  workflow name). Requires:
    N8N_BASE_URL  e.g. https://n8n.hiwebenterprise.com
    N8N_API_KEY   personal API key (Settings → n8n API)

  Credential mapping: workflow JSON references credentials BY NAME. Create these
  credential entries in n8n before import (names must match exactly):
    leadgen-postgres          (Postgres, role varies per service — see README)
    leadgen-postgres-dryrun
    google-places, serpapi, apify, apollo, hunter, psi
    anthropic, openai, google-ai
    slack-leadgen, airtable-leadgen, gsheets-leadgen

  Import does NOT activate workflows; activate after credential verification.
#>
param(
    [string]$Filter = "*.json",
    [switch]$Activate
)
$ErrorActionPreference = "Stop"
$base = $env:N8N_BASE_URL; $key = $env:N8N_API_KEY
if (-not $base -or -not $key) { throw "Set N8N_BASE_URL and N8N_API_KEY" }
$headers = @{ "X-N8N-API-KEY" = $key; "Content-Type" = "application/json" }

$existing = (Invoke-RestMethod -Uri "$base/api/v1/workflows?limit=250" -Headers $headers).data
$root = Split-Path -Parent $PSScriptRoot

Get-ChildItem (Join-Path $root "workflows") -Filter $Filter | Sort-Object Name | ForEach-Object {
    $wf = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $body = @{ name = $wf.name; nodes = $wf.nodes; connections = $wf.connections; settings = $wf.settings } | ConvertTo-Json -Depth 50
    $match = $existing | Where-Object { $_.name -eq $wf.name }
    if ($match) {
        Write-Host "UPDATE  $($wf.name)"
        Invoke-RestMethod -Uri "$base/api/v1/workflows/$($match.id)" -Method Put -Headers $headers -Body $body | Out-Null
        $id = $match.id
    } else {
        Write-Host "CREATE  $($wf.name)"
        $created = Invoke-RestMethod -Uri "$base/api/v1/workflows" -Method Post -Headers $headers -Body $body
        $id = $created.id
    }
    if ($Activate -and $wf.active) {
        Invoke-RestMethod -Uri "$base/api/v1/workflows/$id/activate" -Method Post -Headers $headers | Out-Null
        Write-Host "ACTIVATE $($wf.name)"
    }
}
Write-Host "import-workflows complete."
