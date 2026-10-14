#!/usr/bin/env bash
# What happens to a cell when the data plane dies? Two flavours: STALL (pause) and STOP.
#   bash scripts/bench-dataplane-failure.sh
# Measures: what the client sees, whether the cell recovers on its own, whether data survives.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
YB=nkglobal-yb; API=http://127.0.0.1:20350
SK=$(printf 'Basic %s' "$(printf %s: defaultkey | base64 -w0)")
SQL() { timeout 25 docker exec "$YB" /home/yugabyte/bin/ysqlsh -h 127.0.0.1 -U yugabyte -d yugabyte -t -A -c "$1" 2>/dev/null | tr -d ' '; }

auth_ok() { # returns 0 if one auth request succeeds (4s timeout)
  curl -sf --max-time 4 -X POST "$API/v2/account/authenticate/device?create=true" \
    -H "Authorization: $SK" -H 'Content-Type: application/json' -d '{"id":"dpfail-device"}' >/dev/null 2>&1
}
burst() { # $1=n  -> in "ok fail"
  local ok=0 f=0
  for _ in $(seq 1 "$1"); do auth_ok && ok=$((ok+1)) || f=$((f+1)); done
  echo "$ok $f"
}
yb_ready() { [ -n "$(SQL 'select 1')" ]; }          # can YB answer yet?
storage_ok() { # returns 0 if one object write succeeds
  local tok
  tok=$(curl -sf --max-time 4 -X POST "$API/v2/account/authenticate/device?create=true" \
        -H "Authorization: $SK" -H 'Content-Type: application/json' -d '{"id":"dpfail-storage"}' 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')
  [ -z "$tok" ] && return 1
  curl -sf --max-time 4 -X PUT "$API/v2/storage" -H "Authorization: Bearer $tok" \
    -H 'Content-Type: application/json' -d '{"objects":[{"collection":"dpfail","key":"k","value":"{\"a\":1}","permission_read":1,"permission_write":1}]}' >/dev/null 2>&1
}
wait_for() { # $1=probe name $2=max seconds $3=t0 -> prints "name: Ns"
  local n=0
  while [ "$n" -lt "$2" ]; do
    "$1" && { echo "   $1 OK after $(( $(date +%s) - $3 ))s from the moment YB answered"; return 0; }
    sleep 1; n=$((n+1))
  done
  echo "   $1: >$2 s ✗"
}

echo "== 0. baseline =="
before=$(SQL "select count(*) from migration_info"); echo "   migration_info=$before"; echo "   auth: $(burst 3)"

for mode in pause stop; do
  echo
  echo "== 1. $mode YB (data plane $([ "$mode" = pause ] && echo 'STALLED — the harsher case' || echo 'STOPPED')) =="
  docker "$mode" "$YB" >/dev/null 2>&1
  echo "   client while YB is $mode: $(burst 4) (ok fail) — up to 4s per request"
  echo "   is the Nakama cell still up? $(docker ps --format '{{.Names}}' | grep -c nkglobal-nakama-a) container ✓ (it does not exit)"
  if [ "$mode" = pause ]; then docker unpause "$YB" >/dev/null 2>&1; else docker start "$YB" >/dev/null 2>&1; fi
  echo "   did $([ "$mode" = pause ] && echo unpause || echo start) YB, waiting for YB to answer:"
  n=0; while ! yb_ready && [ $n -lt 90 ]; do sleep 1; n=$((n+1)); done
  if ! yb_ready; then echo "   YB did not come back within 90s ✗ — stopping here"; exit 1; fi
  t0=$(date +%s); echo "   YB answers again after ${n}s; measuring cell recovery from here:"
  wait_for auth_ok 90 "$t0"
  wait_for storage_ok 90 "$t0"
  after=$(SQL "select count(*) from migration_info")
  echo "   data: migration_info=$after $([ "$before" = "$after" ] && echo '✓ intact' || echo '✗ DATA LOST')"
done

echo
echo "== 2. overall check once the data plane is back =="
make smoke 2>&1 | grep -E "FAIL|PASS=|⇒" | tail -5
