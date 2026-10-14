#!/usr/bin/env bash
# Measure one cell's round-trip, optionally injecting WAN latency on the cell→data-plane path only.
#   bash scripts/bench-latency.sh                 # baseline (no latency)
#   bash scripts/bench-latency.sh --inject 60     # inject 60ms one-way towards YB
#   bash scripts/bench-latency.sh --clear         # remove it
#   N=200 bash scripts/bench-latency.sh           # sample count
# Honest caveat: only ONE direction is injected (YB's container has no `tc`), so a real
# symmetric WAN adds about as much again on the way back ⇒ double the delta when inferring true RTT.
set -euo pipefail
CELL="${CELL:-nkglobal-nakama-a}"
YB_IP="${YB_IP:-$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nkglobal-yb)}"
API="${API:-http://127.0.0.1:20350}"
N="${N:-100}"
SK="Basic $(printf %s: defaultkey | base64 -w0)"

inject() { # $1 = ms
  docker exec "$CELL" tc qdisc del dev eth0 root 2>/dev/null || true
  docker exec "$CELL" tc qdisc add dev eth0 root handle 1: prio
  docker exec "$CELL" tc filter add dev eth0 parent 1: protocol ip prio 1 \
      u32 match ip dst "$YB_IP"/32 flowid 1:3
  docker exec "$CELL" tc qdisc add dev eth0 parent 1:3 handle 30: netem delay "$1"ms
  echo "   injected ${1}ms one-way on the cell→YB path ($YB_IP) ✓"
}
clear_tc() { docker exec "$CELL" tc qdisc del dev eth0 root 2>/dev/null || true; echo "   latency removed ✓"; }

pcts() { python3 -c '
import sys
xs=sorted(float(l) for l in sys.stdin if l.strip())
n=len(xs)
def p(q): return xs[min(n-1,int(round(q*(n-1))))]*1000
print(f"{p(.5):8.1f} {p(.95):8.1f} {p(.99):8.1f}")'; }

run_case() { # $1 = label
  echo "── $1 (N=$N)"
  : > /tmp/bench_auth; : > /tmp/bench_put; : > /tmp/bench_get
  local tok uid
  for _ in $(seq 1 "$N"); do
    curl -s -o /tmp/bench_auth_body -w '%{time_total}\n' \
      -X POST "$API/v2/account/authenticate/device?create=true" -H "Authorization: $SK" \
      -H 'Content-Type: application/json' -d '{"id":"bench-device-0001"}' >> /tmp/bench_auth
  done
  tok=$(python3 -c 'import json;print(json.load(open("/tmp/bench_auth_body")).get("token",""))')
  uid=$(curl -s "$API/v2/account" -H "Authorization: Bearer $tok" \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("user",{}).get("id",""))')
  for i in $(seq 1 "$N"); do
    curl -s -o /dev/null -w '%{time_total}\n' -X PUT "$API/v2/storage" -H "Authorization: Bearer $tok" \
      -H 'Content-Type: application/json' \
      -d "{\"objects\":[{\"collection\":\"bench\",\"key\":\"k$i\",\"value\":\"{\\\"n\\\":$i}\",\"permission_read\":1,\"permission_write\":1}]}" >> /tmp/bench_put
  done
  for _ in $(seq 1 "$N"); do
    curl -s -o /dev/null -w '%{time_total}\n' "$API/v2/storage/bench?user_id=$uid" \
      -H "Authorization: Bearer $tok" >> /tmp/bench_get
  done
  printf '   %-26s %s\n' "operation" "p50(ms)    p95(ms)    p99(ms)"
  printf '   %-26s %s\n' "authenticate/device" "$(pcts < /tmp/bench_auth)"
  printf '   %-26s %s\n' "storage PUT" "$(pcts < /tmp/bench_put)"
  printf '   %-26s %s\n' "storage GET" "$(pcts < /tmp/bench_get)"
}

# A dedicated cell for measurement: injecting netem needs NET_ADMIN (plain containers lack it).
BENCH_CELL="${BENCH_CELL:-nkglobal-bench-cell}"
BENCH_API="${BENCH_API:-http://127.0.0.1:20850}"
setup_bench_cell() {
  docker rm -f "$BENCH_CELL" >/dev/null 2>&1 || true
  docker run -d --name "$BENCH_CELL" --network nkglobal_default --cap-add=NET_ADMIN \
    -p 20850:7350 --entrypoint /nakama/nakama heroiclabs/nakama:3.41.0 \
    --name=bench-cell --database.address=yugabyte@yb:5433/yugabyte --logger.level=WARN >/dev/null
  echo "   measurement cell up ($BENCH_CELL, API $BENCH_API, NET_ADMIN) ✓"
  CELL="$BENCH_CELL"; API="$BENCH_API"; export CELL API
  for _ in $(seq 1 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/" || true)" = "200" ] && { echo "   measurement cell HTTP 200 ✓"; return 0; }
    sleep 2
  done
  echo "   measurement cell did not come up ✗"; return 1
}
teardown_bench_cell() { docker rm -f "$BENCH_CELL" >/dev/null 2>&1 || true; echo "   measurement cell removed ✓"; }

case "${1:-}" in
  --inject) inject "${2:?an ms value is required}"; exit 0;;
  --clear)  clear_tc; exit 0;;
  --cap-check) inject 1 && clear_tc; exit 0;;
  --setup)    setup_bench_cell; exit 0;;
  --teardown) teardown_bench_cell; exit 0;;
esac
clear_tc
run_case "BASELINE — no latency (same machine)"
trap clear_tc EXIT
for d in 60 120; do
  inject "$d"
  run_case "NETEM — ${d}ms one-way on the cell→YB path"
done
