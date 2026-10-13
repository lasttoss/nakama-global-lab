#!/usr/bin/env bash
# Xác minh 20 file SQL khớp MANIFEST.sha256 (phát hiện trôi/khác bản).
set -euo pipefail
cd "$(dirname "$0")/../yb-migrations"
sha256sum -c MANIFEST.sha256 --quiet
n=$(ls -1 *.sql | wc -l)
[ "$n" -eq 20 ] || { echo "FAIL: expected 20 migration files, found $n"; exit 1; }
echo "OK: $n migration files match MANIFEST.sha256"
