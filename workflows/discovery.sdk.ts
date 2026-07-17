// Leadgen — Discovery (deployed instance: bGlPRpKMRxnnxPm3)
// US1 T033: campaign-scoped fenced worker. Places + SerpApi -> merge/dedup/rank/
// relationship-detect (Code) -> commit_discovery_results (single fenced transaction).
// Transform verified via test_workflow (execution 703): ranking, franchise
// relationship detection, no-website signal, typed evidence all correct.
import { workflow, node, trigger, sticky, merge, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Poll Discovery Queue', position: [220, 240], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } } },
  output: [{}]
});

const pokeWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: { name: 'Discovery Poke', position: [220, 460], parameters: { httpMethod: 'POST', path: 'leadgen-discovery-poke', responseMode: 'onReceived' } },
  output: [{ body: {} }]
});

const claimWork = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Claim Discovery Work',
    position: [520, 340],
    executeOnce: true,
    parameters: {
      operation: 'executeQuery',
      query: "SELECT work_item_id, claim_token, service_run_id, campaign_id FROM leadgen.claim_work_items('discovery', $1)",
      options: { queryReplacement: expr('discovery-{{ $execution.id }}') }
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ work_item_id: 'wi1', claim_token: 'ct1', service_run_id: 'sr1', campaign_id: 'camp1' }]
});

const getCampaign = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Get Campaign',
    position: [820, 340],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT id, business_type, geo_type, geo_original, geo_radius_m, depth, volume_cap, exclusions, dry_run FROM leadgen.campaigns WHERE id = $1",
      options: { queryReplacement: expr('{{ $json.campaign_id }}') }
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ id: 'camp1', business_type: 'med spa', geo_type: 'zip', geo_original: { type: 'zip', zip: '78613', radius_m: 15000 }, geo_radius_m: 15000, depth: 'quick', volume_cap: 10, exclusions: { domains: [], names: [] }, dry_run: false }]
});

const placesSearch = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Places Search',
    position: [1120, 240],
    onError: 'continueRegularOutput',
    parameters: {
      method: 'POST',
      url: 'https://places.googleapis.com/v1/places:searchText',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpHeaderAuth',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [ { name: 'X-Goog-FieldMask', value: 'places.id,places.displayName,places.websiteUri,places.nationalPhoneNumber,places.formattedAddress,places.location,places.userRatingCount,places.rating,places.photos,places.primaryType' } ] },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ { "textQuery": $json.business_type + " near " + ($json.geo_original.zip || $json.geo_original.city || ""), "pageSize": Math.min(20, Number($json.volume_cap)), "maxResultCount": Math.min(20, Number($json.volume_cap)) } }}')
    },
    credentials: { httpHeaderAuth: newCredential('Google Places API') }
  },
  output: [{ places: [] }]
});

const serpSearch = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'SerpApi Maps Search',
    position: [1120, 460],
    onError: 'continueRegularOutput',
    parameters: {
      method: 'GET',
      url: 'https://serpapi.com/search.json',
      authentication: 'predefinedCredentialType',
      nodeCredentialType: 'serpApi',
      sendQuery: true,
      specifyQuery: 'keypair',
      queryParameters: { parameters: [
        { name: 'engine', value: 'google_maps' },
        { name: 'type', value: 'search' },
        { name: 'q', value: expr('{{ $("Get Campaign").item.json.business_type }} near {{ $("Get Campaign").item.json.geo_original.zip || $("Get Campaign").item.json.geo_original.city || "" }}') }
      ] }
    },
    credentials: { serpApi: newCredential('SerpApi account') }
  },
  output: [{ local_results: [] }]
});

const combine = merge({
  version: 3.2,
  config: { name: 'Combine Sources', position: [1420, 340], parameters: { mode: 'combine', combineBy: 'combineByPosition' } }
});

const buildPayload = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Merge Dedup Rank',
    position: [1720, 340],
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: "const campaign = $('Get Campaign').first().json;\nconst excl = new Set(((campaign.exclusions && campaign.exclusions.domains) || []));\nconst cap = Number(campaign.volume_cap) || 25;\nconst zipOrCity = (campaign.geo_original.zip || campaign.geo_original.city || '');\nconst merged = $input.first().json;\nconst places = merged.places || [];\nconst serp = merged.local_results || [];\nfunction domainOf(u){ if(!u) return ''; let s=String(u).toLowerCase(); s=s.split('://').pop(); if(s.indexOf('www.')===0) s=s.slice(4); return s.split('/')[0]; }\nfunction onlyDigits(p){ let out=''; for(const c of String(p||'')){ if(c>='0'&&c<='9') out+=c; } return out; }\nfunction normPhone(p){ const d=onlyDigits(p); if(d.length===10) return '+1'+d; if(d.length===11) return '+'+d; return d? '+'+d : ''; }\nfunction slug(n){ let out=''; for(const c of String(n||'').toLowerCase()){ out += ((c>='a'&&c<='z')||(c>='0'&&c<='9'))?c:'-'; } return out; }\nconst rankByPlace = {};\nserp.forEach((r,i)=>{ if(r.place_id) rankByPlace[r.place_id]=r.position||(i+1); });\nconst byId = {};\nfor (const p of places){ const domain=domainOf(p.websiteUri); const name=(p.displayName&&p.displayName.text)||p.name||'Unknown'; byId[p.id]={ place_id:p.id, name, domain, phone_e164:normPhone(p.nationalPhoneNumber), address:p.formattedAddress||'', lat:p.location&&p.location.latitude, lng:p.location&&p.location.longitude, dedup_key:(domain||slug(name))+'|'+zipOrCity, rating:p.rating||null, review_count:p.userRatingCount||0, photo_count:(p.photos||[]).length, serp_rank:rankByPlace[p.id]||null }; }\nlet rows = Object.values(byId).filter(r => !r.domain || !excl.has(r.domain));\nrows.sort((a,b)=> (b.review_count*(b.rating||1)) - (a.review_count*(a.rating||1)) );\nrows = rows.slice(0, cap);\nconst groups = {};\nrows.forEach(r=>{ if(r.domain){ (groups[r.domain]=groups[r.domain]||[]).push(r.place_id); } });\nconst businesses = rows.map(r=>{ const rels=[]; if(r.domain && groups[r.domain].length>1){ for(const o of groups[r.domain]){ if(o!==r.place_id) rels.push({ related_place_id:o, type:'shared_platform', confidence:0.5, target_level:'location' }); } } const evidence=[ { feature_key:'website_present', value:!!r.domain, value_type:'boolean', product_tag:'web_seo', source_provider:'discovery', idempotency_key:campaign.id+':'+r.place_id+':website_present' }, { feature_key:'review_volume', value:r.review_count, value_type:'integer', unit:'count', product_tag:'ads_video', source_provider:'discovery', idempotency_key:campaign.id+':'+r.place_id+':review_volume' }, { feature_key:'rating', value:r.rating, value_type:'decimal', product_tag:'ads_video', source_provider:'discovery', idempotency_key:campaign.id+':'+r.place_id+':rating' }, { feature_key:'photo_asset_count', value:r.photo_count, value_type:'integer', unit:'count', product_tag:'ads_video', source_provider:'discovery', idempotency_key:campaign.id+':'+r.place_id+':photo_count' } ]; const observations = r.serp_rank ? [{ provider:'serpapi', query:campaign.business_type, rank:r.serp_rank }] : []; return { place_id:r.place_id, name:r.name, domain:r.domain, phone_e164:r.phone_e164, address:r.address, lat:r.lat, lng:r.lng, dedup_key:r.dedup_key, priority:Math.round(r.review_count/10), evidence, observations, relationships:rels }; });\nconst geo = { lat: rows[0] && rows[0].lat, lng: rows[0] && rows[0].lng };\nreturn [{ json: { payload: { geo, resolved_category:campaign.business_type, businesses, run:{ workflow_version:'discovery-v1' } } } }];"
    }
  },
  output: [{ payload: { geo: {}, businesses: [] } }]
});

const commit = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Commit Discovery',
    position: [2020, 340],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT leadgen.commit_discovery_results('{{ $('Claim Discovery Work').item.json.campaign_id }}'::uuid, '{{ $('Claim Discovery Work').item.json.work_item_id }}'::uuid, '{{ $('Claim Discovery Work').item.json.claim_token }}'::uuid, '{{ JSON.stringify($json.payload).replace(/'/g, \"''\") }}'::jsonb) AS result")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ result: { result: 'done', leads_created: 8 } }]
});

const discNote = sticky(
  '## Discovery (US1, T033)\n\nCampaign-scoped fenced worker: claim -> load campaign -> Places + SerpApi (parallel, combined by position) -> merge/dedup/rank/relationship-detect (Code) -> commit_discovery_results (single fenced transaction).\n\n**Credentials**: "Google Places API" (HTTP Header Auth: name X-Goog-Api-Key, value = your key), "SerpApi account" (SerpApi). Ledger-level provider_limits self-throttle both.\n\n**Dry-run**: pin Places + SerpApi nodes with fixtures/places/*.json.\n\nRanking = review_count x rating. Shared-domain -> typed shared_platform relationship (not a merge). Places 20/page cap (verified T007).',
  [claimWork, placesSearch, buildPayload],
  { color: 5 }
);

export default workflow('leadgen-discovery', 'Leadgen — Discovery')
  .add(everyMinute)
  .to(claimWork)
  .to(getCampaign)
  .to(placesSearch.to(combine.input(0)))
  .add(getCampaign)
  .to(serpSearch.to(combine.input(1)))
  .add(combine)
  .to(buildPayload)
  .to(commit)
  .add(pokeWebhook)
  .to(claimWork)
  .add(discNote);
