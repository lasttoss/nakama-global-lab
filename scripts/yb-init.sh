#!/usr/bin/env bash
# ============================================================================
# Data-plane init for YugabyteDB — runs AS AN INIT SERVICE in docker compose.
#
# Why not `nakama migrate up`: on YB it dies at migration
#   20250926112031-console-fine-grained-acl.sql  (SQLSTATE 42703 column "role" does not exist)
# but THE SAME SQL applies cleanly through ysqlsh, 20/20. So the fault is in how Nakama executes it, not the SQL.
#
# Workaround: apply the schema yourself and record migration_info, then let Nakama start WITHOUT migrate.
# Idempotent: a re-run applies only the migrations missing from migration_info.
# ============================================================================
set -euo pipefail
YB_HOST="${YB_HOST:-yb}"; YB_PORT="${YB_PORT:-5433}"
YB_USER="${YB_USER:-yugabyte}"; YB_DB="${YB_DB:-yugabyte}"
MIG_DIR="${MIG_DIR:-/migrations}"

YSQLSH="$(command -v ysqlsh 2>/dev/null || echo /home/yugabyte/bin/ysqlsh)"
[ -x "$YSQLSH" ] || { echo "FATAL: ysqlsh not found"; exit 1; }

q() { "$YSQLSH" -h "$YB_HOST" -p "$YB_PORT" -U "$YB_USER" -d "$YB_DB" -v ON_ERROR_STOP=1 "$@"; }

echo "== waiting for YSQL to be ready =="
for _ in $(seq 1 60); do q -t -A -c 'select 1' >/dev/null 2>&1 && { echo "   YSQL up ✓"; break; }; sleep 3; done
q -t -A -c 'select 1' >/dev/null 2>&1 || { echo "FATAL: YSQL is not answering"; exit 1; }

echo "== migration ledger table =="
q -c "CREATE TABLE IF NOT EXISTS migration_info (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());" >/dev/null

echo "== applying migrations (the 'Up' part only) =="
n=0; skipped=0
for f in $(ls "$MIG_DIR"/*.sql | sort); do
  id="$(basename "$f")"
  if [ "$(q -t -A -c "SELECT count(*) FROM migration_info WHERE id='$id'")" != "0" ]; then
    skipped=$((skipped+1)); continue
  fi
  sed '/-- +migrate Down/,$d' "$f" > /tmp/up.sql
  if q -f /tmp/up.sql >/dev/null 2>/tmp/mig.err; then
    q -c "INSERT INTO migration_info(id) VALUES ('$id') ON CONFLICT DO NOTHING;" >/dev/null
    n=$((n+1)); echo "   APPLY $id"
  else
    echo "   FAIL  $id"; head -5 /tmp/mig.err; exit 1
  fi
done
echo "== YB-INIT-OK ✓ applied=$n  skipped(already present)=$skipped  ledger total=$(q -t -A -c 'SELECT count(*) FROM migration_info') =="
