#!/usr/bin/env bash
set -euo pipefail

URL="${1:?Usage: health-check.sh <base-url> [attempts] [sleep-seconds]}"
ATTEMPTS="${2:-45}"
SLEEP_SECONDS="${3:-2}"

for i in $(seq 1 "$ATTEMPTS"); do
  if curl -fsS "$URL/.well-known/ready" >/dev/null; then
    echo "ready after ${i} attempt(s)"
    exit 0
  fi
  sleep "$SLEEP_SECONDS"
done

echo "not ready after ${ATTEMPTS} attempt(s)" >&2
exit 1
