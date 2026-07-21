// Leadgen — Sweeper (deployed instance: f5xBdfjMchJgJOzq)
// US1 T041: every 2 min, one maintenance round-trip + a campaign finalization pass.
//
// Run Maintenance (single query, all SECURITY DEFINER fns — workers hold NO direct
// DML, so the disabled-service skip MUST be a function, not an inline UPDATE):
//   - skip_disabled_service_work: marks nonterminal work_items whose service is
//     DISABLED in service_config (Option A / migration 110 — a service with no
//     shipped worker, e.g. US1 reviews/phone/enrichment/assets) skipped_prerequisite
//     so campaigns can finalize without it, then
//   - reap_expired_leases · requeue_retryable_work · requeue_stale_assessments ·
//     reconcile_expired_reservations (stuck work self-heals).
//
// Finalization pass: Find Finalizable (campaigns in analyzing/awaiting_approval) →
//   Begin Finalization (begin_campaign_finalization: resolves approval/critic
//   deadlines, checks readiness, fences with a token+state_revision) → Ready? →
//   Complete Finalization (complete_campaign_finalization: computes quality_state,
//   sets terminal). Digest + Sheets snapshot are US4 (T057) — payload leaves
//   digest_url/sheet_snapshot_url null for now.
//
// KNOWN GAPS (T040/Scorer follow-up, block full finalization today):
//   (1) no-website leads never get an initial assessment (assessment unblocks only
//       on an analyzer completion; a no-domain lead has no analyzer to complete) —
//       product-critical since website_present=false is the top redesign signal.
//   (2) requeue_stale_assessments excludes state='dead', so a dead assessment never
//       revives even when lead_revision advances past its watermark.
import { workflow, node, trigger, ifElse, newCredential, expr } from '@n8n/workflow-sdk';

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
      query: "SELECT leadgen.skip_disabled_service_work() AS disabled_skipped, leadgen.reap_expired_leases() AS reaped, leadgen.requeue_retryable_work() AS requeued, leadgen.reconcile_blocked_dependencies() AS dependencies_reconciled, leadgen.requeue_stale_assessments() AS stale_requeued, leadgen.reconcile_expired_reservations() AS budget_reconciled"
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ disabled_skipped: 0, reaped: {}, requeued: {}, dependencies_reconciled: 0, stale_requeued: 0, budget_reconciled: {} }]
});

const findFinalizable = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Find Finalizable',
    position: [820, 300],
    parameters: {
      operation: 'executeQuery',
      query: "SELECT id::text AS campaign_id FROM leadgen.campaigns WHERE status IN ('analyzing','awaiting_approval')"
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ campaign_id: 'c1' }]
});

const beginFinalization = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Begin Finalization',
    position: [1080, 300],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT '{{ $json.campaign_id }}'::uuid AS campaign_id, leadgen.begin_campaign_finalization('{{ $json.campaign_id }}'::uuid) AS result")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ campaign_id: 'c1', result: { status: 'ready', finalization_token: 't', state_revision: 0 } }]
});

const readyToComplete = ifElse({
  version: 2.2,
  config: {
    name: 'Ready to Complete?',
    position: [1340, 300],
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'loose', version: 2 },
        combinator: 'and',
        conditions: [{ leftValue: expr('{{ $json.result.status }}'), operator: { type: 'string', operation: 'equals' }, rightValue: 'ready' }]
      }
    }
  }
});

const completeFinalization = node({
  type: 'n8n-nodes-base.postgres',
  version: 2.6,
  config: {
    name: 'Complete Finalization',
    position: [1600, 220],
    parameters: {
      operation: 'executeQuery',
      query: expr("SELECT leadgen.complete_campaign_finalization('{{ $json.campaign_id }}'::uuid, '{{ $json.result.finalization_token }}'::uuid, {{ $json.result.state_revision }}::bigint, '{\"completion_reason\":\"finished\"}'::jsonb) AS result")
    },
    credentials: { postgres: newCredential('Postgres account') }
  },
  output: [{ result: { status: 'complete', quality_state: 'healthy' } }]
});

// After a campaign finalizes, fire the Report Generator in batch mode for its warm/hot
// leads (fire-and-forget: short timeout + onError continue, so finalization never blocks;
// the report workflow runs in its own execution and finishes even if this caller times out).
const fireReports = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Fire Reports',
    position: [1840, 220],
    onError: 'continueRegularOutput',
    parameters: {
      method: 'POST',
      url: 'https://n8n.hiwebenterprise.com/webhook/leadgen-report',
      sendBody: true, specifyBody: 'json',
      jsonBody: expr('={ "campaign_id": "{{ $(\'Begin Finalization\').item.json.campaign_id }}" }'),
      options: { timeout: 8000 }
    }
  }
});

export default workflow('leadgen-sweeper', 'Leadgen — Sweeper')
  .add(everyTwoMin)
  .to(runMaintenance)
  .to(findFinalizable)
  .to(beginFinalization)
  .to(readyToComplete.onTrue(completeFinalization.to(fireReports)));
