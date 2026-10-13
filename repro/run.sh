#!/usr/bin/env bash
# Kiểm repro tối thiểu + các ca đối chứng. Cần container YugabyteDB của lab này.
#   bash repro/run.sh                     # dùng container nkglobal-yb
#   YBC=<container> bash repro/run.sh
# Mọi ca dùng DB MỚI TINH; script TỰ KIỂM (in ✗ nếu kết quả khác kỳ vọng).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
YBC="${YBC:-nkglobal-yb}"
MIG=yb-migrations/20180103142001_initial_schema.sql
YB() { docker exec -i "$YBC" /home/yugabyte/bin/ysqlsh -h 127.0.0.1 -U yugabyte -d "$1" "${@:2}"; }
fresh() { YB postgres -t -A -c "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1
          YB postgres -t -A -c "CREATE DATABASE $1" >/dev/null 2>&1; }
up_only() { awk '/-- \+migrate Up/{p=1;next} /-- \+migrate Down/{p=0} p' "$MIG"; }
stmts() { up_only | sed 's/--.*$//' | tr '\n' ' ' | tr ';' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

run_case() { # $1=nhãn $2=kỳ vọng(OK|FAIL) $3=db $4=file $5=flags
  fresh "repro_$3"
  local rc=0
  YB "repro_$3" -q ${5:-} -v ON_ERROR_STOP=1 -f /dev/stdin < "$4" > /tmp/repro_out.txt 2>&1 || rc=$?
  local got=OK; [ "$rc" -ne 0 ] && got=FAIL
  local mark="✓ khớp"; [ "$got" != "$2" ] && mark="✗ KHÁC KỲ VỌNG ($2)"
  printf '  %-52s %-5s %s\n' "$1" "$got" "$mark"
  if [ "$got" = FAIL ]; then grep -E 'ERROR|DETAIL' /tmp/repro_out.txt | head -2 | cut -c1-118 | sed 's/^/        /'; fi
}

{ echo "BEGIN;"; stmts | head -n 3 | sed 's/$/;/'; echo "COMMIT;"; } > /tmp/repro_3.sql
{ echo "BEGIN;"; stmts | sed 's/$/;/';          echo "COMMIT;"; } > /tmp/repro_full.sql
stmts | sed 's/$/;/' > /tmp/repro_auto.sql
stmts | head -n 3 | sed 's/$/;/' > /tmp/repro_3_auto.sql

echo "YugabyteDB: $(YB postgres -t -A -c 'show server_version' | tr -d ' ')"
run_case "3 câu đầu (repro/repro.sql), 1 transaction"        FAIL  r3   repro/repro.sql "-1"
run_case "3 câu đó, KHÔNG có transaction (đối chứng)"        OK    r3a  /tmp/repro_3_auto.sql
run_case "cả file migration #1, 1 transaction"               FAIL  full /tmp/repro_full.sql "-1"
run_case "cả file migration #1, TỪNG CÂU (= đường yb-init)" OK    auto /tmp/repro_auto.sql
