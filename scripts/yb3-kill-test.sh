#!/usr/bin/env bash
# CHỨNG MINH replication factor 3: kill 1 tserver, cụm vẫn ghi/đọc; rồi cho node trở lại.
#   bash scripts/yb3-kill-test.sh
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
NODE=yb3-n1; HOST="${YB3_HOST:-n1}"; KILL=yb3-n3; DB=nakama3
Y() { timeout 20 docker exec "$NODE" /home/yugabyte/bin/ysqlsh -h "$HOST" -U yugabyte -d "$1" -t -A -c "$2" 2>/dev/null | tr -d ' '; }
probe() { # ghi + đọc 1 dòng, in OK/FAIL
  local n
  n="t$(date +%s%N)"
  Y "$DB" "INSERT INTO kill_probe(id, ts) VALUES ('$n', now()) ON CONFLICT DO NOTHING" >/dev/null 2>&1 || { echo "FAIL(ghi)"; return; }
  local c; c=$(Y "$DB" "SELECT count(*) FROM kill_probe WHERE id='$n'")
  [ "$c" = "1" ] && echo "OK" || echo "FAIL(đọc)"
}
Y "$DB" "CREATE TABLE IF NOT EXISTS kill_probe (id text PRIMARY KEY, ts timestamptz NOT NULL DEFAULT now())" >/dev/null 2>&1

echo "== 0. cụm đủ 3 node =="
docker exec "$NODE" bin/yugabyted status 2>/dev/null | grep -E '^[+|] *[0-9]+\.' | head -4 | sed 's/^/   /'
echo "   ghi/đọc: $(probe)"

echo "== 1. KILL $KILL (mất 1/3 bản sao) =="
docker kill "$KILL" >/dev/null 2>&1
sleep 5
n=0; ok=0
for _ in $(seq 1 10); do n=$((n+1)); [ "$(probe)" = "OK" ] && ok=$((ok+1)); done
echo "   sau khi mất 1 node: ghi/đọc OK $ok/$n lần"

echo "== 2. cho $KILL trở lại =="
docker start "$KILL" >/dev/null 2>&1
for i in $(seq 1 60); do docker exec "$KILL" /home/yugabyte/bin/ysqlsh -h "$HOST" -U yugabyte -d "$DB" -t -A -c 'select 1' >/dev/null 2>&1 && { echo "   node trở lại sau ${i}s"; break; }; sleep 2; done
echo "   ghi/đọc: $(probe)"
echo "   số dòng trong kill_probe: $(Y "$DB" 'select count(*) from kill_probe')"
