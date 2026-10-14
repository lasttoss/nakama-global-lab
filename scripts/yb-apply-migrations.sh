#!/usr/bin/env bash
# Apply the Nakama schema to YugabyteDB BY HAND (working around `nakama migrate up` failing on YB).
#
# Why: YB (2026.1.2) fails at migration 20250926112031-console-fine-grained-acl.sql with
#   SQLSTATE 42703 column "role" does not exist
# but THAT SAME SQL applies cleanly through ysqlsh (20/20 ✓). So the fault is in how Nakama runs it,
# not in the SQL. The workaround: apply the schema yourself, seed migration_info, then start Nakama
# WITHOUT `migrate up`.
#
# Usage: bash scripts/yb-apply-migrations.sh <yb-container> <db> [user] [port]
#   vd: bash scripts/yb-apply-migrations.sh nkglobal-yb nakama_ybt yugabyte 5433
set -euo pipefail
YB="${1:?yb container}"; DB="${2:?database}"; U="${3:-yugabyte}"; P="${4:-5433}"
URL="https://raw.githubusercontent.com/heroiclabs/nakama/master/migrate/sql"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

echo "== 1. fetch Nakama's migration SQL =="
curl -s "https://api.github.com/repos/heroiclabs/nakama/contents/migrate/sql" \
 | python3 -c "import json,sys;[print(x['name']) for x in json.load(sys.stdin) if x['name'].endswith('.sql')]" > "$work/LIST"
n=$(wc -l < "$work/LIST"); echo "   $n file"
while read -r f; do curl -s -o "$work/$f" "$URL/$f"; done < "$work/LIST"

echo "== 2. apply the 'Up' part in order (strip the Down part!) =="
docker exec "$YB" bash -lc "ysqlsh -h 127.0.0.1 -p $P -U $U -c 'drop database if exists $DB'" >/dev/null
docker exec "$YB" bash -lc "ysqlsh -h 127.0.0.1 -p $P -U $U -c 'create database $DB'" >/dev/null
mkdir -p "$work/up"; docker cp "$work/." "$YB:/tmp/ybmig" >/dev/null
docker exec "$YB" bash -lc "cd /tmp/ybmig && i=0 && for f in \$(sort LIST); do
  i=\$((i+1)); sed '/-- +migrate Down/,\$d' \"\$f\" > /tmp/up.sql
  if ysqlsh -h 127.0.0.1 -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -f /tmp/up.sql >/dev/null 2>/tmp/e; then
    echo \"  OK \$i/$n \$f\"; else echo \"  FAIL \$i/$n \$f\"; head -3 /tmp/e; exit 9; fi
done"

echo "== 3. create + seed migration_info (id = the .sql file name) =="
docker exec "$YB" bash -lc "ysqlsh -h 127.0.0.1 -p $P -U $U -d $DB -c \"
  CREATE TABLE IF NOT EXISTS migration_info (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());\" " >/dev/null
{ echo "BEGIN;"
  while read -r f; do echo "INSERT INTO migration_info(id) VALUES ('$f') ON CONFLICT (id) DO NOTHING;"; done < "$work/LIST"
  echo "COMMIT; SELECT count(*) AS seeded FROM migration_info;"; } > "$work/seed.sql"
docker cp "$work/seed.sql" "$YB:/tmp/seed.sql" >/dev/null
docker exec "$YB" bash -lc "ysqlsh -h 127.0.0.1 -p $P -U $U -d $DB -v ON_ERROR_STOP=1 -f /tmp/seed.sql" | tail -4

echo "== DONE. Start Nakama WITHOUT 'migrate up': =="
echo "   docker run -d --name nakama-yb --network <net> --entrypoint /nakama/nakama heroiclabs/nakama:3.41.0 \\"
echo "     --database.address $U@<yb-host>:$P/$DB --socket.port 7350 --console.port 7351"
