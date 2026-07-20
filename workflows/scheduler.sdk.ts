// Leadgen — Scheduler (Ops Console feature #4). Deployed instance: zSW7lriZbXptYpz1.
// Hourly poll (plus an on-demand poke webhook) -> fire_due_schedules(): launches every due
// campaign_schedules row via create_campaign(trigger_source='schedule') in one transaction and
// advances next_run_at (weekly +7d / monthly +1mo / once -> disabled). Prod-only spend.
import { workflow, node, trigger, sticky, newCredential } from '@n8n/workflow-sdk';

const hourly = trigger({ type: 'n8n-nodes-base.scheduleTrigger', version: 1.3, config: { name: 'Hourly', position: [220, 240], parameters: { rule: { interval: [{ field: 'hours', hoursInterval: 1 }] } } }, output: [{}] });

const poke = trigger({ type: 'n8n-nodes-base.webhook', version: 2.1, config: { name: 'Scheduler Poke', position: [220, 420], parameters: { httpMethod: 'POST', path: 'leadgen-scheduler-poke', responseMode: 'onReceived' } }, output: [{ body: {} }] });

const fire = node({ type: 'n8n-nodes-base.postgres', version: 2.6, config: { name: 'Fire Due Schedules', position: [520, 320], executeOnce: true, parameters: { operation: 'executeQuery', query: 'SELECT leadgen.fire_due_schedules() AS result' }, credentials: { postgres: newCredential('Postgres account') } }, output: [{ result: {} }] });

const note = sticky('## Scheduler (feature #4)\n\nHourly (+ poke) -> leadgen.fire_due_schedules(): launches every due campaign_schedules row via create_campaign (trigger_source=schedule), advancing next_run_at (weekly +7d / monthly +1mo / once -> disabled). Schedules created/paused from the Ops Console (schedule_campaign / cancel_campaign_schedule).', [fire], { color: 5 });

export default workflow('leadgen-scheduler', 'Leadgen — Scheduler')
  .add(hourly).to(fire)
  .add(poke).to(fire)
  .add(note);
