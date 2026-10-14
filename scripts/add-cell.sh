#!/usr/bin/env bash
# Add a new cell to a running data plane, then PROVE it shares the same data.
#   bash scripts/add-cell.sh e [api_port] [console_port] [valkey_port]
# The first cell (A) defaults to 20350/20351; cell B is 20450/20451.
set -euo pipefail
cd "$(dirname "$0")/.."
ID="${1:?usage: add-cell.sh <id> [api] [console] [valkey]}"
API="${2:-20750}"; CONSOLE="${3:-20751}"; VK="${4:-20780}"
SK="Basic $(printf %s: defaultkey | base64 -w0)"
REF_API="${REF_API:-http://127.0.0.1:20350}"   # cell A as the comparison baseline

echo "== bringing up cell '$ID' (api=$API console=$CONSOLE valkey=$VK) =="
CELL_ID="$ID" API_PORT="$API" CONSOLE_PORT="$CONSOLE" VK_PORT="$VK" \
  docker compose -p "nkglobal-cell-$ID" -f docker-compose.cell.yml up -d

echo "== waiting for cell '$ID' to answer =="
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CONSOLE/" || true)
  [ "$code" = "200" ] && { echo "   cell '$ID' HTTP 200 ✓"; break; }
  sleep 3
done

auth_uid(){ # $1=base url -> prints the user_id of the same device
  local t
  t=$(curl -s -X POST "$1/v2/account/authenticate/device?create=true" -H "Authorization: $SK" \
      -H 'Content-Type: application/json' -d '{"id":"cell-scale-shared-device"}' \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')
  curl -s "$1/v2/account" -H "Authorization: Bearer $t" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("user",{}).get("id",""))'
}

echo "== proof: same account on cell A and cell '$ID'? =="
u_ref=$(auth_uid "$REF_API")
u_new=$(auth_uid "http://127.0.0.1:$API")
echo "   cell A       user_id=$u_ref"
echo "   cell '$ID'   user_id=$u_new"
[ -n "$u_ref" ] && [ "$u_ref" = "$u_new" ] \
  && echo "   ✓ ACCOUNT IS SHARED — cell '$ID' joined the right data plane" \
  || { echo "   ✗ MISMATCH — cell is not on the same data plane"; exit 1; }

echo
echo "Cell '$ID' done. Its own Valkey: docker exec nkglobal-cell-$ID-valkey valkey-cli -p 6379 set k v"
echo "Remove it:  docker compose -p nkglobal-cell-$ID -f docker-compose.cell.yml down"
