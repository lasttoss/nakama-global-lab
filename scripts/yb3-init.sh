#!/usr/bin/env bash
# Apply the 20 migrations to the 3-node YB cluster statement by statement (the only path that works — see docs/nakama-with-yugabytedb.md)
# then seed migration_info so Nakama can start without 'migrate up'.
#   bash scripts/yb3-init.sh [node]        # defaults to node n1
set -euo pipefail
cd "$(dirname "$0")/.."
NODE="${1:-yb3-n1}"
HOST="${YB3_HOST:-n1}"   # YSQL binds to the node name, not 127.0.0.1
DB=nakama3
Y() { docker exec -i "$NODE" /home/yugabyte/bin/ysqlsh -h "$HOST" -U yugabyte -d "$1" "${@:2}"; }
for _ in $(seq 1 60); do Y postgres -t -A -c 'select 1' >/dev/null 2>&1 && break; sleep 3; done
Y postgres -q -c "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true
Y postgres -q -c "CREATE DATABASE $DB"
Y "$DB" -q -c "CREATE TABLE IF NOT EXISTS migration_info (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
applied=0; skipped=0
for f in $(ls yb-migrations/*.sql | sort); do
  b=$(basename "$f")
  if [ "$(Y "$DB" -t -A -c "select count(*) from migration_info where id='$b'" | tr -d ' ')" = "1" ]; then
    skipped=$((skipped+1)); continue
  fi
  awk '/-- \+migrate Up/{p=1;next} /-- \+migrate Down/{p=0} p' "$f" \
    | Y "$DB" -q -v ON_ERROR_STOP=1 -f /dev/stdin
  Y "$DB" -q -c "INSERT INTO migration_info(id) VALUES ('$b') ON CONFLICT DO NOTHING"
  applied=$((applied+1))
done
echo "applied=$applied skipped=$skipped (DB=$DB on $NODE)"
