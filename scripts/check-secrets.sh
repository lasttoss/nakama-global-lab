#!/usr/bin/env bash
# Scan tracked files for leaked secrets. Default dev values used by this lab are allowed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
files=$(git ls-files 2>/dev/null || find . -type f -not -path './.git/*' -not -path './yb-migrations/*')
pat='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{20,}|xox[baprs]-'
hits=$(echo "$files" | xargs -r grep -nEI "$pat" 2>/dev/null || true)
if [ -n "$hits" ]; then echo "POSSIBLE SECRETS:"; echo "$hits"; exit 1; fi
echo "OK: no obvious secrets in tracked files"
