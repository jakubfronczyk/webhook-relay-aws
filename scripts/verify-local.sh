#!/usr/bin/env bash
#
# Asserts every delivery guarantee this repo claims, from a cold start, with no
# AWS account. Exits non-zero when one stops holding.
#
#   ./scripts/verify-local.sh              wipe, rebuild, run everything (~3 min)
#   KEEP_STACK=1 N=100 ./scripts/verify-local.sh   reuse the running stack
#
set -uo pipefail

API=http://localhost:8080
SINK=http://localhost:9000
MQ=http://localhost:9324/000000000000
RUN=$$                          # unique event types, so reruns cannot collide
N=${N:-200}
PASSED=0 FAILED=0

ok()  { PASSED=$((PASSED+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()  { FAILED=$((FAILED+1)); printf '  \033[31m✗\033[0m %s — expected %s, got %s\n' "$1" "$3" "$2"; }
is()  { [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }
btwn(){ [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] 2>/dev/null && ok "$1" || no "$1" "$2" "$3..$4"; }
step(){ printf '\n\033[2m── %s\033[0m\n' "$1"; }

subscribe() { curl -sf -X POST "$API/subscriptions" -H 'content-type: application/json' \
                -d "{\"url\":\"http://sink:9000/hook\",\"event_type\":\"$1\"}"; }
publish()   { curl -sf -X POST "$API/events" -H 'content-type: application/json' \
                -d "{\"type\":\"$1\",\"payload\":{}}" | jq -r .event_id; }
attempts()  { curl -sf "$API/events/$1" | jq -c '.delivery_attempts'; }
code()      { curl -s -o /dev/null -w '%{http_code}' "$@"; }
attr()      { curl -s "$MQ/$1?Action=GetQueueAttributes&AttributeName.1=$2" \
                | sed -n 's|.*<Value>\([0-9]*\)</Value>.*|\1|p'; }
sink_with() { env "$@" docker compose up -d --force-recreate --wait sink >/dev/null 2>&1
              curl -sf -X POST "$SINK/reset" >/dev/null; }
until_()    { local t=$((SECONDS+$1)); shift
              while [ $SECONDS -lt $t ]; do "$@" && return 0; sleep 2; done; return 1; }

got()     { [ "$(attempts "$1" | jq 'length')" -ge "$2" ]; }
in_dlq()  { [ "$(attr webhook-relay-deliveries-dlq ApproximateNumberOfMessages)" = "$1" ]; }
# "Empty" and "finished" are different questions: a message a dead worker is
# still holding is invisible, not lost, until its visibility timeout expires.
# Polling on the visible count alone samples mid-recovery and invents data loss.
drained() { [ "$(attr webhook-relay-deliveries ApproximateNumberOfMessages)" = "0" ] &&
            [ "$(attr webhook-relay-deliveries ApproximateNumberOfMessagesNotVisible)" = "0" ]; }

step "cold start"
for t in docker jq curl; do command -v $t >/dev/null || { echo "  $t is not installed"; exit 2; }; done
docker info >/dev/null 2>&1 || { echo "  the docker daemon is not running"; exit 2; }
[ -z "${KEEP_STACK:-}" ] && docker compose down -v >/dev/null 2>&1
docker compose up --build -d --wait >/dev/null 2>&1 \
  || { echo "  the stack did not come up healthy"; docker compose ps; exit 2; }
ok "postgres, elasticmq, api, worker and sink are healthy"

step "api contract"
is "GET /healthz reports the database reachable" "$(curl -sf "$API/healthz" | jq -r .status)" "ok"
is "POST /events without a type is rejected" \
   "$(code -X POST "$API/events" -H 'content-type: application/json' -d '{"payload":{}}')" "400"
is "POST /events returns 202, not 201" \
   "$(code -X POST "$API/events" -H 'content-type: application/json' -d "{\"type\":\"c.$RUN\"}")" "202"
is "POST /subscriptions rejects a relative url" \
   "$(code -X POST "$API/subscriptions" -H 'content-type: application/json' \
      -d '{"url":"/hook","event_type":"x"}')" "400"
is "re-registering the same url and event type is idempotent" \
   "$(subscribe "idem.$RUN" | jq -r .id)" "$(subscribe "idem.$RUN" | jq -r .id)"
is "GET /events/{id} on an unknown id is a 404" \
   "$(code "$API/events/00000000-0000-0000-0000-000000000000")" "404"

step "happy path"
sink_with; subscribe "happy.$RUN" >/dev/null
id=$(publish "happy.$RUN")
if until_ 15 got "$id" 1; then
  is "the event is delivered and the attempt recorded" "$(attempts "$id" | jq -r '.[0].status_code')" "200"
  is "the subscriber received it exactly once" "$(curl -sf "$SINK/stats" | jq -r .unique_events)" "1"
  is "with no duplicates" "$(curl -sf "$SINK/stats" | jq -r .duplicate_recv)" "0"
else no "the event is delivered" "nothing" "1 attempt in 15s"; fi

step "hmac signing"
secret=$(subscribe "signed.$RUN" | jq -r .secret)
sink_with SUBSCRIPTION_SECRET="$secret"; id=$(publish "signed.$RUN")
until_ 15 got "$id" 1 && is "the right secret verifies the signature" \
  "$(attempts "$id" | jq -r '.[0].status_code')" "200"
sink_with SUBSCRIPTION_SECRET=whsec_wrong; id=$(publish "signed.$RUN")
until_ 15 got "$id" 1 && is "the wrong secret rejects it" \
  "$(attempts "$id" | jq -r '.[0].status_code')" "401"

step "retry curve"
sink_with FAIL_UNTIL_ATTEMPT=2; subscribe "retry.$RUN" >/dev/null
id=$(publish "retry.$RUN")
if until_ 30 got "$id" 3; then
  a=$(attempts "$id")
  # Attempt numbers come from SQS's ApproximateReceiveCount, not from worker state.
  is "attempts are 1, 2, 3 and fail, fail, succeed" \
     "$(jq -rc '[.[] | [.attempt_no, .status_code]]' <<<"$a")" "[[1,500],[2,500],[3,200]]"
  secs='[.[].attempted_at | sub("\\.[0-9]+";"") | fromdateiso8601]'
  g1=$(jq -r "$secs|.[1]-.[0]" <<<"$a"); g2=$(jq -r "$secs|.[2]-.[1]" <<<"$a")
  btwn "first retry waits ~2s (got ${g1}s)"  "$g1" 1 4
  btwn "second retry waits ~4s (got ${g2}s)" "$g2" 3 8
else no "the retry curve runs" "$(attempts "$id" | jq 'length') attempts" "3 in 30s"; fi

step "poison message reaches the dlq"
want=$(( $(attr webhook-relay-deliveries-dlq ApproximateNumberOfMessages) + 1 ))
sink_with FAIL_UNTIL_ATTEMPT=99; subscribe "doomed.$RUN" >/dev/null
id=$(publish "doomed.$RUN")
until_ 60 got "$id" 4
until_ 60 in_dlq "$want"    # the redrive lands one backoff interval after the last failure
is "exactly maxReceiveCount attempts, then it stops" "$(attempts "$id" | jq 'length')" "4"
is "the message moved to the dead-letter queue" \
   "$(attr webhook-relay-deliveries-dlq ApproximateNumberOfMessages)" "$want"

step "durability: the fleet dies mid-drain"
sink_with RESPONSE_DELAY=200ms; subscribe "kill.$RUN" >/dev/null
docker compose stop worker >/dev/null 2>&1
echo "  enqueueing $N events with no worker running…"
seq 1 $N | xargs -P 16 -I_ curl -s -o /dev/null -X POST "$API/events" \
  -H 'content-type: application/json' -d "{\"type\":\"kill.$RUN\",\"payload\":{}}"
# ApproximateNumberOfMessages is approximate by contract; exact accounting comes
# from Postgres, the only component that can answer a transactional question.
btwn "the backlog survives with nothing consuming it" \
  "$(attr webhook-relay-deliveries ApproximateNumberOfMessages)" $((N-5)) $N
docker compose start worker >/dev/null 2>&1; sleep 3
echo "  SIGKILLing the worker mid-drain…"
docker compose kill worker >/dev/null 2>&1; sleep 2
docker compose start worker >/dev/null 2>&1
echo "  restarted; waiting out the visibility timeout on what it was holding…"
until_ 180 drained || echo "  the queue never fully drained"
sleep 3

read -r accepted delivered <<<"$(docker compose exec -T postgres psql -U relay -d relay -tA -F' ' -c "
  select (select count(*) from events where type='kill.$RUN'),
         (select count(distinct a.event_id) from delivery_attempts a
            join events e on e.id = a.event_id
           where e.type='kill.$RUN' and a.status_code between 200 and 299)")"
stats=$(curl -sf "$SINK/stats")
is "the api accepted all $N" "$accepted" "$N"
is "every accepted event reached the subscriber" "$delivered" "$accepted"
is "the subscriber's own tally agrees" "$(jq -r .unique_events <<<"$stats")" "$N"
# Duplicates are expected and bounded: the deliveries in flight when the process
# died, accepted by the subscriber but never acked to SQS.
btwn "duplicates stayed within WORKER_CONCURRENCY ($(jq -r .duplicate_recv <<<"$stats"))" \
  "$(jq -r .duplicate_recv <<<"$stats")" 0 "$(docker compose exec -T worker printenv WORKER_CONCURRENCY 2>/dev/null || echo 8)"

[ "$FAILED" -eq 0 ] && { printf '\n\033[32mPASS\033[0m  %d checks\n\n' "$PASSED"; exit 0; }
printf '\n\033[31mFAIL\033[0m  %d of %d checks\n\n' "$FAILED" "$((PASSED+FAILED))"; exit 1
