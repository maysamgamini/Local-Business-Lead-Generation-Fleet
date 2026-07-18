// Leadgen — Intake Form (deployed instance: SzTS1b6tJHnQmvY3)
// US1 T031: canonical request normalization -> create_campaign() with trusted
// form caller identity. Validation enforced by the SQL function (typed errors).
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const campaignForm = trigger({
  type: 'n8n-nodes-base.formTrigger',
  version: 2.6,
  config: {
    name: 'Campaign Request Form',
    position: [240, 300],
    parameters: {
      formTitle: 'Lead Research Campaign',
      formDescription: 'Launch an agentic local-business research campaign. Results land in the ledger; hot candidates surface in the digest.',
      responseMode: 'lastNode',
      formFields: {
        values: [
          { fieldLabel: 'Business Type', fieldType: 'text', placeholder: 'e.g. med spa, dental office', requiredField: true },
          { fieldLabel: 'Geo Mode', fieldType: 'dropdown', fieldOptions: { values: [{ option: 'zip' }, { option: 'city_radius' }] }, requiredField: true },
          { fieldLabel: 'Zip Code', fieldType: 'text', placeholder: '78613 (when Geo Mode = zip)' },
          { fieldLabel: 'City', fieldType: 'text', placeholder: 'Austin, TX (when Geo Mode = city_radius)' },
          { fieldLabel: 'Radius Km', fieldType: 'number', defaultValue: '15', requiredField: true },
          { fieldLabel: 'Depth', fieldType: 'dropdown', fieldOptions: { values: [{ option: 'quick' }, { option: 'standard' }, { option: 'deep' }] }, requiredField: true },
          { fieldLabel: 'Volume Cap', fieldType: 'number', defaultValue: '25', requiredField: true },
          { fieldLabel: 'Budget USD', fieldType: 'number', defaultValue: '25', requiredField: true },
          { fieldLabel: 'Exclude Domains', fieldType: 'textarea', placeholder: 'comma-separated domains to skip (existing clients, competitors)' }
        ]
      }
    }
  },
  output: [{ 'Business Type': 'med spa', 'Geo Mode': 'zip', 'Zip Code': '78613', 'City': '', 'Radius Km': 15, 'Depth': 'quick', 'Volume Cap': 25, 'Budget USD': 25, 'Exclude Domains': '', submittedAt: '2026-07-17T12:00:00.000Z', formMode: 'production' }]
});

const buildRequest = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Build Canonical Request',
    position: [560, 300],
    parameters: {
      mode: 'raw',
      includeOtherFields: false,
      jsonOutput: expr('{{ { "request": { "schema_version": "1.0", "request_id": "form-" + $execution.id, "business_type": $json["Business Type"], "geo": ($json["Geo Mode"] === "zip" ? { "type": "zip", "zip": ($json["Zip Code"] || "").toString().trim(), "radius_m": Math.round(Number($json["Radius Km"]) * 1000) } : { "type": "city_radius", "city": ($json["City"] || "").toString().trim(), "radius_m": Math.round(Number($json["Radius Km"]) * 1000) }), "depth": $json["Depth"], "volume_cap": Math.round(Number($json["Volume Cap"])), "budget": { "amount": Number($json["Budget USD"]), "currency": "USD" }, "requires_approval": false, "exclusions": { "domains": ($json["Exclude Domains"] || "").split(",").map(s => s.trim().toLowerCase()).filter(s => s.length > 0), "names": [] }, "dry_run": false } } }}')
    }
  },
  output: [{ request: { schema_version: '1.0', request_id: 'form-123', business_type: 'med spa', geo: { type: 'zip', zip: '78613', radius_m: 15000 }, depth: 'quick', volume_cap: 25, budget: { amount: 25, currency: 'USD' }, requires_approval: false, exclusions: { domains: [], names: [] }, dry_run: false } }]
});

const createCampaign = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Create Campaign',
    position: [860, 300],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT campaign_id, creation_status FROM leadgen.create_campaign('{{ JSON.stringify($json.request).replace(/'/g, \"''\") }}'::jsonb, 'bbbbbbbb-0000-0000-0000-000000000001'::uuid, 'form')")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ campaign_id: 'c0ffee00-0000-0000-0000-000000000000', creation_status: 'created' }]
});

const confirmation = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Confirmation',
    position: [1160, 300],
    parameters: {
      mode: 'manual',
      includeOtherFields: false,
      assignments: {
        assignments: [
          { id: 'c1', name: 'text', value: expr('Campaign {{ $json.creation_status }}: {{ $json.campaign_id }}. Discovery starts within a minute; watch campaign_progress in the ledger.'), type: 'string' }
        ]
      }
    }
  },
  output: [{ text: 'Campaign created: c0ffee00... Discovery starts within a minute.' }]
});

const intakeNote = sticky(
  '## Form Intake (US1, T031)\n\nNormalizes the form into the canonical request and calls create_campaign() with the TRUSTED caller identity for form submissions (bbbbbbbb-...-0001) and trigger_source=form.\n\nValidation lives in the SQL function (typed errors); a rejected request errors this execution and surfaces via the global error handler. Form submissions are hardcoded requires_approval=false (no human gate for self-serve form runs; the approval-link workflow is US2/T044 and not yet deployed).\n\nJSON is embedded with quote-doubling because Postgres-node queryReplacement splits on commas.',
  [buildRequest, createCampaign],
  { color: 5 }
);

export default workflow('leadgen-intake-form', 'Leadgen — Intake Form')
  .add(campaignForm)
  .to(buildRequest)
  .to(createCampaign)
  .to(confirmation)
  .add(intakeNote);
