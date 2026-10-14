#!/usr/bin/env bash
# Tell "the cache is still warming" apart from "memory is leaking" for a container cgroup.
#
# Why this exists: `docker stats` (and memory.current) ADDS page cache into one number.
# RocksDB reads files, page cache grows, and the result looks exactly like a leak. memory.stat splits it:
#   anon = actual process memory (a leak would live here)
#   file = page cache, which the OS reclaims on demand (not a leak)
#
#   bash scripts/bench-memory.sh --containers nkglobal-yb,nkglobal-nakama-a --duration 600
#
# Prints CSV per timestamp; at the end prints a first-to-last delta table per container.
set -uo pipefail
export LC_ALL=C

CONTAINERS="nkglobal-yb,nkglobal-nakama-a"
INTERVAL=15; DURATION=600; OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --containers) CONTAINERS="$2"; shift 2;;
  --interval)   INTERVAL="$2";   shift 2;;
  --duration)   DURATION="$2";   shift 2;;
  --out)        OUT="$2";        shift 2;;
  *) echo "unknown argument: $1" >&2; exit 2;; esac; done
[ -n "$OUT" ] || OUT="/tmp/bench-memory-$(date +%Y%m%d-%H%M%S).csv"

IFS=',' read -r -a NAMES <<< "$CONTAINERS"
printf 'elapsed_s,container,current_mib,anon_mib,file_mib\n' > "$OUT"

# Read three numbers from the CONTAINER'S OWN cgroup (no guessing host paths).
read_cgroup() {
  docker exec "$1" sh -c 'cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.stat' 2>/dev/null \
  | awk '/^[0-9]+$/ {cur=$1/1048576; next}
         $1=="anon"  {anon=$2/1048576}
         $1=="file"  {file=$2/1048576}
         END {if (cur=="") exit 1; printf "%.1f %.1f %.1f\n", cur, anon, file}'
}

START=$(date +%s)
while :; do
  ELAPSED=$(( $(date +%s) - START ))
  LINE=""
  for c in "${NAMES[@]}"; do
    read -r cur anon file < <(read_cgroup "$c")
    # Do not rely on read's exit status: read returns 1 at EOF without a '\n'
    # even though it assigned every variable. An empty-value check is the right test.
    [ -n "${cur:-}" ] || { printf '  %-22s (unreadable)\n' "$c"; continue; }
    printf '%s,%s,%s,%s,%s\n' "$ELAPSED" "$c" "$cur" "$anon" "$file" >> "$OUT"
    LINE+=$(printf ' %s: %.0f/%.0f/%.0f' "${c#nkglobal-}" "$cur" "$anon" "$file")
  done
  printf 't=%4ss  current/anon/file MiB —%s\n' "$ELAPSED" "$LINE"
  [ "$ELAPSED" -ge "$DURATION" ] && break
  sleep "$INTERVAL"
done

echo
echo "════ SUMMARY (first → last, MiB) — source: $OUT"
printf '%-22s %-22s %-22s\n' "container" "anon (process)" "file (page cache)"
for c in "${NAMES[@]}"; do
  awk -F, -v c="$c" '
    $2==c { if (first=="") {fa=$4; ff=$5; first=1}; la=$4; lf=$5 }
    END { printf "%-22s %+7.1f → %-11.1f %+7.1f → %-11.1f\n", c, la-fa, la, lf-ff, lf }' "$OUT"
done
echo
echo "How to read it: rising anon ⇒ real process memory. Rising file ⇒ reclaimable page cache."
echo "To call it a LEAK you must see anon RISE EVEN WHEN THERE IS NO TRAFFIC."
