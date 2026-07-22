// Leadgen — Social Activity (warm-gated 'social' fleet service). Deployed instance: vwVPshHYWl4t8fzH.
// Claim 'social' -> Get Target (business + social_links evidence from the Website Auditor) ->
// safe degraded completion. It emits social_inactive_90d only when no social presence was
// detected, then completes and re-scores. Synchronous Apify actor calls were removed from the
// Code node because n8n aborts JavaScript tasks after 60 seconds; restore them as HTTP Request
// nodes or an asynchronous sub-workflow.
//
// GATING: created 'blocked' at discovery; the Scorer opens it (blocked->pending) only when the
// lead is warm/hot (complete_scorer_work_item social gate). Queue gives fencing/lease/retry/
// budget like every other service.
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({ type: 'n8n-nodes-base.scheduleTrigger', version: 1.3, config: { name: 'Poll Social Queue', position: [200, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } }, output: [{}] });
const poke = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Social Poke', position: [200, 440], parameters: { httpMethod: 'POST', path: 'leadgen-social-poke', responseMode: 'onReceived' } }, output: [{ body: {} }] });

const claim = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Claim Social Work', position: [460, 320], executeOnce: true, parameters: { operation: 'executeQuery', query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id FROM leadgen.claim_work_items('social', $1)", options: { queryReplacement: expr('social-{{ $execution.id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ work_item_id: 'wi', claim_token: 'ct', campaign_id: 'c', campaign_lead_id: 'l' }] });

const getTarget = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Get Target', position: [720, 320], parameters: { operation: 'executeQuery', query: "SELECT b.id AS business_id, b.business_name, b.website_domain, b.address, c.business_type, (SELECT ei.value_jsonb FROM leadgen.evidence_items ei WHERE ei.business_id=b.id AND ei.campaign_id=cl.campaign_id AND ei.archived_at IS NULL AND ei.feature_key='social_links' ORDER BY ei.observed_at DESC LIMIT 1) AS social_links FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id JOIN leadgen.campaigns c ON c.id=cl.campaign_id WHERE cl.id=$1", options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ business_id: 'b', business_name: 'X', social_links: {} }] });

// Safe degraded path: synchronous Apify actor runs cannot live inside a Code node because
// the task runner aborts JavaScript after 60 seconds. Complete the work item immediately,
// preserving the valid "no detected social presence" signal. Platform activity scraping
// should be restored with separate HTTP Request nodes or an async sub-workflow.
const scrape = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Scrape & Build', position: [980, 320], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "const tgt=$json; const claim=$('Claim Social Work').item.json; const cid=claim.campaign_id, bid=tgt.business_id; let links={}; try{ links=(tgt.social_links&&typeof tgt.social_links==='object')?tgt.social_links:(tgt.social_links?JSON.parse(tgt.social_links):{}); }catch(e){ links={}; } const ev=[]; if(Object.keys(links).length===0){ ev.push({feature_key:'social_inactive_90d',value:true,value_type:'boolean',unit:null,product_tag:'ads_video',source_provider:'social_activity',idempotency_key:cid+':'+bid+':social_inactive_90d'}); } return {json:{payload:{cause_type:'social_evidence',evidence:ev,run:{workflow_version:'social-activity-v1-degraded',degraded_reason:'external_scrapes_moved_out_of_code_node'}}}};" } }, output: [{ payload: {} }] });

const complete = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Complete Social', position: [1240, 320], parameters: { operation: 'executeQuery', query: "=SELECT leadgen.complete_analysis_work_item('{{ $('Claim Social Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Social Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result", options: {} }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ result: {} }] });

const note = sticky('## Social Activity (warm-gated `social` service)\n\nCurrent safe mode completes immediately and emits social_inactive_90d only when no social links were detected. The prior synchronous Apify IG/FB/TikTok calls exceeded n8n\'s 60-second Code-node task limit and left campaigns analyzing. Restore activity/follower scraping with separate HTTP Request nodes or an async sub-workflow.', [claim], { color: 5 });

export default workflow('leadgen-social-activity', 'Leadgen — Social Activity')
  .add(everyMinute).to(claim)
  .add(poke).to(claim)
  .add(claim).to(getTarget).to(scrape).to(complete)
  .add(note);
