#!/usr/bin/env bash
set -euo pipefail

TS=$(date +%Y%m%d-%H%M%S)
OUT="/opt/postgres/backups/appdb-${TS}.dump"

pg_dump -d appdb -Fc -f "${OUT}"

echo "Created ${OUT}"
