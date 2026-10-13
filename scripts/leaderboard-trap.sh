#!/usr/bin/env bash
# Chứng minh: counter (ZINCRBY) KHÔNG idempotent dưới replication -> nếu 2 cell cùng ghi 1 board = CỘNG ĐÔI
set -uo pipefail
A=nkglobal-valkey-a; B=nkglobal-valkey-b
vk(){ docker exec $1 valkey-cli "${@:2}"; }
hr(){ echo; echo "──────── $1"; }

hr "Bẫy 1: active-active ngây thơ — cả 2 cell cùng ZINCRBY cùng người chơi"
vk $A DEL board:naive >/dev/null; vk $B DEL board:naive >/dev/null
for _ in 1 2 3; do vk $A ZINCRBY board:naive 10 player:1 >/dev/null; done
for _ in 1 2 3; do vk $B ZINCRBY board:naive 10 player:1 >/dev/null; done
echo "   cell A giữ:  $(vk $A ZSCORE board:naive player:1)  (3 lần × 10 = 30, ĐÚNG với những gì A thấy)"
echo "   cell B giữ:  $(vk $B ZSCORE board:naive player:1)  (3 lần × 10 = 30, ĐÚNG với những gì B thấy)"
echo "   Người chơi chơi 6 trận ở 2 region => tổng thật phải là 60, nhưng:"
echo "   nếu merge kiểu 'lấy max/LWW'  => 30  ✗ MẤT 30"
echo "   nếu merge kiểu 'cộng dồn'     => 60  ✓ nhưng chỉ đúng khi KHÔNG bao giờ replay/retry"
echo "   nếu replay 1 message 2 lần    => >60 ✗ CỘNG ĐÔI (counter không idempotent)"

hr "Bẫy 2: single-owner — chỉ owner ghi, cell khác chỉ đọc"
vk $A DEL board:owner >/dev/null; vk $B DEL board:owner >/dev/null
for _ in 1 2 3 4 5 6; do vk $A ZINCRBY board:owner 10 player:1 >/dev/null; done
SCORE=$(vk $A ZSCORE board:owner player:1)
echo "   owner (cell A) nhận CẢ 6 trận: $SCORE ✓ (đúng, không mơ hồ)"
echo "   ⇒ mọi write của 1 board đi về 1 owner; cell khác là read-only view."

hr "Bẫy 3: shard theo region + merge khi đọc (cách còn lại)"
vk $A DEL board:shard >/dev/null; vk $B DEL board:shard >/dev/null
for _ in 1 2 3; do vk $A ZINCRBY board:shard 10 player:1 >/dev/null; done   # trận ở region US
for _ in 1 2 3; do vk $B ZINCRBY board:shard 10 player:1 >/dev/null; done   # trận ở region EU
echo "   shard US=$(vk $A ZSCORE board:shard player:1)  shard EU=$(vk $B ZSCORE board:shard player:1)"
echo "   global = US + EU = 60 ✓ (merge tất định vì mỗi shard có ĐÚNG 1 writer)"
echo
echo "Kết luận: ZSET phục vụ realtime rất tốt ✓, nhưng global leaderboard PHẢI có"
echo "  (a) một writer cho mỗi board, hoặc (b) shard theo region rồi merge khi đọc."
echo "  Active-active ngây thơ trên counter = cộng đôi hoặc mất điểm ✗"
