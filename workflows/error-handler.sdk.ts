// Leadgen — Error Handler (deployed instance: YebUjdNTwGqPy4M9)
// Set as the Error Workflow in every leadgen workflow's settings.
import { workflow, node, trigger, sticky, ifElse, expr } from '@n8n/workflow-sdk';

const onError = trigger({
  type: 'n8n-nodes-base.errorTrigger',
  version: 1,
  config: { name: 'Workflow Errored', position: [240, 300] },
  output: [{ execution: { id: '123', url: 'https://n8n.hiwebenterprise.com/execution/123', error: { message: 'boom', node: { name: 'Some Node' } }, lastNodeExecuted: 'Some Node', mode: 'trigger' }, workflow: { id: 'wf1', name: 'Leadgen — Discovery' } }]
});

const formatAlert = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Format Alert',
    position: [540, 300],
    parameters: {
      mode: 'manual',
      includeOtherFields: false,
      assignments: {
        assignments: [
          { id: 'a1', name: 'text', value: expr(':rotating_light: *Unhandled workflow crash*\n' + 'Workflow: {{ $json.workflow.name }}\n' + 'Node: {{ $json.execution?.lastNodeExecuted ?? "unknown" }}\n' + 'Error: {{ $json.execution?.error?.message ?? "unknown" }}\n' + 'Execution: {{ $json.execution?.url ?? $json.execution?.id }}'), type: 'string' },
          { id: 'a2', name: 'slack_webhook', value: expr('{{ $env.LEADGEN_SLACK_WEBHOOK_URL ?? "" }}'), type: 'string' }
        ]
      }
    }
  },
  output: [{ text: 'Unhandled workflow crash ...', slack_webhook: '' }]
});

const hasSlack = ifElse({
  version: 2.2,
  config: {
    name: 'Slack Configured?',
    position: [840, 300],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
        conditions: [{ leftValue: expr('{{ $json.slack_webhook }}'), operator: { type: 'string', operation: 'notEmpty' } }],
        combinator: 'and'
      }
    }
  }
});

const postToSlack = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Post to Slack',
    position: [1140, 220],
    onError: 'continueRegularOutput',
    parameters: {
      method: 'POST',
      url: expr('{{ $json.slack_webhook }}'),
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ { "text": $json.text } }}')
    }
  },
  output: [{ ok: true }]
});

const logOnly = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Log Only (no Slack env)',
    position: [1140, 420],
    parameters: {
      mode: 'manual',
      includeOtherFields: true,
      assignments: { assignments: [ { id: 'l1', name: 'alerted', value: false, type: 'boolean' } ] }
    }
  },
  output: [{ alerted: false }]
});

const errNote = sticky(
  '## Global Error Handler\n\nSet this workflow as the Error Workflow in every leadgen workflow settings panel.\n\nAlerts go to the Slack incoming-webhook URL in env LEADGEN_SLACK_WEBHOOK_URL (set on the n8n containers). Without it, crashes still appear in n8n execution logs; ledger-level failures are independently captured as work-item states by design.',
  [formatAlert],
  { color: 3 }
);

export default workflow('leadgen-error-handler', 'Leadgen — Error Handler')
  .add(onError)
  .to(formatAlert)
  .to(hasSlack.onTrue(postToSlack).onFalse(logOnly))
  .add(errNote);
