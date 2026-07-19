// Leadgen — Social Activity (warm-gated 'social' fleet service). Deployed instance: vwVPshHYWl4t8fzH.
// Claim 'social' -> Get Target (business + social_links evidence from the Website Auditor) ->
// Scrape & Build (one Code node, this.helpers.httpRequest -> Apify): Instagram
// (apify~instagram-scraper, resultsType details -> followersCount + latestPosts[].timestamp),
// TikTok (clockworks~tiktok-scraper, videos/latest -> authorMeta.fans + createTimeISO),
// Facebook (apify~facebook-pages-scraper -> followers/likes; no post date). Derives per-platform
// followers + last_post_days and social_inactive_90d (most-recent IG/TikTok post > 90 days, or
// TRUE when the business has no detected social presence at all). Emits typed evidence
// (product_tag 'ads_video'; social_inactive_90d already scores +25) -> complete_analysis_work_item
// with cause 'social_evidence' -> advance_lead_revision re-scores the lead on a second pass.
//
// GATING: created 'blocked' at discovery; the Scorer opens it (blocked->pending) only when the
// lead is warm/hot (complete_scorer_work_item social gate). So the paid Apify scrape runs for
// qualified leads only. Queue gives fencing/lease/retry/budget like every other service.
// SECRET: <<APIFY_TOKEN>> inline in the Code node (real value on the deployed instance; redacted here).
// v1 scrapes the social_links the Website Auditor already detected. v2: SerpApi profile discovery
// (find profiles the homepage doesn't link) + SerpApi/Apify Yelp supplement (Yelp reused from the
// Review Miner today).
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({ type: 'n8n-nodes-base.scheduleTrigger', version: 1.3, config: { name: 'Poll Social Queue', position: [200, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } }, output: [{}] });
const poke = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Social Poke', position: [200, 440], parameters: { httpMethod: 'POST', path: 'leadgen-social-poke', responseMode: 'onReceived' } }, output: [{ body: {} }] });

const claim = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Claim Social Work', position: [460, 320], executeOnce: true, parameters: { operation: 'executeQuery', query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id FROM leadgen.claim_work_items('social', $1)", options: { queryReplacement: expr('social-{{ $execution.id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ work_item_id: 'wi', claim_token: 'ct', campaign_id: 'c', campaign_lead_id: 'l' }] });

const getTarget = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Get Target', position: [720, 320], parameters: { operation: 'executeQuery', query: "SELECT b.id AS business_id, b.business_name, b.website_domain, b.address, c.business_type, (SELECT ei.value_jsonb FROM leadgen.evidence_items ei WHERE ei.business_id=b.id AND ei.campaign_id=cl.campaign_id AND ei.feature_key='social_links' ORDER BY ei.observed_at DESC LIMIT 1) AS social_links FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id JOIN leadgen.campaigns c ON c.id=cl.campaign_id WHERE cl.id=$1", options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ business_id: 'b', business_name: 'X', social_links: {} }] });

// Scrape & Build — Apify IG/FB/TikTok via this.helpers.httpRequest; derive followers +
// last_post_days + social_inactive_90d; emit typed evidence. Full jsCode on the deployed
// instance (APIFY token inline). See header for the derivation rules.
const scrape = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Scrape & Build', position: [980, 320], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "/* see deployed instance — Apify IG/FB/TikTok scrape with <<APIFY_TOKEN>>; emits social_inactive_90d + social_followers + social_last_post_days; cause_type social_evidence */" } }, output: [{ payload: {} }] });

const complete = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Complete Social', position: [1240, 320], parameters: { operation: 'executeQuery', query: "SELECT leadgen.complete_analysis_work_item('{{ $('Claim Social Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Social Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result", options: {} }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ result: {} }] });

const note = sticky('## Social Activity (warm-gated `social` service)\n\nClaim social -> Get Target (+ social_links from the Website Auditor) -> Apify IG/FB/TikTok scrape -> followers + last_post_days + social_inactive_90d (>90d most-recent post, or TRUE when no social presence) -> typed evidence (ads_video) -> complete_analysis_work_item (cause social_evidence) -> re-score. Gated to warm/hot leads by the Scorer. v2: SerpApi discovery + Yelp supplement.', [claim], { color: 5 });

export default workflow('leadgen-social-activity', 'Leadgen — Social Activity')
  .add(everyMinute).to(claim)
  .add(poke).to(claim)
  .add(claim).to(getTarget).to(scrape).to(complete)
  .add(note);
