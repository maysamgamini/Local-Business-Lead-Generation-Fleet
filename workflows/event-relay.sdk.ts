// Leadgen — Event Relay (deployed instance: D2O53VaniWo0i6T7)
// Deploy/update via n8n MCP create_workflow_from_code / update_workflow.
import { workflow, node, trigger, sticky, ifElse, newCredential, expr } from '@n8n/workflow-sdk';

const everyMinute = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: {
    name: 'Every Minute',
    position: [240, 260],
    parameters: { rule: { interval: [{ field: 'minutes', minutesInterval: 1 }] } }
  },
  output: [{}]
});

const pokeWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'Relay Poke',
    position: [240, 480],
    parameters: { httpMethod: 'POST', path: 'leadgen-relay-poke', responseMode: 'onReceived' }
  },
  output: [{ body: {} }]
});

const claimDeliveries = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Claim Deliveries',
    position: [560, 360],
    executeOnce: true,
    parameters: {
      operation: 'executeQuery',
      query: "SELECT c.delivery_id, c.claim_token, c.event_id, c.event_type, c.event_class, c.aggregate_id, coalesce(c.effective_revision, 0) AS effective_revision, c.payload, d.dest AS destination FROM unnest(ARRAY['discovery_poke','analyzer_poke','scorer_poke','enrichment_poke','chain_eval','chain_target_poke','slack','dashboard']) AS d(dest) CROSS JOIN LATERAL leadgen.claim_outbox_deliveries(d.dest, $1, 10) c",
      options: { queryReplacement: expr('relay-{{ $execution.id }}') }
    },
    credentials: { postgres: newCredential('Leadgen Postgres (relay)') }
  },
  output: [{ delivery_id: 'd1', claim_token: 't1', event_id: 'e1', event_type: 'assessment.published', event_class: 'state_change', aggregate_id: 'lead-1', effective_revision: 4, payload: {}, destination: 'chain_eval' }]
});

const isChainEval = ifElse({
  version: 2.2,
  config: {
    name: 'Chain Eval?',
    position: [860, 360],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ leftValue: expr('{{ $json.destination }}'), operator: { type: 'string', operation: 'equals' }, rightValue: 'chain_eval' }],
        combinator: 'and'
      }
    }
  }
});

const runChainRules = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Evaluate Chain Rules',
    position: [1160, 260],
    onError: 'continueErrorOutput',
    parameters: {
      operation: 'executeQuery',
      query: "SELECT leadgen.evaluate_chain_rules($1::uuid, 'on_assessment', $2::bigint) AS result",
      options: { queryReplacement: expr('{{ $json.aggregate_id }},{{ $json.effective_revision }}') }
    },
    credentials: { postgres: newCredential('Leadgen Postgres (relay)') }
  },
  output: [{ result: { fired: 0, not_fired: 2 } }]
});

const completeChainEval = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Complete Chain Delivery',
    position: [1460, 200],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT leadgen.complete_outbox_delivery($1::uuid, $2::uuid, $3, 'relay-v1') AS result",
      options: { queryReplacement: expr("{{ $('Claim Deliveries').item.json.delivery_id }},{{ $('Claim Deliveries').item.json.claim_token }},chain-eval") }
    },
    credentials: { postgres: newCredential('Leadgen Postgres (relay)') }
  },
  output: [{ result: 'delivered' }]
});

const failChainEval = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Fail Chain Delivery',
    position: [1460, 360],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT leadgen.fail_outbox_delivery($1::uuid, $2::uuid, $3) AS result",
      options: { queryReplacement: expr("{{ $('Claim Deliveries').item.json.delivery_id }},{{ $('Claim Deliveries').item.json.claim_token }},chain eval failed") }
    },
    credentials: { postgres: newCredential('Leadgen Postgres (relay)') }
  },
  output: [{ result: 'pending' }]
});

const completeNoop = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Complete as Noop v1',
    position: [1160, 520],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT leadgen.complete_outbox_delivery($1::uuid, $2::uuid, $3, 'relay-v1') AS result",
      options: { queryReplacement: expr('{{ $json.delivery_id }},{{ $json.claim_token }},noop-v1:{{ $json.destination }}') }
    },
    credentials: { postgres: newCredential('Leadgen Postgres (relay)') }
  },
  output: [{ result: 'delivered' }]
});

const relayNote = sticky(
  '## Event Relay (transport only)\n\nClaims outbox deliveries for all destinations with lease + fence.\n\n**v1 policy**: chain_eval deliveries invoke evaluate_chain_rules(); poke destinations complete as no-ops (worker polling is the delivery guarantee — pokes become real HTTP nudges when the US1 worker webhooks exist); slack/dashboard upgrade in US4.\n\nNo business logic lives here by design.',
  [claimDeliveries],
  { color: 4 }
);

export default workflow('leadgen-event-relay', 'Leadgen — Event Relay')
  .add(everyMinute)
  .to(claimDeliveries)
  .to(isChainEval
    .onTrue(runChainRules
      .to(completeChainEval)
      .onError(failChainEval))
    .onFalse(completeNoop))
  .add(pokeWebhook)
  .to(claimDeliveries)
  .add(relayNote);
