#!/usr/bin/env bash
# Verify the 20 SQL files match MANIFEST.sha256 (catches drift or a swapped file).
set -euo pipefail
cd "$(dirname "$0")/../yb-migrations"
sha256sum -c MANIFEST.sha256 --quiet
n=$(ls -1 *.sql | wc -l)
[ "$n" -eq 20 ] || { echo "FAIL: expected 20 migration files, found $n"; exit 1; }
echo "OK: $n migration files match MANIFEST.sha256"
