// Leadgen — Phone Probe Service (warm-gated 'phone_probe' fleet service). Deployed: BP3pMFyvJ0n0bPLX.
// Phone Presence V3 (INTERACTIVE / Level 3), fleet-integrated. Claim 'phone_probe' -> Get phone ->
// [phone?] Twilio call + AMD, Url -> /leadgen-phone-twiml-ask TwiML which speaks a direct question
// ("Am I speaking with an automated assistant, or a real person?") then Records the answer
// (RecordingTrack='both') -> Wait 45s -> poll answered_by ->
// **Classify Greeting** (deployed node: fetch the Twilio recording -> Gemini flash AUDIO
// classification -> phone_assistant_type = ai_assistant | ivr_menu | human | voicemail | no_answer
// | unclear). CRITICAL: the classifier decides by WHAT THE BUSINESS LINE SAYS (the words spoken),
// NOT by how natural/human the voice sounds — modern AI receptionists sound fully human, so voice
// tone is not a signal. If the line states/implies it is an AI, automated, or virtual
// assistant/receptionist -> ai_assistant. (Verified live on Skin Envy Austin: the line said
// "I'm actually an AI receptionist" — content-based prompt classifies ai_assistant; the earlier
// tone-based prompt wrongly returned human.) Emits phone_unanswered (voice_ai, when:true -> +15) +
// phone_probe_answered_by + phone_assistant_type evidence -> complete_analysis_work_item
// (cause 'phone_evidence' -> reuses phone_evidence->assessment rule -> re-score). No phone -> complete
// empty. Single execution (Wait+poll, no async callback fence). TwiML endpoint /leadgen-phone-twiml-ask
// is deployed by the on-demand probe (8JLoJMdcFY8ylhzI). Twilio auth via the n8n 'Twilio account'
// credential (twilioApi) — no inlined secret; SID in the URL redacted here (<<TWILIO_SID>>).
// REPORT: report-generator (LD2ujo15iFNfrhEM) renders a deterministic "How your phone is answered"
// block from phone_assistant_type; its Load query dedups evidence latest-per-feature (DISTINCT ON
// feature_key ORDER BY observed_at DESC) so appended corrections win.
//
// GATING: created 'blocked' at discovery (migration 140 adds 'phone_probe' to the service CHECK);
// the Scorer opens it on warm/hot (complete_scorer_work_item), skips otherwise. complete_analysis
// allowlist +'phone_probe'. Ships behind service_config.phone_probe.enabled — DISABLED by default
// because it places REAL outbound calls. Flip enabled=true to auto-probe warm leads:
//   UPDATE leadgen.service_config SET enabled=true WHERE service='phone_probe';
// COMPLIANCE (Level 3): this variant DOES speak a question and record the reply, so the recorded
// leg is retained only for classification. One probe per business; respect TCPA/DNC and two-party
// recording-consent law (the TwiML question makes the call's purpose plain). Twilio must be a Full
// (non-trial) account. Ships DISABLED by default; enable only where recording is permissible.
import { workflow, node, trigger, sticky, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

const everyMin = trigger({ type: 'n8n-nodes-base.scheduleTrigger', version: 1.3, config: { name: 'Poll Probe Queue', position: [200, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } }, output: [{}] });
const poke = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Probe Poke', position: [200, 440], parameters: { httpMethod: 'POST', path: 'leadgen-phone-probe-poke', responseMode: 'onReceived' } }, output: [{ body: {} }] });

const claim = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Claim Probe Work', position: [440, 320], executeOnce: true, parameters: { operation: 'executeQuery', query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id FROM leadgen.claim_work_items('phone_probe', $1)", options: { queryReplacement: expr('probe-{{ $execution.id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ work_item_id: 'wi', claim_token: 'ct', campaign_id: 'c', campaign_lead_id: 'l' }] });

const getTarget = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Get Target', position: [680, 320], parameters: { operation: 'executeQuery', query: "SELECT b.id AS business_id, b.business_name, b.phone_e164 FROM leadgen.campaign_leads cl JOIN leadgen.businesses b ON b.id=cl.business_id WHERE cl.id=$1", options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ business_id: 'b', phone_e164: '+15125550123' }] });

const hasPhone = ifElse({ version: 2.2, config: { name: 'Has Phone?', position: [900, 320], parameters: { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 }, combinator: 'and', conditions: [{ leftValue: expr('{{ $json.phone_e164 }}'), operator: { type: 'string', operation: 'notEmpty' } }] } } } });

// Level 3: Url points to the interactive /leadgen-phone-twiml-ask TwiML, which speaks the question
// and Records the answer (RecordingTrack='both'). Record=true + RecordingTrack on the Originate call
// too, so the callee's spoken reply is captured for the Classify Greeting node.
const originate = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Originate Call', position: [1140, 220], parameters: { method: 'POST', url: 'https://api.twilio.com/2010-04-01/Accounts/<<TWILIO_SID>>/Calls.json', authentication: 'predefinedCredentialType', nodeCredentialType: 'twilioApi', sendBody: true, contentType: 'form-urlencoded', bodyParameters: { parameters: [ { name: 'To', value: expr('={{ $json.phone_e164 }}') }, { name: 'From', value: '+18775094805' }, { name: 'Url', value: 'https://n8n.hiwebenterprise.com/webhook/leadgen-phone-twiml-ask' }, { name: 'Record', value: 'true' }, { name: 'RecordingTrack', value: 'both' }, { name: 'MachineDetection', value: 'Enable' }, { name: 'MachineDetectionTimeout', value: '15' }, { name: 'Timeout', value: '25' } ] }, options: {} }, credentials: { twilioApi: newCredential('Twilio account') } }, output: [{ sid: 'CA1' }] });

const waitCall = node({ type: 'n8n-nodes-base.wait', version: 1.1, config: { name: 'Wait for Call', position: [1360, 220], parameters: { resume: 'timeInterval', amount: 45, unit: 'seconds' } } });

const pollCall = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Poll Call', position: [1580, 220], parameters: { method: 'GET', url: expr("=https://api.twilio.com/2010-04-01/Accounts/<<TWILIO_SID>>/Calls/{{ $('Originate Call').item.json.sid }}.json"), authentication: 'predefinedCredentialType', nodeCredentialType: 'twilioApi', options: {} }, credentials: { twilioApi: newCredential('Twilio account') } }, output: [{ answered_by: 'human', status: 'completed' }] });

// Classify Greeting (deployed between Poll Call and Build Probe Evidence): fetches the Twilio
// recording (RecordingUrl.mp3, Twilio basic-auth), sends it to Gemini flash as inline audio
// (thinkingConfig.thinkingBudget:0) with a CONTENT-BASED prompt: "Decide based ONLY on WHAT THE
// BUSINESS LINE SAYS (the words spoken), NOT on how natural or human the voice sounds — modern AI
// receptionists sound fully human. If the business line states or implies it is an AI, automated,
// or virtual assistant/receptionist … answer ai_assistant …" -> phone_assistant_type ∈
// {ai_assistant, ivr_menu, human, voicemail, no_answer, unclear}. (Full node jsCode lives in the
// deployed workflow; audio-fetch + Gemini key are runtime-only and redacted from this archive.)
//
// Build Probe Evidence emits phone_unanswered (bool, voice_ai; true when line is AI/unanswered),
// phone_probe_answered_by (enum, from Twilio AMD), and phone_assistant_type (enum, from Classify).
const buildEv = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Build Probe Evidence', position: [1800, 220], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "const poll=$('Poll Call').item.json; const cls=$json; const claim=$('Claim Probe Work').item.json; const tgt=$('Get Target').item.json; const cid=claim.campaign_id, bid=tgt.business_id; const ab=(poll.answered_by||'').toString(); const status=(poll.status||'').toString(); const pat=(cls.phone_assistant_type||'unclear').toString(); const isAi=pat==='ai_assistant'; const unanswered=isAi||['voicemail','no_answer'].includes(pat); function mk(fk,val,vt){ return {feature_key:fk,value:val,value_type:vt,product_tag:'voice_ai',source_provider:'phone_probe',idempotency_key:cid+':'+bid+':'+fk}; } const ev=[ mk('phone_unanswered', unanswered, 'boolean'), mk('phone_probe_answered_by', (ab||'unknown'), 'enum'), mk('phone_assistant_type', pat, 'enum') ]; return { json:{ payload:{ cause_type:'phone_evidence', evidence:ev, run:{ workflow_version:'phone-probe-svc-v3', answered_by:ab, status:status, phone_assistant_type:pat } } } };" } }, output: [{ payload: {} }] });

// Classify Greeting — deployed node (full jsCode redacted: fetches Twilio recording + calls Gemini
// with the content-based prompt). Placeholder here mirrors its output shape for archive fidelity.
const classify = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Classify Greeting', position: [1690, 220], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "// REDACTED (runtime): fetch <<TWILIO recording>> mp3 (basic auth) -> Gemini flash inline audio,\n// content-based prompt (decide by WORDS spoken, not voice tone) -> phone_assistant_type.\nreturn { json:{ phone_assistant_type:'unclear' } };" } }, output: [{ phone_assistant_type: 'ai_assistant' }] });

const buildNoPhone = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'No Phone', position: [1140, 460], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "return { json:{ payload:{ cause_type:'phone_evidence', evidence:[], run:{ workflow_version:'phone-probe-svc-v1', skipped:'no_phone' } } } };" } }, output: [{ payload: {} }] });

const complete = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Complete Probe', position: [2040, 320], parameters: { operation: 'executeQuery', query: "=SELECT leadgen.complete_analysis_work_item('{{ $('Claim Probe Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Probe Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result", options: {} }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ result: {} }] });

const note = sticky('## Phone Probe Service V3 (warm-gated phone_probe, INTERACTIVE)\n\nClaim phone_probe -> Get phone -> Twilio call + AMD, TwiML /leadgen-phone-twiml-ask asks "AI or a real person?" + Records -> Wait 45s -> poll -> Classify Greeting (Gemini audio, decide by WORDS not voice tone) -> phone_assistant_type + phone_unanswered (voice_ai +15) + phone_probe_answered_by -> complete (cause phone_evidence) -> re-score. Report renders "How your phone is answered". Warm/hot gated. Ships DISABLED (real recorded calls). Twilio via the n8n credential.', [claim], { color: 6 });

export default workflow('leadgen-phone-probe-service', 'Leadgen — Phone Probe Service')
  .add(everyMin).to(claim)
  .add(poke).to(claim)
  .add(claim).to(getTarget).to(hasPhone.onTrue(originate.to(waitCall).to(pollCall).to(classify).to(buildEv).to(complete)).onFalse(buildNoPhone.to(complete)))
  .add(note);
