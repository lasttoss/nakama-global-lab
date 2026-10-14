#!/usr/bin/env bash
# Quick A/B: bring up YB at a given tag + run migrate, report how many migrations applied
# usage: bash scripts/ab-migrate.sh <yb-tag> [isolation]
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
TAG=${1:?a tag is required, e.g. 2025.2.7.0-b107}
ISO=${2:-serializable}
echo "### A/B: YB=$TAG isolation=$ISO"

# switch the isolation level in the compose file
python3 - "$ISO" <<'PY'
import re,sys
iso=sys.argv[1]
p='docker-compose.yml'; s=open(p).read()
s=re.sub(r'ysql_default_transaction_isolation=\w+', f'ysql_default_transaction_isolation={iso}', s)
open(p,'w').write(s)
PY

docker compose down -v >/dev/null 2>&1
docker volume create nkglobal_yb_data >/dev/null
docker run --rm -u 0 -v nkglobal_yb_data:/mnt --entrypoint bash \
  "yugabytedb/yugabyte:${TAG}" -c 'chown -R 10001:100 /mnt' >/dev/null 2>&1
YB_TAG="$TAG" docker compose up -d yb >/dev/null 2>&1

for i in $(seq 1 48); do
  st=$(docker inspect -f '{{.State.Health.Status}}' nkglobal-yb 2>/dev/null || echo none)
  rn=$(docker inspect -f '{{.State.Status}}' nkglobal-yb 2>/dev/null || echo none)
  [ "$rn" = "exited" ] && { echo "YB exited ✗:"; docker logs --tail 12 nkglobal-yb; exit 1; }
  [ "$st" = "healthy" ] && { echo "YB healthy (~$((i*5))s)"; break; }
  sleep 5
done

docker exec nkglobal-yb bash -c "bin/ysqlsh -h 127.0.0.1 -U yugabyte -tAc 'select version()'" 2>/dev/null | head -1

# run migrate DIRECTLY (not through the entrypoint) so the result is unambiguous
echo "--- running migrate up ---"
docker run --rm --network nkglobal_default --entrypoint /nakama/nakama heroiclabs/nakama:3.41.0 \
  /nakama/nakama migrate up --database.address yugabyte@yb:5433/yugabyte 2>&1 | tail -4
echo "--- migrations applied ---"
docker exec nkglobal-yb bash -c "bin/ysqlsh -h 127.0.0.1 -U yugabyte -d yugabyte -tAc 'select count(*) from migration_info'" 2>/dev/null
docker exec nkglobal-yb bash -c "bin/ysqlsh -h 127.0.0.1 -U yugabyte -d yugabyte -tAc \"select count(*) from information_schema.tables where table_schema='public'\"" 2>/dev/null
