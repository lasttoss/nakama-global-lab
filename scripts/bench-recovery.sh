#!/usr/bin/env bash
# Cell chết thì mất gì? Kill hẳn 1 cell (cell đo) giữa lúc đang có traffic, đo:
#   - bao nhiêu request thất bại với client CHỈ biết 1 cell
#   - mất bao lâu tới khi client có danh sách cell chuyển sang cell khác và thành công
#   - account có còn nguyên trên cell kia không (data plane dùng chung)
#   bash scripts/bench-recovery.sh
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
BENCH=nkglobal-bench-cell; BENCH_API=http://127.0.0.1:20850
B_API=http://127.0.0.1:20450
SK=$(printf 'Basic %s' "$(printf %s: defaultkey | base64 -w0)")
DEV=recovery-device-01

auth() { # $1=api -> in user_id (rỗng nếu fail)
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

echo "== 0. cell đo có sống? (dựng nếu chưa) =="
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$BENCH_API/" 2>/dev/null)" != "200" ]; then
  bash scripts/bench-latency.sh --setup >/dev/null 2>&1
fi
uid_before=$(auth "$BENCH_API") || { echo "   cell đo không lên ✗"; exit 1; }
echo "   account trên cell đo: $uid_before"

echo "== 1. traffic đang chạy (2 giây) =="
ok=0
for _ in $(seq 1 10); do auth "$BENCH_API" >/dev/null 2>&1 && ok=$((ok+1)); done
echo "   $ok/10 request thành công"

echo "== 2. KILL cell đo (giả lập cell chết đột ngột) =="
docker kill "$BENCH" >/dev/null 2>&1
t0=$(date +%s.%N)
echo "   đã kill lúc $(date +%T)"

echo "== 3. client CÓ danh sách cell: đo từ lúc kill tới lúc cell B phục vụ được =="
dead_fail=0; ok_after=""
for _ in $(seq 1 30); do
  auth "$BENCH_API" >/dev/null 2>&1 || dead_fail=$((dead_fail+1))
  u=$(auth "$B_API" 2>/dev/null)
  if [ -n "$u" ]; then
    t1=$(date +%s.%N)
    ok_after=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    printf '   cell B trả lời OK — cách lúc kill %s giây (đã thử cell chết %d lần)\n' "$ok_after" "$dead_fail"
    printf '   account trên cell B: %s\n' "$u"
    [ "$u" = "$uid_before" ] && echo "   ✓ CÙNG account — cell chết KHÔNG mất dữ liệu (data plane dùng chung)" \
                             || echo "   ✗ khác account"
    break
  fi
  sleep 0.2
done

echo "== 4. client CHỈ biết cell đó (không danh sách): mọi request đều hỏng =="
blind=0
for _ in $(seq 1 5); do auth "$BENCH_API" >/dev/null 2>&1 || blind=$((blind+1)); sleep 0.2; done
echo "   $blind/5 request thất bại ✗ — cell chết mà client không biết đi đâu"
echo "   ⇒ tổng request chết vì cell đó: $((blind + dead_fail))"
echo
echo "Cell đo đã bị kill (không tự dựng lại). Dọn: docker rm -f $BENCH"
