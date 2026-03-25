#!/usr/bin/env bash
set -euo pipefail

FILE="${1:?Usage: restore-db.sh </path/to/backup.dump>}"

echo "Restoring from ${FILE}"
pg_restore -d appdb --clean --if-exists "${FILE}"
