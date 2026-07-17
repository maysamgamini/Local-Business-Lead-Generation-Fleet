// Leadgen — Sweeper maintenance core (deployed instance: f5xBdfjMchJgJOzq)
// US1 T041: every 2 min, one round-trip runs the four engine functions so stuck
// work self-heals (reap leases, requeue retryable, requeue stale assessments,
// reconcile expired budget holds). Finalization + digest is the next stage.
import { workflow, node, trigger, sticky, newCredential } from '@n8n/workflow-sdk';

const everyTwoMin = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: { name: 'Sweeper Tick', position: [240, 300], parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 2 }] } } },
  output: [{}]
});

const runMaintenance = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Run Maintenance',
    position: [560, 300],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT leadgen.reap_expired_leases() AS reaped, leadgen.requeue_retryable_work() AS requeued, leadgen.requeue_stale_assessments() AS stale_requeued, leadgen.reconcile_expired_reservations() AS budget_reconciled"
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ reaped: {}, requeued: {}, stale_requeued: 0, budget_reconciled: {} }]
});

export default workflow('leadgen-sweeper', 'Leadgen — Sweeper')
  .add(everyTwoMin)
  .to(runMaintenance);
