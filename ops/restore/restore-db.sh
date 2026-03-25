#!/usr/bin/env bash
set -euo pipefail

FILE="${1:?Usage: restore-db.sh </path/to/backup.dump>}"

echo "Restoring from ${FILE}"
cat "$FILE" | docker exec -i postgres pg_restore -U appuser -d appdb --clean --if-exists
