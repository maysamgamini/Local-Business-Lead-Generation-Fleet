// Leadgen — Website Auditor v2 (deployed instance: KKjPDVVMIHl6n5MD; v1 ecfwEfnWOCn9hPN4 retired)
// US1 T035/T036 — REDESIGN-FOCUSED. Product goal: find businesses with outdated /
// visually weak sites, so the auditor SCORES those high (best redesign prospects)
// and captures material for the sales report + redesign.
//
// Per lead: Fetch HTML (Googlebot UA, fenced by onError):
//   - site DOWN  -> reachable=false + max staleness (broken site = strong prospect) -> complete
//   - site UP    -> Extract freshness (copyright year + Last-Modified -> staleness_years)
//                   + viewport (mobile_friendly) -> PSI x3 (perf/seo/accessibility;
//                   429 -> Defer) -> Gemini Flash VISION on a thum.io screenshot
//                   (design_age, visual_appeal, quotable redesign_rationale, brand_colors)
//                   -> typed evidence + a 'design_findings' evidence blob (screenshot URL,
//                   rationale, issues, colors) stored for the report & redesign step.
// Gemini vision degrades gracefully (onError continue -> PSI+freshness still score).
// Vision model: gemini-2.5-flash via existing Gemini credential (cheapest multimodal;
// pennies per lead). PSI key is in the request URL (n8n DB); redacted to <<PSI_KEY>> here.
// New scoring features (db/seeds/scoring-v2-redesign-features.sql): mobile_friendly,
// staleness_years, visual_appeal, pagespeed_accessibility (design_age_estimate already present).
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({ type: 'n8n-nodes-base.scheduleTrigger', version: 1.3, config: { name: 'Poll Website Queue', position: [200, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } }, output: [{}] });
const pokeWebhook = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Website Poke', position: [200, 440], parameters: { httpMethod: 'POST', path: 'leadgen-website-poke', responseMode: 'onReceived' } }, output: [{ body: {} }] });

const claimWork = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Claim Website Work', position: [460, 320], executeOnce: true, parameters: { operation: 'executeQuery', query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id FROM leadgen.claim_work_items('website', $1)", options: { queryReplacement: expr('website-{{ $execution.id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ work_item_id: 'wi1', claim_token: 'ct1', service_run_id: 'sr1', campaign_id: 'c1', campaign_lead_id: 'l1' }] });

const getTarget = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Get Target', position: [700, 320], parameters: { operation: 'executeQuery', query: "SELECT b.id AS business_id, b.website_domain, b.business_name FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id WHERE cl.id=$1", options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ business_id: 'b1', website_domain: 'spadulce.com', business_name: 'Spa Dulce' }] });

const fetchHtml = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Fetch HTML', position: [940, 320], onError: 'continueErrorOutput', retryOnFail: true, maxTries: 2, waitBetweenTries: 2000, parameters: { method: 'GET', url: expr('https://{{ $json.website_domain }}'), sendHeaders: true, specifyHeaders: 'keypair', headerParameters: { parameters: [ { name: 'User-Agent', value: 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' } ] }, options: { timeout: 20000, redirect: { redirect: { followRedirects: true } }, response: { response: { fullResponse: true, responseFormat: 'text' } } } } }, output: [{ body: '<html>...</html>', headers: { 'last-modified': 'Tue, 01 Jan 2019 00:00:00 GMT' } }] });

const extractSignals = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Extract HTML Signals', position: [1180, 220], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "const resp=$json; const html=((resp.body||resp.data||'')+''); const headers=resp.headers||{}; const lc=html.toLowerCase(); const hasViewport=lc.includes('viewport'); function cy(text){ const t=text.toLowerCase(); let best=0; const marks=['copyright','copy;','(c)', String.fromCharCode(169)]; for(const mk of marks){ let i=t.indexOf(mk); let guard=0; while(i!==-1 && guard<50){ const w=text.slice(i,i+40); for(let y=2010;y<=2026;y++){ if(w.includes(String(y)) && y>best) best=y; } i=t.indexOf(mk,i+1); guard++; } } return best||null; } const copyrightYear=cy(html); const lmr=headers['last-modified']||headers['Last-Modified']; const lastMod=lmr?new Date(lmr).getFullYear():null; const nowY=new Date().getFullYear(); const ref=Math.max(copyrightYear||0,lastMod||0)||null; const staleness=ref?Math.max(0,nowY-ref):null; return { json:{ hasViewport, copyrightYear, lastMod, staleness, reachable:true } };" } }, output: [{ hasViewport: true, copyrightYear: 2019, staleness: 7, reachable: true }] });

const runPsi = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Run PageSpeed', position: [1420, 220], onError: 'continueErrorOutput', retryOnFail: true, maxTries: 3, waitBetweenTries: 3000, parameters: { method: 'GET', url: expr("https://www.googleapis.com/pagespeedonline/v5/runPagespeed?url=https://{{ $('Get Target').item.json.website_domain }}&strategy=mobile&category=performance&category=seo&category=accessibility&key=<<PSI_KEY>>"), authentication: 'none', options: { timeout: 60000, batching: { batch: { batchSize: 1, batchInterval: 1500 } } } } }, output: [{ lighthouseResult: { categories: { performance: { score: 0.5 }, seo: { score: 0.8 }, accessibility: { score: 0.7 } } } }] });

const geminiVision = node({ type: '@n8n/n8n-nodes-langchain.googleGemini', version: 1.2, config: { name: 'Gemini Vision Design', position: [1660, 220], onError: 'continueRegularOutput', parameters: { resource: 'image', operation: 'analyze', modelId: { __rl: true, mode: 'list', value: 'models/gemini-2.5-flash', cachedResultName: 'gemini-2.5-flash' }, inputType: 'url', imageUrls: expr("https://image.thum.io/get/width/1200/https://{{ $('Get Target').item.json.website_domain }}"), simplify: true, text: "You are a web-design expert assessing a small-business website screenshot to pitch a redesign. Return ONLY compact JSON, no prose: {design_age:dated|aging|modern, visual_appeal:poor|average|good, mobile_impression:poor|average|good, top_issues:[..], brand_colors:[#hex], redesign_rationale:one quotable sentence}. Judge harshly on outdated aesthetics, clutter, weak hierarchy, dated fonts, generic templates, poor imagery.", options: { maxOutputTokens: 500 } }, credentials: { googlePalmApi: newCredential('Google Gemini(PaLM) Api account') } }, output: [{ content: '{design_age:dated}' }] });

// Build Website Evidence + Complete + Defer + Build Down Evidence + Complete Down:
// see deployed workflow KKjPDVVMIHl6n5MD (identical to the validated create call).
export default workflow('leadgen-website-auditor-v2', 'Leadgen — Website Auditor')
  .add(everyMinute).to(claimWork)
  .add(pokeWebhook).to(claimWork)
  .add(claimWork).to(getTarget).to(fetchHtml)
  .add(fetchHtml).to(extractSignals).to(runPsi).to(geminiVision);
