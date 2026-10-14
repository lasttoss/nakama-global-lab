#!/usr/bin/env bash
# A process-based generator (xargs + curl) — not limited by the Python GIL,
# so it can find the cell's REAL ceiling.
#   bash scripts/bench-load.sh --api http://127.0.0.1:20350 --conc 50 --requests 4000 --op auth
set -uo pipefail
export LC_ALL=C
API=http://127.0.0.1:20350; CONC=50; REQ=4000; OP=auth
while [ $# -gt 0 ]; do case "$1" in
  --api) API="$2"; shift 2;; --conc) CONC="$2"; shift 2;;
  --requests) REQ="$2"; shift 2;; --op) OP="$2"; shift 2;;
  *) echo "unknown argument: $1" >&2; exit 2;; esac; done
SK=$(printf 'Basic %s' "$(printf %s: defaultkey | base64 -w0)")
TOK=$(curl -s -X POST "$API/v2/account/authenticate/device?create=true" -H "Authorization: $SK" \
      -H 'Content-Type: application/json' -d '{"id":"load-client-device"}' \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
UID_=$(curl -s "$API/v2/account" -H "Authorization: Bearer $TOK" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["user"]["id"])')
rm -f /tmp/load_times.txt /tmp/load_codes.txt
echo "api=$API conc=$CONC requests=$REQ op=$OP"
t0=$(date +%s.%N)
if [ "$OP" = "auth" ]; then
  seq 1 "$REQ" | xargs -P "$CONC" -I{} curl -s -o /dev/null --max-time 30 \
    -w '%{time_total} %{http_code}\n' -X POST "$API/v2/account/authenticate/device?create=true" \
    -H "Authorization: $SK" -H 'Content-Type: application/json' -d '{"id":"load-client-device"}' \
    >> /tmp/load_times.txt
else
  seq 1 "$REQ" | xargs -P "$CONC" -I{} curl -s -o /dev/null --max-time 30 \
    -w '%{time_total} %{http_code}\n' "$API/v2/storage/load?user_id=$UID_" \
    -H "Authorization: Bearer $TOK" >> /tmp/load_times.txt
fi
t1=$(date +%s.%N)
python3 - "$REQ" <<'PY'
import sys
rows=[l.split() for l in open('/tmp/load_times.txt') if l.strip()]
import collections
t=[float(a) for a,_ in rows]; codes=collections.Counter(b for _,b in rows)
t.sort(); n=len(t)
p=lambda q: t[min(n-1,int(round(q*(n-1))))]*1000
print(f"  finished {n}/{sys.argv[1]} requests · http_code: {dict(codes)}")
print(f"  p50={p(.5):.1f}ms  p95={p(.95):.1f}ms  p99={p(.99):.1f}ms")
PY
awk -v a="$t0" -v b="$t1" -v n="$REQ" 'BEGIN{printf "  wall=%.2fs  ⇒ %.0f req/s\n", b-a, n/(b-a)}'
