#!/usr/bin/env bash
# run-race-tests.sh (T029) — executes the full race suite against leadgen_dryrun.
# Usage (on the n8n host):  PSQL_CONTAINER=n8n-postgres-1 PGUSER=n8n_root ./run-race-tests.sh
# Sequential assertions come from db/tests/race_tests.sql; this script adds the
# genuinely concurrent scenarios: claim semaphore, discovery poke storm, and
# the budget-cap boundary under parallel authorization.
set -euo pipefail
C="${PSQL_CONTAINER:-n8n-postgres-1}"
U="${PGUSER:-n8n_root}"
DB="${PGDATABASE:-leadgen_db}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PSQL() { sudo docker exec -i "$C" psql -U "$U" -d "$DB" -v ON_ERROR_STOP=1 -X -q -tA "$@"; }
SQL() { PSQL -c "SET search_path=leadgen_dryrun; $1"; }
TS=$(date +%s)

echo "=== 1/4 sequential suite (db/tests/race_tests.sql) ==="
PSQL < "$DIR/db/tests/race_tests.sql" | tail -1

echo "=== 2/4 discovery poke storm (5 parallel claims -> exactly 1 winner) ==="
SQL "SELECT campaign_id FROM leadgen_dryrun.create_campaign(
  '{\"schema_version\":\"1.0\",\"request_id\":\"storm-$TS\",\"business_type\":\"spa\",
    \"geo\":{\"type\":\"zip\",\"zip\":\"78613\",\"radius_m\":10000},\"depth\":\"quick\",
    \"volume_cap\":10,\"budget\":{\"amount\":10,\"currency\":\"USD\"}}'::jsonb,
  'aaaaaaaa-0000-0000-0000-000000000002','webhook')" > /tmp/storm_camp.txt
rm -f /tmp/storm_claim_*.txt
for i in 1 2 3 4 5; do
  SQL "SELECT work_item_id FROM leadgen_dryrun.claim_work_items('discovery','storm-$i')" \
    > "/tmp/storm_claim_$i.txt" 2>/dev/null &
done
wait
WINNERS=$(cat /tmp/storm_claim_*.txt | grep -c . || true)
echo "winners: $WINNERS (expect 1; discovery max_concurrency=2 but only 1 item exists)"
[ "$WINNERS" -eq 1 ] || { echo "FAIL: poke storm claimed $WINNERS"; exit 1; }
echo "PASS: poke storm"

echo "=== 3/4 claim semaphore (max_concurrency=3, two parallel batch-5 claims) ==="
CAMP2=$(SQL "SELECT campaign_id FROM leadgen_dryrun.create_campaign(
  '{\"schema_version\":\"1.0\",\"request_id\":\"sema-$TS\",\"business_type\":\"spa\",
    \"geo\":{\"type\":\"zip\",\"zip\":\"78613\",\"radius_m\":10000},\"depth\":\"quick\",
    \"volume_cap\":10,\"budget\":{\"amount\":10,\"currency\":\"USD\"}}'::jsonb,
  'aaaaaaaa-0000-0000-0000-000000000002','webhook')")
CLAIM=$(SQL "SELECT work_item_id||'|'||claim_token FROM leadgen_dryrun.claim_work_items('discovery','sema-setup')")
ITEM="${CLAIM%%|*}"; TOK="${CLAIM##*|}"
BIZ=""
for n in 1 2 3 4 5 6; do
  BIZ="$BIZ{\"place_id\":\"sema-$TS-$n\",\"name\":\"Sema $n\",\"domain\":\"sema$n.example\",\"dedup_key\":\"sema$n\",\"evidence\":[]},"
done
SQL "SELECT leadgen_dryrun.commit_discovery_results('$CAMP2','$ITEM','$TOK',
  '{\"geo\":{\"lat\":30.5,\"lng\":-97.8},\"businesses\":[${BIZ%,}],\"run\":{}}'::jsonb)" >/dev/null
SQL "UPDATE leadgen_dryrun.service_config SET max_concurrency=3, claim_batch_size=5 WHERE service='website'"
rm -f /tmp/sema_claim_*.txt
SQL "SELECT work_item_id FROM leadgen_dryrun.claim_work_items('website','sema-A')" > /tmp/sema_claim_A.txt &
SQL "SELECT work_item_id FROM leadgen_dryrun.claim_work_items('website','sema-B')" > /tmp/sema_claim_B.txt &
wait
TOTAL=$(cat /tmp/sema_claim_*.txt | grep -c . || true)
RUNNING=$(SQL "SELECT count(*) FROM leadgen_dryrun.work_items WHERE service='website' AND state='running' AND campaign_id='$CAMP2'")
SQL "UPDATE leadgen_dryrun.service_config SET max_concurrency=5, claim_batch_size=5 WHERE service='website'"
echo "claimed across sessions: $TOTAL, running: $RUNNING (expect <=3)"
[ "$TOTAL" -le 3 ] && [ "$RUNNING" -le 3 ] || { echo "FAIL: semaphore exceeded"; exit 1; }
echo "PASS: semaphore"

echo "=== 4/4 budget boundary (cap \$10, two parallel \$6 authorizations) ==="
L1=$(sed -n 1p /tmp/sema_claim_A.txt /tmp/sema_claim_B.txt | grep . | head -1)
# need tokens+runs: reclaim cleanly instead — release the running ones back
# (use two of the claimed items' tokens directly from a fresh query)
PAIRS=$(SQL "SELECT id||'|'||claim_token||'|'||(SELECT r.id FROM leadgen_dryrun.service_runs r
   WHERE r.work_item_id = w.id ORDER BY r.work_attempt DESC LIMIT 1)
   FROM leadgen_dryrun.work_items w
   WHERE w.campaign_id='$CAMP2' AND w.service='website' AND w.state='running' LIMIT 2")
P1=$(echo "$PAIRS" | sed -n 1p); P2=$(echo "$PAIRS" | sed -n 2p)
I1=$(echo "$P1"|cut -d'|' -f1); T1=$(echo "$P1"|cut -d'|' -f2); R1=$(echo "$P1"|cut -d'|' -f3)
I2=$(echo "$P2"|cut -d'|' -f1); T2=$(echo "$P2"|cut -d'|' -f2); R2=$(echo "$P2"|cut -d'|' -f3)
SQL "SELECT leadgen_dryrun.authorize_paid_operation('$I1','$T1','$R1','psi','default','op',6.00,'race-b-$TS-1')->>'status'" > /tmp/bud_1.txt &
SQL "SELECT leadgen_dryrun.authorize_paid_operation('$I2','$T2','$R2','psi','default','op',6.00,'race-b-$TS-2')->>'status'" > /tmp/bud_2.txt &
wait
OK=$(cat /tmp/bud_1.txt /tmp/bud_2.txt | grep -c '^authorized$' || true)
NO=$(cat /tmp/bud_1.txt /tmp/bud_2.txt | grep -c 'insufficient_budget' || true)
echo "authorized: $OK, insufficient: $NO (expect 1 / 1)"
[ "$OK" -eq 1 ] && [ "$NO" -eq 1 ] || { echo "FAIL: budget boundary over/under-authorized"; exit 1; }
echo "PASS: budget boundary"

echo ""
echo "RACE SUITE: ALL PASSED"
