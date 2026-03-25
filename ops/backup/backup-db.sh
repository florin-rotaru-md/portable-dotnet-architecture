#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
OUT="/opt/postgres/backups/appdb-${TS}.dump"

docker exec postgres pg_dump -U appuser -d appdb -Fc -f "/backups/appdb-${TS}.dump"

echo "Created ${OUT}"
