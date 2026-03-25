#!/usr/bin/env bash
set -euo pipefail

if [ -f /opt/myapp/runtime/active-slot ]; then
  tr -d '
' < /opt/myapp/runtime/active-slot
  exit 0
fi

if grep -q '18081' /etc/nginx/conf.d/upstream-active.conf; then
  echo blue
else
  echo green
fi
