// Leadgen — Scorer (deployed instance: r0K3xkLN2XtUceTF)
// US1 T040: reactive deterministic scoring. Claim -> load pinned scoring_config +
// confirmed evidence + contact/analyzer state (one query) -> compute fits +
// opportunity/contactability/confidence (Code) -> complete_scorer_work_item.
// Verified via test_workflow (exec 728): discovery-only lead -> ads_video 45,
// opportunity 49.75 -> cold, every point traced to a score_component. Hot
// structurally impossible without resolved critic + AND-gate.
//
// TUNING 2026-07-18: (a) warm threshold lowered 60 -> 45 (opportunity>=45 warm,
//   40-45 cold, <40 disqualified) — established verticals (HVAC etc.) score in the
//   45-55 band and are legit warm leads. (b) DOMAIN MEMORABILITY signal: a long/
//   unmemorable domain is a branding weakness -> +25 fit_web_seo (traceable score
//   component domain_hard_to_recall, evidence_id null like consulting derived feats).
//   Heuristic on the registrable label (protocol/www/path/TLD stripped): >=20 alpha
//   chars OR contains a hyphen/digit. Loads b.website_domain into the scorer. Both
//   thresholds + the opportunity formula are hardcoded HERE, not read from
//   scoring_config (the config rows are documentation of intent).
//
// Evidence rule: counts unless latest verification event is rejected/superseded/
// disputed (deterministic provider facts have no event and count; quote-checker
// rejections do not). Interpretation of the "only confirmed scores" contract for
// deterministic-fact analyzers that don't emit verification events.
import { workflow, node, trigger, sticky, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Poll Assessment Queue', position: [220, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } },
  output: [{}]
});

const pokeWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: { name: 'Scorer Poke', position: [220, 460], parameters: { httpMethod: 'POST', path: 'leadgen-scorer-poke', responseMode: 'onReceived' } },
  output: [{ body: {} }]
});

const claimWork = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Claim Assessment Work',
    position: [520, 340],
    executeOnce: true,
    parameters: {
      operation: 'executeQuery',
      query: "SELECT work_item_id, claim_token, service_run_id, campaign_id, campaign_lead_id, processing_version FROM leadgen.claim_work_items('assessment', $1)",
      options: { queryReplacement: expr('scorer-{{ $execution.id }}') }
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ work_item_id: 'wi1', claim_token: 'ct1', service_run_id: 'sr1', campaign_id: 'c1', campaign_lead_id: 'l1', processing_version: 2 }]
});

const loadInputs = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Load Scoring Inputs',
    position: [860, 340],
    parameters: {
      operation: 'executeQuery',
      query: "WITH lead AS ( SELECT cl.id lead_id, cl.campaign_id, cl.business_id, cl.lead_revision, cl.classification, cl.critic_state, c.scoring_config_set_id csid, c.business_type, c.requires_approval, c.approval_status, b.website_domain FROM leadgen.campaign_leads cl JOIN leadgen.campaigns c ON c.id=cl.campaign_id JOIN leadgen.businesses b ON b.id=cl.business_id WHERE cl.id=$1 ), latest_ev AS ( SELECT DISTINCT ON (ei.feature_key) ei.feature_key, ei.value_jsonb val, ei.id evidence_id, ei.observed_at, (SELECT ve.status FROM leadgen.evidence_verification_events ve WHERE ve.evidence_id=ei.id ORDER BY ve.verified_at DESC, ve.id DESC LIMIT 1) vstatus FROM leadgen.evidence_items ei, lead WHERE ei.business_id=lead.business_id AND ei.campaign_id=lead.campaign_id ORDER BY ei.feature_key, ei.observed_at DESC ), ev AS ( SELECT coalesce(jsonb_object_agg(feature_key, jsonb_build_object('value',val,'evidence_id',evidence_id)) FILTER (WHERE vstatus IS NULL OR vstatus='confirmed'), '{}') evidence, count(*) FILTER (WHERE vstatus IS NULL OR vstatus='confirmed') n_conf, count(*) FILTER (WHERE observed_at > now()-interval '365 days' AND (vstatus IS NULL OR vstatus='confirmed')) n_recent FROM latest_ev ), cfg AS ( SELECT coalesce(jsonb_agg(jsonb_build_object('product',product,'feature_key',feature_key,'transform_type',transform_type,'direction',direction,'input_min',input_min,'input_max',input_max,'weight',weight,'point_cap',point_cap,'step_map',step_map,'missing_policy',missing_policy)), '[]') cfg FROM leadgen.scoring_config sc, lead WHERE sc.config_set_id=lead.csid AND (sc.business_type IS NULL OR sc.business_type=lead.business_type) ), ct AS ( SELECT count(*) FILTER (WHERE crv.status='attested' AND crv.expires_at>now()) roles_attested, count(*) FILTER (WHERE ccv.status='deliverable' AND ccv.expires_at>now()) emails_ok FROM lead LEFT JOIN leadgen.contact_business_links cbl ON cbl.business_id=lead.business_id LEFT JOIN leadgen.contact_role_verifications crv ON crv.contact_business_link_id=cbl.id LEFT JOIN leadgen.contact_channels cc ON cc.contact_id=cbl.contact_id LEFT JOIN leadgen.contact_channel_verifications ccv ON ccv.contact_channel_id=cc.id ), analyzers AS ( SELECT count(*) total, count(*) FILTER (WHERE state IN ('done','dead','skipped_gate','skipped_budget','skipped_prerequisite','canceled')) terminal FROM leadgen.work_items w, lead WHERE w.campaign_lead_id=lead.lead_id AND w.service IN ('website','reviews','phone') ) SELECT to_jsonb(lead)-'csid' lead, ev.evidence, ev.n_conf, ev.n_recent, cfg.cfg config, ct.roles_attested, ct.emails_ok, analyzers.total analyzers_total, analyzers.terminal analyzers_terminal FROM lead, ev, cfg, ct, analyzers",
      options: { queryReplacement: expr('{{ $json.campaign_lead_id }}') }
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ lead: { lead_id: 'l1', business_type: 'med spa', lead_revision: 2, critic_state: null, requires_approval: true, approval_status: 'pending' }, evidence: {}, n_conf: 4, n_recent: 4, config: [], roles_attested: 0, emails_ok: 0, analyzers_total: 3, analyzers_terminal: 1 }]
});

const computeScores = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Compute Scores',
    position: [1200, 340],
    parameters: {
      mode: 'runOnceForEachItem',
      language: 'javaScript',
      jsCode: "const row = $json;\nconst ev = row.evidence || {};\nconst cfg = row.config || [];\nconst lead = row.lead || {};\nfunction num(v){ const n = Number(v); return isFinite(n) ? n : null; }\nfunction evVal(k){ return ev[k] ? ev[k].value : undefined; }\nfunction evId(k){ return ev[k] ? ev[k].evidence_id : null; }\nfunction clamp(x){ return Math.max(0, Math.min(100, x)); }\nfunction applyTransform(c, raw){ const cap = c.point_cap!=null?Number(c.point_cap):100; const w = c.weight!=null?Number(c.weight):1; const sm = c.step_map||{};\n  if(raw===undefined||raw===null){ return c.missing_policy==='neutral_points'? {pts: cap*0.3, tv:null} : {pts:0, tv:null}; }\n  if(c.transform_type==='boolean_points'){ let hit=false; const rv=raw; if('when' in sm){ hit = (rv===sm.when); } if('when_lt' in sm){ hit = num(rv)!=null && num(rv)<sm.when_lt; } if('when_gte' in sm){ hit = num(rv)!=null && num(rv)>=sm.when_gte; } const pts = hit ? (sm.points!=null?sm.points:cap) : 0; return {pts: Math.min(pts,cap), tv: hit?1:0}; }\n  if(c.transform_type==='linear'){ const mn=Number(c.input_min||0), mx=Number(c.input_max||1); const x=num(raw); if(x==null) return {pts:0,tv:null}; const frac=Math.max(0,Math.min(1,(x-mn)/((mx-mn)||1))); return {pts: clamp(frac*cap), tv:frac}; }\n  if(c.transform_type==='inverse_linear'){ const mn=Number(c.input_min||0), mx=Number(c.input_max||100); const x=num(raw); if(x==null) return {pts:0,tv:null}; const frac=Math.max(0,Math.min(1,(x-mn)/((mx-mn)||1))); return {pts: clamp((1-frac)*cap), tv:1-frac}; }\n  if(c.transform_type==='log'){ const mn=Number(c.input_min||1), mx=Number(c.input_max||100); const x=num(raw); if(x==null||x<=0) return {pts:0,tv:0}; const lf=Math.max(0,Math.min(1,(Math.log(x)-Math.log(mn))/((Math.log(mx)-Math.log(mn))||1))); return {pts: clamp(lf*cap), tv:lf}; }\n  if(c.transform_type==='step'){ const x=num(raw); if(x==null) return {pts:0,tv:null}; if(sm.map && (raw in sm.map)){ return {pts: Math.min(sm.map[raw],cap), tv:null}; } if(Array.isArray(sm.steps)){ for(const s of sm.steps){ if(('gt' in s)&&x>s.gt) return {pts:Math.min(s.points,cap),tv:null}; if(('gte' in s)&&x>=s.gte) return {pts:Math.min(s.points,cap),tv:null}; if(('lte' in s)&&x<=s.lte) return {pts:Math.min(s.points,cap),tv:null}; } } return {pts:0,tv:null}; }\n  return {pts:0, tv:null}; }\nconst fits = { web_seo:0, voice_ai:0, ads_video:0, consulting:0 };\nconst components = [];\nfor(const c of cfg){ if(!(c.product in fits)) continue; const raw = evVal(c.feature_key); const r = applyTransform(c, raw); if(r.pts>0){ fits[c.product]+=r.pts; components.push({ product:c.product, feature_key:c.feature_key, observed_value: raw===undefined?null:raw, transformed_value: r.tv, weight: c.weight!=null?Number(c.weight):1, points: r.pts, evidence_id: evId(c.feature_key) }); } }\nfor(const k in fits){ fits[k]=clamp(fits[k]); }\nconst dom=(lead.website_domain||'').toString().toLowerCase().trim();\nlet dlabel=dom; if(dlabel.indexOf('//')>=0) dlabel=dlabel.split('//')[1]; if(dlabel.indexOf('www.')===0) dlabel=dlabel.slice(4); dlabel=dlabel.split('/')[0].split('?')[0]; const ddot=dlabel.lastIndexOf('.'); if(ddot>0) dlabel=dlabel.slice(0,ddot);\nlet dalpha=''; let dHyphenDigit=false; for(let di=0; di<dlabel.length; di++){ const dch=dlabel[di]; if(dch>='a'&&dch<='z') dalpha+=dch; if(dch==='-'||(dch>='0'&&dch<='9')) dHyphenDigit=true; }\nconst hardDomain = dom!=='' && (dalpha.length>=20 || dHyphenDigit);\nif(hardDomain){ const dp=25; fits.web_seo=clamp(fits.web_seo+dp); components.push({ product:'web_seo', feature_key:'domain_hard_to_recall', observed_value:dlabel, transformed_value:1, weight:1, points:dp, evidence_id:null }); }\nconst midband = ['web_seo','voice_ai','ads_video'].filter(k=> fits[k]>=40 && fits[k]<=70).length;\nfor(const c of cfg){ if(c.product!=='consulting') continue; let raw; if(c.feature_key==='fits_in_midband_count') raw=midband; else raw=evVal(c.feature_key); const r=applyTransform(c, raw); if(r.pts>0){ fits.consulting+=r.pts; components.push({ product:'consulting', feature_key:c.feature_key, observed_value: raw===undefined?null:raw, transformed_value:r.tv, weight:c.weight!=null?Number(c.weight):1, points:r.pts, evidence_id:null }); } }\nfits.consulting=clamp(fits.consulting);\nconst fitVals=[fits.web_seo,fits.voice_ai,fits.ads_video,fits.consulting].sort((a,b)=>b-a);\nlet opportunity = 0.55*fitVals[0] + 0.15*fitVals[1];\nconst catMatch = 15; opportunity += catMatch;\nconst reviewVol = num(evVal('review_volume'))||0; if(reviewVol>=25) opportunity+=10;\nopportunity=clamp(opportunity);\nconst rolesAttested=Number(row.roles_attested)||0; const emailsOk=Number(row.emails_ok)||0;\nlet contactability = (rolesAttested>0?40:0)+(emailsOk>0?40:0); contactability=clamp(contactability);\nconst total=Number(row.analyzers_total)||3; const term=Number(row.analyzers_terminal)||0; const completeness = total>0? term/total : 0;\nconst nConf=Number(row.n_conf)||0; const nRecent=Number(row.n_recent)||0;\nlet confidence = 40*completeness + Math.min(30, nConf*1.5) + (nConf>0 && nRecent/nConf>=0.6?20:0); confidence=clamp(confidence);\nconst analysisTerminal = term>=total;\nconst hotCandidate = opportunity>=75 && confidence>=60;\nlet classification='disqualified'; if(opportunity>=45) classification='warm'; if(opportunity>=40 && opportunity<45) classification='cold'; if(opportunity<40) classification='disqualified';\nlet finalClass=classification; let openCritic=false;\nif(opportunity>=75 && contactability>=60 && confidence>=60){ if(lead.critic_state==='resolved'){ finalClass='hot'; } else { finalClass='warm'; openCritic=(lead.critic_state==null); } }\nconst bestFitKey = ['web_seo','voice_ai','ads_video','consulting'].reduce((a,b)=> fits[b]>fits[a]?b:a, 'web_seo');\nconst enrichGatePassed = opportunity>=60;\nconst payload = { assessment: { scoring_version:'scoring-v1', fit_web_seo:fits.web_seo, fit_voice_ai:fits.voice_ai, fit_ads_video:fits.ads_video, fit_consulting:fits.consulting, opportunity:opportunity, contactability:contactability, confidence:confidence, completeness:completeness, best_angle:bestFitKey }, components, classification:{ value:finalClass, reason:'opp='+opportunity.toFixed(0)+' contact='+contactability.toFixed(0)+' conf='+confidence.toFixed(0) }, hot_candidate:hotCandidate, open_critic:openCritic, critic_type:'hot_lead', enrichment_gate_passed:enrichGatePassed, analysis_terminal:analysisTerminal, change_reason:'recompute@rev'+lead.lead_revision, run:{ workflow_version:'scorer-v1' } };\nreturn { json: { payload } };"
    }
  },
  output: [{ payload: {} }]
});

const complete = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Complete Scorer',
    position: [1540, 340],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT leadgen.complete_scorer_work_item('{{ $('Claim Assessment Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Assessment Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ result: { result: 'done', published: true } }]
});

const scoreNote = sticky(
  '## Scorer (US1, T040)\n\nReactive deterministic scoring. Claim assessment work -> load pinned scoring_config + confirmed evidence + contact/analyzer state (one query) -> compute 4 fits + opportunity/contactability/confidence in the Code node (every point -> a score_component) -> complete_scorer_work_item (publication rule, classification, hot_candidate, critic open, enrichment-gate resolution).\n\n**Evidence rule**: counts unless its latest verification event is rejected/superseded/disputed — deterministic provider facts (no event) count; quote-checker rejections do not.\n\nHot is never set here directly — it needs a resolved critic + full AND-gate (enforced again in the SQL function). US1 leads reach warm + hot_candidate at most.',
  [loadInputs, computeScores],
  { color: 6 }
);

export default workflow('leadgen-scorer', 'Leadgen — Scorer')
  .add(everyMinute)
  .to(claimWork)
  .to(loadInputs)
  .to(computeScores)
  .to(complete)
  .add(pokeWebhook)
  .to(claimWork)
  .add(scoreNote);
