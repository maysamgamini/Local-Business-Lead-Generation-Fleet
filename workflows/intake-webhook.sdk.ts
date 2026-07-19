// Leadgen — API Intake (US3 T053). Deployed instance: stTulzWEWMCS9qPS.
// Authenticated webhook intake -> create_campaign (trusted webhook caller identity
// bbbbbbbb-...-0002, trigger_source=webhook). Body = canonical request fields; caller-scoped
// idempotency means a replayed request_id returns creation_status=existing.
//   POST https://n8n.hiwebenterprise.com/webhook/leadgen-intake-api
//   header x-leadgen-key: <<INTAKE_API_KEY>>  (real value on the deployed instance; redacted here)
//   body: { request_id?, business_type, geo:{type,zip|city,radius_m}, depth, volume_cap,
//           budget:{amount,currency:'USD'}, requires_approval?, exclusions?, dry_run? }
// Verified live: valid->created, replay->existing, no/bad key->unauthorized, missing
// business_type / volume_cap>300 -> {ok:false,error:'invalid_request'} (typed create_campaign
// validation; the Response node caps error text at 120 chars + falls back to 'invalid_request'
// so internal errors never leak to callers). create_campaign hardened with early business_type
// + geo validation (benefits the form intake too).
// CAVEAT: dry_run is NOT yet isolated — the deployed Discovery worker processes dry_run
// campaigns against real providers (no dry-run workflow variant exists; T042 deferred). Do not
// send dry_run:true expecting fixture-only behavior.
import { workflow, node, trigger, sticky, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

const hook = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'API Intake', position: [200, 300], parameters: { httpMethod: 'POST', path: 'leadgen-intake-api', responseMode: 'lastNode' } }, output: [{ body: {}, headers: {} }] });

const authCheck = ifElse({ version: 2.2, config: { name: 'Authenticated?', position: [440, 300], parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 }, combinator: 'and', conditions: [{ leftValue: expr("{{ $json.headers['x-leadgen-key'] }}"), operator: { type: 'string', operation: 'equals' }, rightValue: '<<INTAKE_API_KEY>>' }] } } } });

const buildRequest = node({ type: 'n8n-nodes-base.set', version: 3.4, config: { name: 'Build Canonical Request', position: [700, 200], parameters: { mode: 'raw', includeOtherFields: false, jsonOutput: expr('{{ { "request": { "schema_version": "1.0", "request_id": ($json.body.request_id || ("api-" + $execution.id)), "business_type": $json.body.business_type, "geo": $json.body.geo, "depth": ($json.body.depth || "standard"), "volume_cap": Math.round(Number($json.body.volume_cap || 25)), "budget": { "amount": Number(($json.body.budget && $json.body.budget.amount) || 25), "currency": (($json.body.budget && $json.body.budget.currency) || "USD") }, "requires_approval": ($json.body.requires_approval === true), "exclusions": ($json.body.exclusions || { "domains": [], "names": [] }), "dry_run": ($json.body.dry_run === true) } } }}') } }, output: [{ request: {} }] });

const createCampaign = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Create Campaign', position: [940, 200], onError: 'continueRegularOutput', parameters: { operation: 'executeQuery', query: expr("=SELECT campaign_id, creation_status FROM leadgen.create_campaign('{{ JSON.stringify($json.request).replace(/'/g, \"''\") }}'::jsonb, 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, 'webhook')") }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ campaign_id: 'x', creation_status: 'created' }] });

const okResponse = node({ type: 'n8n-nodes-base.set', version: 3.4, config: { name: 'Response', position: [1180, 200], parameters: { mode: 'raw', includeOtherFields: false, jsonOutput: expr("={{ $json.campaign_id ? { \"ok\": true, \"campaign_id\": $json.campaign_id, \"creation_status\": $json.creation_status } : { \"ok\": false, \"error\": (typeof $json.error === 'string' ? $json.error : (($json.error && typeof $json.error.message === 'string' && $json.error.message.length < 120) ? $json.error.message : 'invalid_request')) } }}") } }, output: [{ ok: true }] });

const unauthorized = node({ type: 'n8n-nodes-base.set', version: 3.4, config: { name: 'Unauthorized', position: [700, 420], parameters: { mode: 'raw', includeOtherFields: false, jsonOutput: expr('{{ { "ok": false, "error": "unauthorized" } }}') } }, output: [{ ok: false }] });

const note = sticky('## API Intake (US3, T053)\n\nAuthenticated webhook intake -> create_campaign (trusted webhook caller identity, trigger_source=webhook). Shared-secret header x-leadgen-key (redacted). Body = canonical request fields; request_id replay -> creation_status=existing (caller-scoped idempotency). Validation errors from create_campaign returned as {ok:false,error}. Budget/volume caps enforced by create_campaign.', [buildRequest, createCampaign], { color: 4 });

export default workflow('leadgen-intake-webhook', 'Leadgen — API Intake')
  .add(hook)
  .to(authCheck.onTrue(buildRequest.to(createCampaign).to(okResponse)).onFalse(unauthorized))
  .add(note);
