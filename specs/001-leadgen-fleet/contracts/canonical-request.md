# Contract: Canonical Research Request

All three intake channels normalize to this object before calling `create_campaign()`. The pipeline never learns the trigger source from the caller.

## Schema (v1.0)

```json
{
  "schema_version": "1.0",
  "request_id": "caller-generated-unique-id",
  "business_type": "dentist",
  "geo": { "type": "city_radius", "city": "Austin, TX", "radius_m": 25000 },
  "depth": "quick | standard | deep",
  "volume_cap": 50,
  "budget": { "amount": 25, "currency": "USD" },
  "requires_approval": true,
  "exclusions": { "domains": [], "names": [] },
  "dry_run": false
}
```

### `geo` variants

```json
{ "type": "zip", "zip": "78613", "radius_m": 15000 }
{ "type": "city_radius", "city": "Austin, TX", "radius_m": 25000 }
```

(`region` geography — counties, administrative areas — is **not supported in v1**; requests with `type: "region"` are rejected at intake. Deferred to v2 with a proper boundary-polygon model.)

## Validation rules (enforced at intake; violations → 4xx with error detail, no campaign created)

| Rule | Behavior |
|---|---|
| `schema_version` supported | Reject unknown versions |
| `request_id` present + unique **per caller** (`UNIQUE(caller_identity, request_id)`) | Replay returns the existing campaign reference (idempotent) — never a duplicate. `caller_identity` comes from authentication (webhook) or an internal identity (form/schedule), passed to `create_campaign()` as a trusted argument — never from the JSON body |
| `volume_cap` ≤ 300 | Reject above v1 system maximum |
| `budget.currency` = "USD" | Reject anything else (v1) |
| `budget.amount` ≤ caller's authorized limit | Caller identity (webhook auth) bounds allowable budget |
| `depth` ∈ quick\|standard\|deep | Reject otherwise |
| `trigger_source` | **Set by the intake workflow — never accepted from the caller** |

## Per-channel behavior

- **Form intake**: n8n Form; generates `request_id`; `requires_approval` defaults **true**.
- **Scheduled intake**: reads standing ICP rows from the input sheet (the only sheet machines ever read); per-row cursor state in the ledger; `requires_approval` **false** by design; `request_id` derived from (row id, scheduled slot) for idempotency.
- **Webhook intake**: authenticated (header credential); JSON validated against this contract; caller identity logged and bounds budget.

## Response (all channels)

```json
{
  "campaign_id": "…",
  "creation_status": "created | existing",
  "campaign_status": "created",
  "dashboard_url": "…"
}
```

(`creation_status` reports the idempotency outcome; `campaign_status` reports lifecycle — deliberately separate fields.)
