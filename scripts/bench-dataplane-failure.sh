#!/usr/bin/env bash
# Data plane chết thì cell ra sao? Thử 2 kiểu: TREO (pause) và TẮT (stop) container YugabyteDB.
#   bash scripts/bench-dataplane-failure.sh
# Đo: client có lỗi gì, cell có tự phục hồi không, dữ liệu còn nguyên không.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
YB=nkglobal-yb; API=http://127.0.0.1:20350
SK=$(printf 'Basic %s' "$(printf %s: defaultkey | base64 -w0)")
SQL() { timeout 25 docker exec "$YB" /home/yugabyte/bin/ysqlsh -h 127.0.0.1 -U yugabyte -d yugabyte -t -A -c "$1" 2>/dev/null | tr -d ' '; }

auth_ok() { # 0 nếu 1 request auth thành công (timeout 4s)
  curl -sf --max-time 4 -X POST "$API/v2/account/authenticate/device?create=true" \
    -H "Authorization: $SK" -H 'Content-Type: application/json' -d '{"id":"dpfail-device"}' >/dev/null 2>&1
}
burst() { # $1=n  -> in "ok fail"
  local ok=0 f=0
  for _ in $(seq 1 "$1"); do auth_ok && ok=$((ok+1)) || f=$((f+1)); done
  echo "$ok $f"
}
yb_ready() { [ -n "$(SQL 'select 1')" ]; }          # YB tự trả lời được chưa
storage_ok() { # 0 nếu ghi được 1 object
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
wait_for() { # $1=tên phép thử $2=số giây tối đa $3=t0 -> in "tên: Ns"
  local n=0
  while [ "$n" -lt "$2" ]; do
    "$1" && { echo "   $1 OK sau $(( $(date +%s) - $3 ))s kể từ lúc YB trả lời được"; return 0; }
    sleep 1; n=$((n+1))
  done
  echo "   $1: >$2 s ✗"
}

echo "== 0. baseline =="
before=$(SQL "select count(*) from migration_info"); echo "   migration_info=$before"; echo "   auth: $(burst 3)"

for mode in pause stop; do
  echo
  echo "== 1. $mode YB (data plane $([ "$mode" = pause ] && echo 'TREO — nặng hơn' || echo 'TẮT hẳn')) =="
  docker "$mode" "$YB" >/dev/null 2>&1
  echo "   client trong lúc YB $mode: $(burst 4) (ok fail) — chờ tối đa 4s mỗi request"
  echo "   cell Nakama còn chạy? $(docker ps --format '{{.Names}}' | grep -c nkglobal-nakama-a) container ✓ (không tự thoát)"
  if [ "$mode" = pause ]; then docker unpause "$YB" >/dev/null 2>&1; else docker start "$YB" >/dev/null 2>&1; fi
  echo "   đã $([ "$mode" = pause ] && echo unpause || echo start) YB, chờ YB tự trả lời:"
  n=0; while ! yb_ready && [ $n -lt 90 ]; do sleep 1; n=$((n+1)); done
  if ! yb_ready; then echo "   YB không trở lại sau 90s ✗ — dừng ở đây"; exit 1; fi
  t0=$(date +%s); echo "   YB trả lời được sau ${n}s; từ đây đo cell tự phục hồi:"
  wait_for auth_ok 90 "$t0"
  wait_for storage_ok 90 "$t0"
  after=$(SQL "select count(*) from migration_info")
  echo "   dữ liệu: migration_info=$after $([ "$before" = "$after" ] && echo '✓ không mất' || echo '✗ MẤT DỮ LIỆU')"
done

echo
echo "== 2. kiểm tra tổng thể sau khi data plane sống lại =="
make smoke 2>&1 | grep -E "FAIL|PASS=|⇒" | tail -5
