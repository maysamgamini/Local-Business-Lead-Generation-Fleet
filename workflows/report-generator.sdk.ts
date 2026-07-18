// Leadgen — Report Generator (deployed instance: LD2ujo15iFNfrhEM; active).
// MODES: POST {campaign_lead_id} = single lead; POST {campaign_id} = BATCH all warm/hot
//   leads in the campaign (per-item fan-out; responseMode lastNode returns each result).
// DELIVERY: bucket only (no DB double copy — lead_reports stores just the URL/pointer;
//   reports regenerate from the ledger anyway). Agency brand = "HiLeadDiscovery Studio".
// Webhook -> Load Report Data (business + current assessment +
// evidence bundle) -> Build Pitch Prompt -> Compose Pitch (Gemini gemini-flash-latest,
// tailored to best_angle) -> Build & Upload Report (Code: build a self-contained,
// theme-aware HTML audit from evidence + pitch; server-render score gauges as SVG;
// AWS SigV4-sign a PUT with require('crypto') + this.helpers.httpRequest; upload to the
// Lightsail S3 bucket public-read at an unguessable key) -> Record Report
// (record_lead_report: DB copy + URL) -> responseMode lastNode returns {result:{url}}.
//
// DELIVERY = "secret link": public-read object, unguessable key, bucket listing disabled.
// DOUBLE COPY: DB (lead_reports.html) + bucket object; reports also regenerate from evidence.
// SECRETS live in the request/Code (n8n DB), redacted here: <<GEMINI_KEY>> in Compose Pitch
// URL; <<AWS_KEY>>/<<AWS_SECRET>> in Build & Upload. Bucket n8n-leadgen-reports (us-east-1),
// verified signed PUT + public read. Report design = "clinical luxury" (see the artifact
// sample); headline/lede/sections come from Gemini, all numbers/findings from the ledger.
// GOTCHAS baked in: (a) Gemini sometimes drops the trailing '}' even at finishReason STOP
//   -> the parser tries the raw text then a few appended closers. (b) n8n Code nodes CAN
//   require('crypto') and use this.helpers.httpRequest (probed). (c) HTML has no newlines so
//   it embeds cleanly in the record SQL literal (single-quote-doubled).
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const hook = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Report Webhook', position: [200, 300], parameters: { httpMethod: 'POST', path: 'leadgen-report', responseMode: 'lastNode' } }, output: [{ body: { campaign_lead_id: 'x' } }] });

// Single OR batch: $1=campaign_lead_id, $2=campaign_id. Missing id -> '-' sentinel
// (n8n drops EMPTY comma-separated queryReplacement segments -> "no parameter $2";
// a non-empty sentinel keeps both params bound). NULLIF(..,'-') no-ops the unused branch.
const load = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Load Report Data', position: [460, 300], parameters: { operation: 'executeQuery', query: "SELECT cl.id AS campaign_lead_id, b.business_name, b.website_domain, b.address, b.phone_e164, a.best_angle, cl.classification, (SELECT jsonb_object_agg(feature_key, value_jsonb) FROM leadgen.evidence_items WHERE business_id=b.id AND campaign_id=cl.campaign_id) AS evidence FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id JOIN leadgen.lead_assessments a ON a.campaign_lead_id=cl.id AND a.is_current WHERE cl.id = NULLIF($1,'-')::uuid OR (cl.campaign_id = NULLIF($2,'-')::uuid AND cl.classification IN ('warm','hot'))", options: { queryReplacement: expr("{{ $json.body.campaign_lead_id || '-' }},{{ $json.body.campaign_id || '-' }}") } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ campaign_lead_id: 'x', evidence: {} }] });

const prep = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Build Pitch Prompt', position: [720, 300], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "const r=$json; const ev=r.evidence||{}; const vision=(ev.design_findings&&ev.design_findings.vision)||{}; const brief={business:r.business_name,website:r.website_domain||null,best_angle:r.best_angle,rating:ev.rating,reviews:ev.review_volume,psi:{performance:ev.pagespeed_performance,seo:ev.pagespeed_seo,accessibility:ev.pagespeed_accessibility},staleness_years:ev.staleness_years,mobile_friendly:ev.mobile_friendly,design:{design_age:vision.design_age,visual_appeal:vision.visual_appeal,mobile_impression:vision.mobile_impression,top_issues:vision.top_issues,redesign_rationale:vision.redesign_rationale},phone_pain:ev.phone_pain_score,phone_complaint_share:ev.phone_complaint_share,owner_response_rate:ev.owner_response_rate,complaint_themes:(ev.complaint_themes&&ev.complaint_themes.themes)||[]}; const prompt='You are a senior strategist at a digital agency writing a persuasive but HONEST audit to send a local business as a soft sales pitch. Lead with the angle '+(r.best_angle||'web_seo')+'. Products: web_seo=website redesign; voice_ai=AI phone receptionist for missed-call/scheduling pain; ads_video=visibility and reputation marketing; consulting. Using ONLY the evidence JSON (never invent facts or numbers), return ONLY compact JSON: {headline: punchy up to 12 words contrasting a strength vs a weakness, lede: 2 sentences, primary_angle, sections: array of 2 to 4 objects {title, body: 2-3 specific sentences citing the real evidence} tailored to the strongest angles that actually have evidence, recommendation: 1-2 sentences on what we would do, cta_line: one inviting line}. Evidence: '+JSON.stringify(brief); return { json:{ geminiBody:{ contents:[{parts:[{text:prompt}]}], generationConfig:{ responseMimeType:'application/json', maxOutputTokens:1300, thinkingConfig:{thinkingBudget:0} } } } };" } }, output: [{ geminiBody: {} }] });

const pitch = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Compose Pitch', position: [980, 300], onError: 'continueRegularOutput', retryOnFail: true, maxTries: 2, waitBetweenTries: 5000, parameters: { method: 'POST', url: 'https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=<<GEMINI_KEY>>', sendBody: true, specifyBody: 'json', jsonBody: expr('={{ $json.geminiBody }}'), options: { timeout: 60000 } } }, output: [{ candidates: [] }] });

// Build & Upload Report — full jsCode is deployed on LD2ujo15iFNfrhEM. It: robustly parses
// the Gemini JSON (tries raw + appended closers for the dropped-'}' quirk); builds the HTML
// (masthead, hero headline/lede, reputation-vs-website contrast, screenshot exhibit, vision
// findings, PSI score gauges [server-rendered SVG], redesign-rationale pull-quote, Gemini
// pitch sections, brand-colour palette, CTA); AWS SigV4-signs (kDate->kRegion->kService->
// kSigning; signed headers host;x-amz-acl;x-amz-content-sha256;x-amz-date) and PUTs to
// https://n8n-leadgen-reports.s3.us-east-1.amazonaws.com/reports/<slug>-<rand>.html with
// x-amz-acl:public-read; returns {campaign_lead_id, report_url, object_key, best_angle,
// summary, html}. Secrets <<AWS_KEY>>/<<AWS_SECRET>> inline (redacted). See instance for source.
const build = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Build & Upload Report', position: [1240, 300], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: '/* see deployed instance LD2ujo15iFNfrhEM; AWS SigV4 upload with <<AWS_KEY>>/<<AWS_SECRET>> */' } }, output: [{ report_url: 'https://...' }] });

const record = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Record Report', position: [1500, 300], parameters: { operation: 'executeQuery', query: "=SELECT leadgen.record_lead_report('{{ $json.campaign_lead_id }}'::uuid, '{{ $json.report_url }}', '{{ $json.object_key }}', '{{ $json.best_angle }}', '{{ ($json.summary||'').replace(/'/g,\"''\") }}', '{{ ($json.html||'').replace(/'/g,\"''\") }}'::text) AS result", options: {} }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ result: {} }] });

const note = sticky('## Report Generator\n\nPOST {campaign_lead_id} (single) or {campaign_id} (batch: all warm/hot) -> load evidence -> Gemini pitch (tailored to best_angle) -> build self-contained HTML -> SigV4 upload to S3 (public-read, unguessable key = secret link) -> record_lead_report (URL pointer; bucket-only, no DB copy) -> returns URL(s). Bucket n8n-leadgen-reports (us-east-1). Design "clinical luxury"; brand = HiLeadDiscovery Studio.', [load], { color: 4 });

export default workflow('leadgen-report-generator', 'Leadgen — Report Generator')
  .add(hook).to(load).to(prep).to(pitch).to(build).to(record)
  .add(note);
