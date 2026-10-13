#!/usr/bin/env bash
# Thêm 1 cell mới vào data plane đang chạy, rồi CHỨNG MINH nó dùng chung dữ liệu.
#   bash scripts/add-cell.sh e [api_port] [console_port] [valkey_port]
# Cell đầu tiên (A) mặc định là 20350/20351; cell B là 20450/20451.
set -euo pipefail
cd "$(dirname "$0")/.."
ID="${1:?dùng: add-cell.sh <id> [api] [console] [valkey]}"
API="${2:-20750}"; CONSOLE="${3:-20751}"; VK="${4:-20780}"
SK="Basic $(printf %s: defaultkey | base64 -w0)"
REF_API="${REF_API:-http://127.0.0.1:20350}"   # cell A làm mốc so sánh

echo "== dựng cell '$ID' (api=$API console=$CONSOLE valkey=$VK) =="
CELL_ID="$ID" API_PORT="$API" CONSOLE_PORT="$CONSOLE" VK_PORT="$VK" \
  docker compose -p "nkglobal-cell-$ID" -f docker-compose.cell.yml up -d

echo "== chờ cell '$ID' trả lời =="
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CONSOLE/" || true)
  [ "$code" = "200" ] && { echo "   cell '$ID' HTTP 200 ✓"; break; }
  sleep 3
done

auth_uid(){ # $1=base url -> in user_id của cùng 1 device
  local t
  t=$(curl -s -X POST "$1/v2/account/authenticate/device?create=true" -H "Authorization: $SK" \
      -H 'Content-Type: application/json' -d '{"id":"cell-scale-shared-device"}' \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')
  curl -s "$1/v2/account" -H "Authorization: Bearer $t" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin).get("user",{}).get("id",""))'
}

echo "== chứng minh: cùng account trên cell A và cell '$ID'? =="
u_ref=$(auth_uid "$REF_API")
u_new=$(auth_uid "http://127.0.0.1:$API")
echo "   cell A       user_id=$u_ref"
echo "   cell '$ID'   user_id=$u_new"
[ -n "$u_ref" ] && [ "$u_ref" = "$u_new" ] \
  && echo "   ✓ ACCOUNT DÙNG CHUNG — cell '$ID' đã vào đúng data plane" \
  || { echo "   ✗ KHÔNG khớp — cell chưa nối đúng data plane"; exit 1; }

echo
echo "Cell '$ID' xong. Valkey riêng: docker exec nkglobal-cell-$ID-valkey valkey-cli -p 6379 set k v"
echo "Gỡ cell:  docker compose -p nkglobal-cell-$ID -f docker-compose.cell.yml down"
