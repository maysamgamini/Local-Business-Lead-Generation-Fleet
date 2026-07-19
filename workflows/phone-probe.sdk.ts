// Leadgen — Phone Probe (Phone Presence V2, on-demand active probe). Deployed: 8JLoJMdcFY8ylhzI.
// POST {to:'+1...'} -> originate a Twilio call with Answering-Machine-Detection -> Wait 45s ->
// poll the Call resource for answered_by -> classify how the business handles calls:
//   human           -> a person answered live (lower AI-receptionist need)
//   machine_*        -> voicemail/machine (AI receptionist / missed-call-capture opportunity)
//   fax / unknown    -> fax / no clear answer (possible missed-call pain)
// TwiML just <Pause length=12/> then <Hangup/> — NO speech, NO recording (lowest compliance
// footprint; a passive listen-and-classify probe, not a conversation).
//
// COMPLIANCE: automated outbound calls touch TCPA + state recording law. This probe does not
// record and does not play a message; keep it to one short probe per business and respect DNC.
// Twilio account must be UPGRADED from trial (trial can only dial verified numbers).
//
// SECRETS redacted here: <<TWILIO_SID>> in the Account URLs, <<TWILIO_AUTH>> = Basic
// base64(AccountSID:AuthToken) on the deployed instance. Caller ID From = +18775094805.
//
// v1 is ON-DEMAND (webhook), returns the classification but does NOT write scoring evidence
// (evidence_items.service_run_id is NOT NULL, so scoring evidence needs the work-queue). v2:
// promote to a warm-gated `phone_probe` fleet service (migration + gate + poll-worker) that
// completes a work item and writes phone_evidence on the same contract Phone Presence V1 uses.
import { workflow, node, trigger, sticky, expr } from '@n8n/workflow-sdk';

const probeTrigger = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Probe Trigger', position: [200, 200], parameters: { httpMethod: 'POST', path: 'leadgen-phone-probe', responseMode: 'lastNode' } }, output: [{ body: { to: '+15125550123' } }] });

const originate = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Originate Call', position: [440, 200], parameters: { method: 'POST', url: 'https://api.twilio.com/2010-04-01/Accounts/<<TWILIO_SID>>/Calls.json', sendHeaders: true, headerParameters: { parameters: [ { name: 'Authorization', value: '<<TWILIO_AUTH>>' } ] }, sendBody: true, contentType: 'form-urlencoded', bodyParameters: { parameters: [ { name: 'To', value: expr('={{ $json.body.to }}') }, { name: 'From', value: '+18775094805' }, { name: 'Url', value: 'https://n8n.hiwebenterprise.com/webhook/leadgen-phone-twiml' }, { name: 'MachineDetection', value: 'Enable' }, { name: 'MachineDetectionTimeout', value: '15' }, { name: 'Timeout', value: '25' } ] }, options: {} } }, output: [{ sid: 'CA123' }] });

const wait = node({ type: 'n8n-nodes-base.wait', version: 1.1, config: { name: 'Wait for Call', position: [680, 200], parameters: { resume: 'timeInterval', amount: 45, unit: 'seconds' } } });

const pollCall = node({ type: 'n8n-nodes-base.httpRequest', version: 4.4, config: { name: 'Poll Call', position: [920, 200], parameters: { method: 'GET', url: expr("=https://api.twilio.com/2010-04-01/Accounts/<<TWILIO_SID>>/Calls/{{ $('Originate Call').item.json.sid }}.json"), sendHeaders: true, headerParameters: { parameters: [ { name: 'Authorization', value: '<<TWILIO_AUTH>>' } ] }, options: {} } }, output: [{ answered_by: 'human', status: 'completed', duration: '20' }] });

const respond = node({ type: 'n8n-nodes-base.set', version: 3.4, config: { name: 'Result', position: [1160, 200], parameters: { mode: 'raw', includeOtherFields: false, jsonOutput: expr("={{ { \"to\": $('Originate Call').item.json.to, \"answered_by\": ($json.answered_by || 'unknown'), \"status\": $json.status, \"duration_s\": Number($json.duration || 0), \"interpretation\": ($json.answered_by === 'human' ? 'A person answered live — lower AI-receptionist need.' : (($json.answered_by || '').indexOf('machine') === 0 ? 'Went to a machine/voicemail — AI receptionist / missed-call-capture opportunity.' : ($json.answered_by === 'fax' ? 'Fax line.' : 'No clear answer (no-answer/busy/undetected) — possible missed-call pain.'))) } }}") } }, output: [{}] });

const twimlHook = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'TwiML', position: [200, 420], parameters: { httpMethod: 'POST', path: 'leadgen-phone-twiml', responseMode: 'responseNode' } }, output: [{}] });

const twimlResp = node({ type: 'n8n-nodes-base.respondToWebhook', version: 1.1, config: { name: 'TwiML Response', position: [440, 420], parameters: { respondWith: 'text', responseBody: '<?xml version="1.0" encoding="UTF-8"?><Response><Pause length="12"/><Hangup/></Response>', options: { responseHeaders: { entries: [ { name: 'Content-Type', value: 'application/xml' } ] } } } } });

const note = sticky('## Phone Probe (Phone Presence V2, on-demand)\n\nPOST {to} -> Twilio call + Answering-Machine-Detection -> Wait 45s -> poll answered_by -> classify (human / machine-voicemail / fax / no-answer). TwiML pauses 12s then hangs up (no speech, no recording). Twilio must be upgraded from trial. v2: warm-gated phone_probe service writing phone_evidence.', [originate], { color: 6 });

export default workflow('leadgen-phone-probe', 'Leadgen — Phone Probe')
  .add(probeTrigger).to(originate).to(wait).to(pollCall).to(respond)
  .add(twimlHook).to(twimlResp)
  .add(note);
