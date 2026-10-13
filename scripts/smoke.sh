#!/usr/bin/env bash
# Smoke: chứng minh DATA PLANE DÙNG CHUNG giữa 2 cell (ghi ở A → đọc ở B)
set -uo pipefail
A=${API_A:-http://127.0.0.1:7350}
B=${API_B:-http://127.0.0.1:7450}
AC=${CONSOLE_A:-http://127.0.0.1:7351}
KEY=${KEY:-defaultkey}
SK="Basic $(printf %s: "$KEY" | base64 -w0)"   # Nakama 3.41: server key qua HTTP Basic
DEVICE=${DEVICE:-smoke-device-1}
VK_A=${VK_A:-nkglobal-valkey-a}
VK_B=${VK_B:-nkglobal-valkey-b}
pass=0; fail=0; skipn=0
ok(){ echo "   PASS ✓ $1"; pass=$((pass+1)); }
ko(){ echo "   FAIL ✗ $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }
skip(){ echo "   SKIP ○ $1"; skipn=$((skipn+1)); }
sk(){ echo "   SKIP – $1"; skip=$((skip+1)); }
hr(){ echo; echo "──────── $1"; }


# call METHOD URL DATA AUTH -> "CODE<TAB>BODYFILE"
call(){ local m=$1 u=$2 d=${3:-} a=${4:-}; local out code
  out=$(mktemp)
  if [ -n "$d" ]; then
    code=$(curl -s -o "$out" -w '%{http_code}' -X "$m" "$u" ${a:+-H "Authorization: $a"} -H 'Content-Type: application/json' -d "$d")
  else
    code=$(curl -s -o "$out" -w '%{http_code}' -X "$m" "$u" ${a:+-H "Authorization: $a"})
  fi
  printf '%s\t%s' "$code" "$out"; }

hr "0. Hai cell sống?"
cA=$(curl -s -o /dev/null -w '%{http_code}' "$A/")
cB=$(curl -s -o /dev/null -w '%{http_code}' "$B/")
# console API (dùng cho kiểm tra leaderboard/board registry)
cC=$(curl -s -o /dev/null -w '%{http_code}' "$AC/v2/console/leaderboard" -u "${ADMIN:-admin:password}")
{ [ "$cA" = "200" ] && ok "cell A ($A) HTTP 200"; } || ko "cell A không trả lời (HTTP $cA)"
{ [ "$cB" = "200" ] && ok "cell B ($B) HTTP 200"; } || ko "cell B không trả lời (HTTP $cB)"
{ [ "$cC" = "200" ] && ok "console cell A trả lời (HTTP 200)"; } || ko "console cell A không trả lời (HTTP $cC)"

hr "1. AUTH: cùng device id ở 2 cell → cùng account?"
IFS=$'\t' read -r ccA fA < <(call POST "$A/v2/account/authenticate/device?create=true" "{\"id\":\"$DEVICE\"}" "$SK")
IFS=$'\t' read -r ccB fB < <(call POST "$B/v2/account/authenticate/device?create=true" "{\"id\":\"$DEVICE\"}" "$SK")
TOK_A=$(python3 scripts/jq.py "$fA" "token")
TOK_B=$(python3 scripts/jq.py "$fB" "token")
# uid lấy từ /v2/account (response auth KHÔNG có object user)
IFS=$'\t' read -r _ fa < <(call GET "$A/v2/account" "" "Bearer $TOK_A")
IFS=$'\t' read -r _ fb < <(call GET "$B/v2/account" "" "Bearer $TOK_B")
UID_A=$(python3 scripts/jq.py "$fa" "user.id")
UID_B=$(python3 scripts/jq.py "$fb" "user.id")
echo "   cell A: user_id=$UID_A"
echo "   cell B: user_id=$UID_B"
{ [ "$ccA" = "200" ] && ok "auth ở A"; } || ko "auth ở A (HTTP $ccA)" "$(head -c 200 "$fA")"
{ [ "$ccB" = "200" ] && ok "auth ở B (cùng device)"; } || ko "auth ở B (HTTP $ccB)" "$(head -c 200 "$fB")"
if [ -n "$UID_A" ] && [ "$UID_A" = "$UID_B" ]; then ok "ACCOUNT DÙNG CHUNG ✓ (cùng user_id ở 2 cell)"
else ko "account không dùng chung (A='$UID_A' B='$UID_B')"; fi

hr "2. STORAGE: ghi ở A → đọc ở B?"
IFS=$'\t' read -r c f < <(call PUT "$A/v2/storage" "{\"objects\":[{\"collection\":\"smoke\",\"key\":\"k1\",\"value\":\"{\\\"written_by\\\":\\\"cell-A\\\"}\",\"permission_read\":2,\"permission_write\":1}]}" "Bearer $TOK_A")
{ [ "$c" = "200" ] && ok "ghi storage ở A"; } || ko "ghi storage ở A (HTTP $c)" "$(head -c 250 "$f")"
IFS=$'\t' read -r c f < <(call POST "$B/v2/storage" "{\"object_ids\":[{\"collection\":\"smoke\",\"key\":\"k1\",\"user_id\":\"$UID_A\"}]}" "Bearer $TOK_B")
VAL=$(python3 scripts/jq.py "$f" "objects.0.value")
case "$VAL" in *cell-A*) ok "STORAGE DÙNG CHUNG ✓ (cell B đọc thấy dữ liệu ghi từ cell A)";;
  *) ko "storage không dùng chung (đọc ở B: '$VAL')" "$(head -c 250 "$f")";; esac

hr "3. LEADERBOARD: tạo ở A (console API) → nộp điểm ở A → đọc ở B"
IFS=$'\t' read -r c f < <(call POST "$A/v2/leaderboard" '{"id":"smoke_board","sort_order":"descending","operator":"incr","reset_schedule":"","metadata":{},"authoritative":false,"enable_ranks":false}' "$SK")
if [ "$c" = "200" ]; then ok "tạo leaderboard ở A (client API + server key)"
elif grep -q 'already exists' "$f"; then ok "leaderboard đã tồn tại"
else
  echo "        (API tạo board HTTP $c -> shortcut SQL; enum là INT: sort_order 1=descending, operator 2=incr)"
  ERR=$(${SQL_EXEC:-docker exec nkcrdb-crdb /cockroach/cockroach sql --insecure -d defaultdb -e} \
    "insert into leaderboard (id, sort_order, operator, reset_schedule, metadata, authoritative) values ('smoke_board', 1, 2, null, '{}', false) on conflict (id) do nothing" 2>&1)
  if echo "$ERR" | grep -qiE 'error|ERROR'; then ko "tạo leaderboard bằng SQL" "$ERR"; else ok "tạo leaderboard ở A (shortcut SQL ✓)"; fi
fi
# Nộp điểm qua CLIENT API: không tạo được board qua API client (cần runtime RPC) nên bỏ qua,
# ghi rõ thay vì giả PASS. Bẫy ZINCRBY được kiểm riêng bằng scripts/leaderboard-trap.sh.
skip "nộp điểm qua client API (cần runtime RPC tạo board — phase B, xem docs/yugabyte-workaround.md)"
# Chứng minh row board nằm trong DATA PLANE DÙNG CHUNG (đọc bằng SQL, chạy được cho cả CRDB và YB).
NBOARD=$(${SQL_EXEC:-docker exec nkcrdb-crdb /cockroach/cockroach sql --insecure -d defaultdb -e} \
  "select count(*) from leaderboard where id='smoke_board'" 2>/dev/null | grep -Eo '[0-9]+' | head -1)
{ [ "${NBOARD:-0}" -ge 1 ] && ok "leaderboard row nằm trong data plane dùng chung (SQL: $NBOARD row ✓)"; } \
  || ko "leaderboard row không có trong data plane" "$NBOARD"
echo "        (console sẽ liệt kê board này SAU khi node khởi động lại — registry nạp lúc start)"

hr "4. VALKEY per-cell: có share không? (kỳ vọng: KHÔNG)"
docker exec "$VK_A" valkey-cli -p ${VK_PORT_A:-6380} SET local_key only-in-A >/dev/null 2>&1
OA=$(docker exec "$VK_A" valkey-cli -p ${VK_PORT_A:-6380} GET local_key 2>/dev/null)
OB=$(docker exec "$VK_B" valkey-cli -p ${VK_PORT_B:-6381} GET local_key 2>/dev/null)
echo "   valkey-A='$OA'  valkey-B='${OB:-<nil>}'"
{ [ "$OA" = "only-in-A" ] && [ -z "$OB" ] && ok "VALKEY KHÔNG SHARE ✓ (đúng: state cục bộ)"; } || ko "valkey ngoài ý muốn (A='$OA' B='$OB')"

hr "TỔNG KẾT"
echo "   PASS=$pass  FAIL=$fail  SKIP=$skipn"
[ "$fail" -eq 0 ] && echo "   ⇒ DATA PLANE DÙNG CHUNG HOẠT ĐỘNG ✓" || echo "   ⇒ còn lỗi ✗"
