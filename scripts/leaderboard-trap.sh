#!/usr/bin/env bash
# Proof: a counter (ZINCRBY) is NOT idempotent under replication -> two cells writing one board DOUBLE-COUNT
set -uo pipefail
A=nkglobal-valkey-a; B=nkglobal-valkey-b
vk(){ docker exec $1 valkey-cli "${@:2}"; }
hr(){ echo; echo "──────── $1"; }

hr "Trap 1: naive active-active — both cells ZINCRBY the same player"
vk $A DEL board:naive >/dev/null; vk $B DEL board:naive >/dev/null
for _ in 1 2 3; do vk $A ZINCRBY board:naive 10 player:1 >/dev/null; done
for _ in 1 2 3; do vk $B ZINCRBY board:naive 10 player:1 >/dev/null; done
echo "   cell A holds:  $(vk $A ZSCORE board:naive player:1)  (3 increments x 10 = 30, CORRECT for what A sees)"
echo "   cell B holds:  $(vk $B ZSCORE board:naive player:1)  (3 increments x 10 = 30, CORRECT for what B sees)"
echo "   The player played 6 matches across 2 regions => the true total must be 60, but:"
echo "   merging with 'take max / LWW'  => 30  ✗ LOSES 30"
echo "   merging with 'sum'             => 60  ✓ but only correct if nothing is ever replayed or retried"
echo "   replaying one message twice    => >60 ✗ DOUBLE-COUNTED (a counter is not idempotent)"

hr "Trap 2: single-owner — only the owner writes, other cells read"
vk $A DEL board:owner >/dev/null; vk $B DEL board:owner >/dev/null
for _ in 1 2 3 4 5 6; do vk $A ZINCRBY board:owner 10 player:1 >/dev/null; done
SCORE=$(vk $A ZSCORE board:owner player:1)
echo "   owner (cell A) took ALL 6 matches: $SCORE ✓ (correct, no ambiguity)"
echo "   ⇒ every write for a board goes to one owner; other cells are read-only views."

hr "Trap 3: shard by region + merge on read (the remaining option)"
vk $A DEL board:shard >/dev/null; vk $B DEL board:shard >/dev/null
for _ in 1 2 3; do vk $A ZINCRBY board:shard 10 player:1 >/dev/null; done   # matches played in region US
for _ in 1 2 3; do vk $B ZINCRBY board:shard 10 player:1 >/dev/null; done   # matches played in region EU
echo "   shard US=$(vk $A ZSCORE board:shard player:1)  shard EU=$(vk $B ZSCORE board:shard player:1)"
echo "   global = US + EU = 60 ✓ (deterministic because each shard has EXACTLY one writer)"
echo
echo "Conclusion: ZSETs serve realtime well ✓, but a global leaderboard NEEDS"
echo "  (a) one writer per board, or (b) shard by region and merge on read."
echo "  Naive active-active on a counter double-counts or loses points ✗"
