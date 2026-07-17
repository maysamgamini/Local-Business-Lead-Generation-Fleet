// Leadgen — Website Auditor Tier 1 (deployed instance: ecfwEfnWOCn9hPN4)
// US1 T035. Claim -> get domain -> PageSpeed Insights (Lighthouse lab) -> typed
// web_seo evidence -> complete_analysis_work_item (bumps lead_revision via
// 'website_evidence' -> unblocks phone + assessment). Verified live: real
// campaign scored (e.g. It's A Secret Med Spa web_seo 17.5 from PSI).
//
// HARDENING (post-429 incident):
//  - Call spacing: batchSize 1, batchInterval 1500ms + retryOnFail (3x, 3s).
//  - Run PageSpeed onError=continueErrorOutput -> Defer Website (defer_work_item)
//    so a 429/timeout reschedules the lead instead of marking it unreachable.
//  - PSI key: n8n's httpQueryAuth credential was not reaching the request, so the
//    key is placed directly in the request URL. In the LIVE workflow the real
//    PSI-restricted key is in the URL (n8n DB only). Here it is redacted to
//    <<PSI_KEY>> so the repo stays clean — restore the real key when redeploying,
//    or move it to an $env var on the n8n containers.
import { workflow, node, trigger, sticky, expr } from '@n8n/workflow-sdk';
import { newCredential } from '@n8n/workflow-sdk';

const everyMinute = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Poll Website Queue', position: [220, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } },
  output: [{}]
});

const pokeWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: { name: 'Website Poke', position: [220, 460], parameters: { httpMethod: 'POST', path: 'leadgen-website-poke', responseMode: 'onReceived' } },
  output: [{ body: {} }]
});

const claimWork = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Claim Website Work',
    position: [520, 340],
    executeOnce: true,
    parameters: {
      operation: 'executeQuery',
      query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id FROM leadgen.claim_work_items('website', $1)",
      options: { queryReplacement: expr('website-{{ $execution.id }}') }
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ work_item_id: 'wi1', claim_token: 'ct1', service_run_id: 'sr1', campaign_id: 'c1', campaign_lead_id: 'l1' }]
});

const getTarget = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Get Target',
    position: [820, 340],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT b.id AS business_id, b.website_domain FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id WHERE cl.id=$1",
      options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') }
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ business_id: 'b1', website_domain: 'spadulce.com' }]
});

const runPsi = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Run PageSpeed',
    position: [1120, 340],
    onError: 'continueErrorOutput',
    retryOnFail: true,
    maxTries: 3,
    waitBetweenTries: 3000,
    parameters: {
      method: 'GET',
      url: expr('https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=https://{{ $json.website_domain }}&strategy=mobile&category=performance&category=seo&key=<<PSI_KEY>>'),
      authentication: 'none',
      options: { timeout: 60000, batching: { batch: { batchSize: 1, batchInterval: 1500 } } }
    }
  },
  output: [{ lighthouseResult: { categories: { performance: { score: 0.84 }, seo: { score: 0.92 } } } }]
});

const buildEvidence = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Website Evidence',
    position: [1420, 340],
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: "const psi = $json;\nconst claim = $('Claim Website Work').item.json;\nconst tgt = $('Get Target').item.json;\nconst cid = claim.campaign_id; const bid = tgt.business_id;\nconst lh = psi ? psi.lighthouseResult : null;\nfunction mk(fk, val, vt, unit){ return { feature_key:fk, value:val, value_type:vt, unit:unit, product_tag:'web_seo', source_provider:'psi', idempotency_key: cid+':'+bid+':'+fk }; }\nconst ev = [];\nif (lh && lh.categories) { const perf = Math.round(((lh.categories.performance && lh.categories.performance.score) || 0) * 100); const seo = Math.round(((lh.categories.seo && lh.categories.seo.score) || 0) * 100); ev.push(mk('pagespeed_performance', perf, 'integer', 'score')); ev.push(mk('pagespeed_seo', seo, 'integer', 'score')); ev.push({ feature_key:'website_reachable', value:true, value_type:'boolean', product_tag:'web_seo', source_provider:'psi', idempotency_key: cid+':'+bid+':website_reachable' }); }\nelse { ev.push({ feature_key:'website_reachable', value:false, value_type:'boolean', product_tag:'web_seo', source_provider:'psi', idempotency_key: cid+':'+bid+':website_reachable' }); }\nreturn { json: { payload: { cause_type:'website_evidence', evidence: ev, run:{ workflow_version:'website-auditor-v1-tier1' } } } };"
    }
  },
  output: [{ payload: {} }]
});

const complete = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Complete Website',
    position: [1720, 340],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT leadgen.complete_analysis_work_item('{{ $('Claim Website Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Website Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ result: { result: 'done', new_evidence: 3 } }]
});

const deferItem = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Defer Website',
    position: [1720, 540],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT leadgen.defer_work_item('{{ $('Claim Website Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Website Work').item.json.claim_token }}'::uuid, (now() + interval '5 minutes'), 'psi_transient') AS result")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ result: 'deferred' }]
});

const auditNote = sticky(
  '## Website Auditor — Tier 1 (US1, T035)\n\nPer-lead deterministic audit: claim -> get domain -> PageSpeed Insights (Lighthouse lab: performance + seo) -> typed web_seo evidence -> complete_analysis_work_item (bumps lead_revision -> unblocks phone + assessment -> Scorer).\n\n**Call spacing + defer**: PSI runs 1/1.5s with 3 retries; a 429/timeout routes to Defer Website (defer_work_item, ~5 min) instead of poisoning the lead. PSI (Lighthouse) is slow — 10-30s per site.\n\n**Key**: currently in the request URL (n8n DB). Move to $env or a working httpQueryAuth credential when convenient.\n\n**Follow-ups (T036)**: tech fingerprints (booking/chat -> voice_ai), marketing presence (ad_presence, social_inactive_90d -> ads_video), caged Claude Tier-2 agent.',
  [claimWork, runPsi, buildEvidence],
  { color: 5 }
);

export default workflow('leadgen-website-auditor', 'Leadgen — Website Auditor')
  .add(everyMinute)
  .to(claimWork)
  .to(getTarget)
  .to(runPsi.onError(deferItem))
  .to(buildEvidence)
  .to(complete)
  .add(pokeWebhook)
  .to(claimWork)
  .add(auditNote);
