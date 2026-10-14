#!/usr/bin/env bash
# Verify the repro plus its control cases. Needs this lab's YugabyteDB container.
#   bash repro/run.sh                     # uses container nkglobal-yb
#   YBC=<container> bash repro/run.sh
# Every case uses a FRESH database; the script SELF-CHECKS (prints "✗ UNEXPECTED" on a mismatch).
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.." || exit 1
YBC="${YBC:-nkglobal-yb}"
F1=yb-migrations/20180103142001_initial_schema.sql
YB() { docker exec -i "$YBC" /home/yugabyte/bin/ysqlsh -h 127.0.0.1 -U yugabyte -d "$1" "${@:2}"; }
fresh() { YB postgres -t -A -c "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1
          YB postgres -t -A -c "CREATE DATABASE $1" >/dev/null 2>&1; }
up_only() { awk '/-- \+migrate Up/{p=1;next} /-- \+migrate Down/{p=0} p' "$F1"; }
stmts() { up_only | sed 's/--.*$//' | tr '\n' ' ' | tr ';' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

run_case() { # $1=label $2=expected(OK|FAIL) $3=db $4=file $5=flags
  fresh "repro_$3"
  local rc=0
  YB "repro_$3" -q ${5:-} -v ON_ERROR_STOP=1 -f /dev/stdin < "$4" > /tmp/repro_out.txt 2>&1 || rc=$?
  local got=OK; [ "$rc" -ne 0 ] && got=FAIL
  local mark="✓ match"; [ "$got" != "$2" ] && mark="✗ UNEXPECTED (expected $2)"
  printf '  %-46s %-5s %s\n' "$1" "$got" "$mark"
  if [ "$got" = FAIL ]; then grep -E 'ERROR|DETAIL' /tmp/repro_out.txt | head -2 | cut -c1-112 | sed 's/^/        /'; fi
}

grep -vE '^(BEGIN|COMMIT);' repro/minimal.sql > /tmp/minimal_notx.sql
{ echo "BEGIN;"; stmts | sed 's/$/;/';          echo "COMMIT;"; } > /tmp/full_tx.sql
stmts | sed 's/$/;/' > /tmp/full_auto.sql

echo "YugabyteDB: $(YB postgres -t -A -c 'show server_version' | tr -d ' ')"
run_case "minimal repro, 3 statements, 1 transaction"        FAIL min   repro/minimal.sql "-1"
run_case "same 3 statements, NO transaction"                 OK    minx  /tmp/minimal_notx.sql
run_case "Nakama's real 3 statements, 1 transaction"         FAIL orig  repro/nakama-origin.sql "-1"
run_case "all of migration #1, 1 transaction"                FAIL full  /tmp/full_tx.sql "-1"
run_case "all of migration #1, STATEMENT BY STATEMENT (= yb-init)" OK auto /tmp/full_auto.sql
