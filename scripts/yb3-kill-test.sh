#!/usr/bin/env bash
# PROVE replication factor 3: kill one tserver, the cluster still reads and writes, then let it rejoin.
#   bash scripts/yb3-kill-test.sh
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
NODE=yb3-n1; HOST="${YB3_HOST:-n1}"; KILL=yb3-n3; DB=nakama3
Y() { timeout 20 docker exec "$NODE" /home/yugabyte/bin/ysqlsh -h "$HOST" -U yugabyte -d "$1" -t -A -c "$2" 2>/dev/null | tr -d ' '; }
probe() { # write + read one row, prints OK/FAIL
  local n
  n="t$(date +%s%N)"
  Y "$DB" "INSERT INTO kill_probe(id, ts) VALUES ('$n', now()) ON CONFLICT DO NOTHING" >/dev/null 2>&1 || { echo "FAIL(ghi)"; return; }
  local c; c=$(Y "$DB" "SELECT count(*) FROM kill_probe WHERE id='$n'")
  [ "$c" = "1" ] && echo "OK" || echo "FAIL(read)"
}
Y "$DB" "CREATE TABLE IF NOT EXISTS kill_probe (id text PRIMARY KEY, ts timestamptz NOT NULL DEFAULT now())" >/dev/null 2>&1

echo "== 0. the cluster has all 3 nodes =="
docker exec "$NODE" bin/yugabyted status 2>/dev/null | grep -E '^[+|] *[0-9]+\.' | head -4 | sed 's/^/   /'
echo "   read/write: $(probe)"

echo "== 1. KILL $KILL (losing 1 of 3 replicas) =="
docker kill "$KILL" >/dev/null 2>&1
sleep 5
n=0; ok=0
for _ in $(seq 1 10); do n=$((n+1)); [ "$(probe)" = "OK" ] && ok=$((ok+1)); done
echo "   after losing one node: read/write OK $ok/$n times"

echo "== 2. bring $KILL back =="
docker start "$KILL" >/dev/null 2>&1
for i in $(seq 1 60); do docker exec "$KILL" /home/yugabyte/bin/ysqlsh -h "$HOST" -U yugabyte -d "$DB" -t -A -c 'select 1' >/dev/null 2>&1 && { echo "   node rejoined after ${i}s"; break; }; sleep 2; done
echo "   read/write: $(probe)"
echo "   rows in kill_probe: $(Y "$DB" 'select count(*) from kill_probe')"
