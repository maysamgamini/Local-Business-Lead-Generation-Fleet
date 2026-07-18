// Leadgen — Phone Presence (US1 T039). Deploy via create_workflow_from_code.
// V1 PASSIVE analyzer (no telephony provider): derives a phone_pain_score (0-1)
// from EXISTING review-mined evidence — phone_complaint_share, low owner_response_rate,
// high-severity voice_ai complaint themes, declining trajectory — and links it back to
// those review evidence roots (relationship_type='derived_from') so the Scorer's
// count_roots_only policy never double-counts the same pain. Producer of voice_ai's
// biggest driver (phone_pain_score, 40 pts) + ai_receptionist_likelihood.
// Dependency: the 'phone' work item is created blocked and unblocks only after website
// + reviews are terminal (complete_analysis_work_item), so the review inputs exist.
// V2 (probe-caller) swaps in later on the SAME contract. No external secrets.
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({ type: 'n8n-nodes-base.scheduleTrigger', version: 1.3, config: { name: 'Poll Phone Queue', position: [200, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } }, output: [{}] });
const poke = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Phone Poke', position: [200, 440], parameters: { httpMethod: 'POST', path: 'leadgen-phone-poke', responseMode: 'onReceived' } }, output: [{ body: {} }] });

const claim = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Claim Phone Work', position: [460, 320], executeOnce: true, parameters: { operation: 'executeQuery', query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id FROM leadgen.claim_work_items('phone', $1)", options: { queryReplacement: expr('phone-{{ $execution.id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ work_item_id: 'wi', claim_token: 'ct', campaign_id: 'c', campaign_lead_id: 'l' }] });

// Load the lead's review-derived evidence (value + evidence id, for lineage links).
const loadInputs = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Load Phone Inputs', position: [720, 320], parameters: { operation: 'executeQuery', query: "SELECT cl.business_id, cl.campaign_id, coalesce(jsonb_object_agg(ei.feature_key, jsonb_build_object('value', ei.value_jsonb, 'id', ei.id)) FILTER (WHERE ei.feature_key IS NOT NULL), '{}'::jsonb) AS ev FROM leadgen.campaign_leads cl LEFT JOIN leadgen.evidence_items ei ON ei.business_id=cl.business_id AND ei.campaign_id=cl.campaign_id AND ei.feature_key IN ('phone_complaint_share','owner_response_rate','complaint_themes','review_trajectory','rating','review_volume') WHERE cl.id=$1 GROUP BY cl.business_id, cl.campaign_id", options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') } }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ business_id: 'b', campaign_id: 'c', ev: {} }] });

const computePain = node({ type: 'n8n-nodes-base.code', version: 2, config: { name: 'Compute Phone Pain', position: [980, 320], parameters: { mode: 'runOnceForEachItem', language: 'javaScript', jsCode: "const row=$json; const ev=row.ev||{}; const cid=row.campaign_id, bid=row.business_id; function num(o){ return (o&&o.value!=null)?Number(o.value):null; } const pcs=num(ev.phone_complaint_share); const orr=num(ev.owner_response_rate); const traj=num(ev.review_trajectory); let highVoice=false; try{ const ct=ev.complaint_themes&&ev.complaint_themes.value; const themes=(ct&&ct.themes)||[]; highVoice=themes.some(t=>t && t.product_tag==='voice_ai' && (t.severity==='high'||t.severity==='med')); }catch(e){} let pain=0; const roots=[]; if(pcs!=null){ pain += Math.min(0.6, pcs*5); if(ev.phone_complaint_share&&ev.phone_complaint_share.id) roots.push(ev.phone_complaint_share.id); } if(orr!=null && orr<0.2){ pain += 0.25; if(ev.owner_response_rate&&ev.owner_response_rate.id) roots.push(ev.owner_response_rate.id); } if(highVoice){ pain += 0.2; if(ev.complaint_themes&&ev.complaint_themes.id) roots.push(ev.complaint_themes.id); } if(traj!=null && traj < -0.3){ pain += 0.1; } pain = Math.max(0, Math.min(1, +pain.toFixed(3))); const likelihood = pain>=0.5?'high':(pain>=0.25?'medium':'low'); const links = roots.map(id=>({parent_evidence_id:id, relationship_type:'derived_from'})); const out=[ {feature_key:'phone_pain_score', value:pain, value_type:'decimal', product_tag:'voice_ai', source_provider:'phone_presence', calculation_version:'phone-v1', idempotency_key:cid+':'+bid+':phone_pain_score', links}, {feature_key:'ai_receptionist_likelihood', value:likelihood, value_type:'enum', product_tag:'voice_ai', source_provider:'phone_presence', idempotency_key:cid+':'+bid+':ai_receptionist_likelihood'} ]; return { json:{ payload:{ cause_type:'phone_evidence', evidence:out, run:{ workflow_version:'phone-presence-v1' } } } };" } }, output: [{ payload: {} }] });

const complete = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Complete Phone', position: [1240, 320], parameters: { operation: 'executeQuery', query: "SELECT leadgen.complete_analysis_work_item('{{ $('Claim Phone Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Phone Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result", options: {} }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ result: {} }] });

const note = sticky('## Phone Presence (US1 T039, V1 passive)\n\nDerives phone_pain_score (0-1) + ai_receptionist_likelihood from review-mined evidence (phone_complaint_share, owner_response_rate<0.2, high-severity voice_ai themes, declining trajectory) and links it to those review roots (derived_from) so count_roots_only never double-counts. Unblocks after website+reviews terminal. No telephony provider (V2 probe-caller swaps in on the same contract).', [claim], { color: 6 });

export default workflow('leadgen-phone-presence', 'Leadgen — Phone Presence')
  .add(everyMinute).to(claim)
  .add(poke).to(claim)
  .add(claim).to(loadInputs).to(computePain).to(complete)
  .add(note);
