#!/usr/bin/env bash
# ============================================================================
# Data plane init cho YugabyteDB — chạy NHƯ MỘT SERVICE INIT trong docker compose.
#
# Vì sao không dùng `nakama migrate up`: trên YB nó chết ở migration
#   20250926112031-console-fine-grained-acl.sql  (SQLSTATE 42703 column "role" does not exist)
# nhưng CÙNG SQL ĐÓ áp bằng ysqlsh thì sạch 20/20. ⇒ lỗi ở cách Nakama thực thi, không phải SQL.
#
# Cách né: tự áp schema + tự ghi sổ migration_info, rồi để Nakama start KHÔNG kèm migrate.
# Idempotent: chạy lại chỉ áp những migration chưa có trong migration_info.
# ============================================================================
set -euo pipefail
YB_HOST="${YB_HOST:-yb}"; YB_PORT="${YB_PORT:-5433}"
YB_USER="${YB_USER:-yugabyte}"; YB_DB="${YB_DB:-yugabyte}"
MIG_DIR="${MIG_DIR:-/migrations}"

YSQLSH="$(command -v ysqlsh 2>/dev/null || echo /home/yugabyte/bin/ysqlsh)"
[ -x "$YSQLSH" ] || { echo "FATAL: không tìm thấy ysqlsh"; exit 1; }

q() { "$YSQLSH" -h "$YB_HOST" -p "$YB_PORT" -U "$YB_USER" -d "$YB_DB" -v ON_ERROR_STOP=1 "$@"; }

echo "== chờ YSQL sẵn sàng =="
for _ in $(seq 1 60); do q -t -A -c 'select 1' >/dev/null 2>&1 && { echo "   YSQL up ✓"; break; }; sleep 3; done
q -t -A -c 'select 1' >/dev/null 2>&1 || { echo "FATAL: YSQL không trả lời"; exit 1; }

echo "== bảng sổ migration =="
q -c "CREATE TABLE IF NOT EXISTS migration_info (id text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());" >/dev/null

echo "== áp migration (chỉ phần 'Up') =="
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
echo "== YB-INIT-OK ✓ áp mới=$n  bỏ qua(đã có)=$skipped  tổng sổ=$(q -t -A -c 'SELECT count(*) FROM migration_info') =="
