#!/usr/bin/env bash
# Phân biệt "cache đang ấm" với "rò rỉ RAM" cho một cgroup container.
#
# Vì sao cần: `docker stats` (và memory.current) GỘP page cache vào một con số.
# RocksDB đọc file thì page cache tăng, trông y hệt rò rỉ. memory.stat tách được:
#   anon = bộ nhớ tiến trình thật sự (rò rỉ sẽ nằm ở đây)
#   file = page cache, hệ điều hành thu hồi được khi cần (không phải rò rỉ)
#
#   bash scripts/bench-memory.sh --containers nkglobal-yb,nkglobal-nakama-a --duration 600
#
# In ra CSV mỗi mốc thời gian; cuối cùng in bảng delta đầu→cuối cho từng container.
set -uo pipefail
export LC_ALL=C

CONTAINERS="nkglobal-yb,nkglobal-nakama-a"
INTERVAL=15; DURATION=600; OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --containers) CONTAINERS="$2"; shift 2;;
  --interval)   INTERVAL="$2";   shift 2;;
  --duration)   DURATION="$2";   shift 2;;
  --out)        OUT="$2";        shift 2;;
  *) echo "tham số lạ: $1" >&2; exit 2;; esac; done
[ -n "$OUT" ] || OUT="/tmp/bench-memory-$(date +%Y%m%d-%H%M%S).csv"

IFS=',' read -r -a NAMES <<< "$CONTAINERS"
printf 'elapsed_s,container,current_mib,anon_mib,file_mib\n' > "$OUT"

# Đọc 3 số từ cgroup CỦA CHÍNH container (không đoán đường dẫn trên host).
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
    # Không dựa vào mã trả về của read: read trả 1 khi EOF mà thiếu '\n'
    # dù đã gán đủ biến. Kiểm tra giá trị rỗng mới là điều kiện đúng.
    [ -n "${cur:-}" ] || { printf '  %-22s (không đọc được)\n' "$c"; continue; }
    printf '%s,%s,%s,%s,%s\n' "$ELAPSED" "$c" "$cur" "$anon" "$file" >> "$OUT"
    LINE+=$(printf ' %s: %.0f/%.0f/%.0f' "${c#nkglobal-}" "$cur" "$anon" "$file")
  done
  printf 't=%4ss  current/anon/file MiB —%s\n' "$ELAPSED" "$LINE"
  [ "$ELAPSED" -ge "$DURATION" ] && break
  sleep "$INTERVAL"
done

echo
echo "════ TỔNG KẾT (đầu → cuối, MiB) — nguồn: $OUT"
printf '%-22s %-22s %-22s\n' "container" "anon (tiến trình)" "file (page cache)"
for c in "${NAMES[@]}"; do
  awk -F, -v c="$c" '
    $2==c { if (first=="") {fa=$4; ff=$5; first=1}; la=$4; lf=$5 }
    END { printf "%-22s %+7.1f → %-11.1f %+7.1f → %-11.1f\n", c, la-fa, la, lf-ff, lf }' "$OUT"
done
echo
echo "Đọc kết quả: anon tăng ⇒ bộ nhớ tiến trình thật sự. file tăng ⇒ page cache đọc lại được."
echo "Để kết luận 'rò rỉ', cần thấy anon TĂNG ĐỀU kể cả khi KHÔNG có tải."
