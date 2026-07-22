import reportGenWf from '../workflows/report-generator.sdk.js';
import competitorsWf from '../workflows/competitors-gap.sdk.js';
import websiteAuditorWf from '../workflows/website-auditor.sdk.js';
import adsVerificationWf from '../workflows/ads-verification.sdk.js';
import phoneProbeWf from '../workflows/phone-probe-service.sdk.js';
import opsConsoleWf from '../workflows/ops-console.sdk.js';

const API_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJiYzNiOTJkYi0wNTI0LTQ0NTMtYjczOC03NTRiNjQ4NzdkNzEiLCJpc3OiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwianRpIjoiYTA3OWRlYzItNjUyMi00MTE1LWExYjktYWUwZDc5ZTQ2YzUwIiwiaWF0IjoxNzg0Njc2NDk3fQ.volEdb9rW-taKWRclHpVhykC-BQPf4wvHh5ZkF4h1pM';
const BASE_URL = 'https://n8n.hiwebenterprise.com';

const SECRETS = {
  AWS_KEY: process.env.AWS_KEY || '<<AWS_KEY>>',
  AWS_SECRET: process.env.AWS_SECRET || '<<AWS_SECRET>>',
  GEMINI_KEY: process.env.GEMINI_KEY || '<<GEMINI_KEY>>',
  META_TOKEN: process.env.META_TOKEN || '<<META_TOKEN>>'
};

const KNOWN_CREDENTIALS: Record<string, { id: string; name: string }> = {
  'Postgres account': { id: 'VTrElAHYtXxS0wYN', name: 'Postgres account' },
  'SerpApi account': { id: '8DzAS0fl6dzq5qpY', name: 'SerpApi account' },
  'Google Places API': { id: 'p6TPEFGKhcDgCCwv', name: 'Google Places API' },
  'Header Auth account': { id: 'p6TPEFGKhcDgCCwv', name: 'Google Places API' },
  'Google Gemini(PaLM) Api account': { id: 'PaLM-api-account-id', name: 'Google Gemini(PaLM) Api account' }
};

const targets = [
  { id: 'LD2ujo15iFNfrhEM', name: 'Leadgen — Report Generator', wf: reportGenWf },
  { id: 'gYE23EUlVMC9QtGp', name: 'Leadgen — Competitor Gap-Finder', wf: competitorsWf },
  { id: 'KKjPDVVMIHl6n5MD', name: 'Leadgen — Website Auditor v2', wf: websiteAuditorWf },
  { id: 'Ts7fpKJQacm8uhkX', name: 'Leadgen — Ad Verification', wf: adsVerificationWf },
  { id: 'BP3pMFyvJ0n0bPLX', name: 'Leadgen — Phone Probe Service', wf: phoneProbeWf },
  { id: 'k3EJWaGRnGg8tl3p', name: 'Leadgen — Ops Console', wf: opsConsoleWf }
];

function processNodesWithCredentialsAndSecrets(wf: any) {
  const json = typeof wf.toJSON === 'function' ? wf.toJSON() : wf;
  const nodes = json.nodes || [];

  const rawNodeCredsMap: Record<string, any> = {};
  if (wf._nodes && typeof wf._nodes.forEach === 'function') {
    wf._nodes.forEach((val: any, key: string) => {
      const cfg = val?.instance?.config || val?.config;
      if (cfg?.credentials) {
        rawNodeCredsMap[key] = cfg.credentials;
      }
    });
  }

  return nodes.map((n: any) => {
    let nodeStr = JSON.stringify(n);
    nodeStr = nodeStr.split('<<AWS_KEY>>').join(SECRETS.AWS_KEY);
    nodeStr = nodeStr.split('<<AWS_SECRET>>').join(SECRETS.AWS_SECRET);
    nodeStr = nodeStr.split('<<GEMINI_KEY>>').join(SECRETS.GEMINI_KEY);
    nodeStr = nodeStr.split('<<META_TOKEN>>').join(SECRETS.META_TOKEN);
    const nodeCopy = JSON.parse(nodeStr);

    const rawCreds = rawNodeCredsMap[n.name] || n.credentials;
    if (rawCreds) {
      const fixedCreds: Record<string, any> = {};
      for (const [credType, credVal] of Object.entries(rawCreds as Record<string, any>)) {
        const cName = credVal?.name || (typeof credVal === 'string' ? credVal : null);
        if (cName && KNOWN_CREDENTIALS[cName]) {
          fixedCreds[credType] = KNOWN_CREDENTIALS[cName];
        } else if (credVal?.id && credVal?.name) {
          fixedCreds[credType] = { id: credVal.id, name: credVal.name };
        } else {
          fixedCreds[credType] = credVal;
        }
      }
      if (Object.keys(fixedCreds).length > 0) {
        nodeCopy.credentials = fixedCreds;
      }
    }
    return nodeCopy;
  });
}

async function main() {
  const headers = {
    'X-N8N-API-KEY': API_KEY,
    'Content-Type': 'application/json'
  };

  console.log('Fetching existing workflows...');
  const res = await fetch(`${BASE_URL}/api/v1/workflows?limit=250`, { headers });
  if (!res.ok) {
    throw new Error(`Failed to fetch workflows: ${res.status} ${res.statusText}`);
  }
  const data = await res.json();
  const existingWorkflows: any[] = data.data || [];

  for (const t of targets) {
    const json = typeof (t.wf as any).toJSON === 'function' ? (t.wf as any).toJSON() : t.wf;
    let match = existingWorkflows.find(w => w.id === t.id) || existingWorkflows.find(w => w.name === t.name);
    let targetId = t.id;
    if (match) targetId = match.id;

    const processedNodes = processNodesWithCredentialsAndSecrets(t.wf);

    const body = JSON.stringify({
      name: json.name || t.name,
      nodes: processedNodes,
      connections: json.connections,
      settings: json.settings || {}
    });

    console.log(`Updating workflow with secrets: ${t.name} (${targetId})...`);
    const putRes = await fetch(`${BASE_URL}/api/v1/workflows/${targetId}`, {
      method: 'PUT',
      headers,
      body
    });
    if (!putRes.ok) {
      const errText = await putRes.text();
      throw new Error(`Failed to update ${t.name}: ${putRes.status} ${errText}`);
    }
    console.log(`Successfully updated ${t.name} (ID: ${targetId})`);

    console.log(`Activating workflow: ${t.name} (${targetId})...`);
    const actRes = await fetch(`${BASE_URL}/api/v1/workflows/${targetId}/activate`, {
      method: 'POST',
      headers
    });
    if (!actRes.ok) {
      console.warn(`Warning: Activation response for ${t.name}: ${actRes.status}`);
    } else {
      console.log(`Workflow active: ${t.name} (${targetId})`);
    }
  }

  console.log('\nWorkflow deployment with secrets complete!');
}

main().catch(err => {
  console.error('Deployment Error:', err);
  process.exit(1);
});
