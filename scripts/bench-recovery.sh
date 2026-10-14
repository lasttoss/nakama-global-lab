#!/usr/bin/env bash
# What is lost when a cell dies? Kill a whole cell (the measurement cell) mid-traffic and measure:
#   - how many requests fail for a client that knows only ONE cell
#   - how long until a client holding a cell list moves to another cell and succeeds
#   - whether the account survives on the other cell (shared data plane)
#   bash scripts/bench-recovery.sh
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
BENCH=nkglobal-bench-cell; BENCH_API=http://127.0.0.1:20850
B_API=http://127.0.0.1:20450
SK=$(printf 'Basic %s' "$(printf %s: defaultkey | base64 -w0)")
DEV=recovery-device-01

auth() { # $1=api -> prints user_id (empty on failure)
  local t
  t=$(curl -s --max-time 5 -X POST "$1/v2/account/authenticate/device?create=true" -H "Authorization: $SK" \
      -H 'Content-Type: application/json' -d "{\"id\":\"$DEV\"}" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')
  [ -z "$t" ] && return 1
  curl -s --max-time 5 "$1/v2/account" -H "Authorization: Bearer $t" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("user",{}).get("id",""))
except Exception: print("")'
}

echo "== 0. is the measurement cell up? (bring it up if not) =="
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BENCH_API/" 2>/dev/null)" != "200" ]; then
  bash scripts/bench-latency.sh --setup >/dev/null 2>&1
fi
uid_before=$(auth "$BENCH_API") || { echo "   measurement cell did not come up ✗"; exit 1; }
echo "   account on the measurement cell: $uid_before"

echo "== 1. traffic running (2 seconds) =="
ok=0
for _ in $(seq 1 10); do auth "$BENCH_API" >/dev/null 2>&1 && ok=$((ok+1)); done
echo "   $ok/10 requests succeeded"

echo "== 2. KILL the measurement cell (simulating a sudden cell death) =="
docker kill "$BENCH" >/dev/null 2>&1
t0=$(date +%s.%N)
echo "   killed at $(date +%T)"

echo "== 3. client WITH a cell list: time from the kill until cell B serves =="
dead_fail=0; ok_after=""
for _ in $(seq 1 30); do
  auth "$BENCH_API" >/dev/null 2>&1 || dead_fail=$((dead_fail+1))
  u=$(auth "$B_API" 2>/dev/null)
  if [ -n "$u" ]; then
    t1=$(date +%s.%N)
    ok_after=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    printf '   cell B answered OK — %s s after the kill (tried the dead cell %d times)\n' "$ok_after" "$dead_fail"
    printf '   account on cell B: %s\n' "$u"
    [ "$u" = "$uid_before" ] && echo "   ✓ SAME account — a dead cell loses no data (shared data plane)" \
                             || echo "   ✗ different account"
    break
  fi
  sleep 0.2
done

echo "== 4. client that knows ONLY that cell (no list): every request fails =="
blind=0
for _ in $(seq 1 5); do auth "$BENCH_API" >/dev/null 2>&1 || blind=$((blind+1)); sleep 0.2; done
echo "   $blind/5 requests failed ✗ — the cell is dead and the client has nowhere else to go"
echo "   ⇒ total requests lost to that cell death: $((blind + dead_fail))"
echo
echo "The measurement cell was killed (not recreated). Clean up: docker rm -f $BENCH"
