#!/usr/bin/env bash
set -euo pipefail

TARGET_SLOT="${1:?Usage: switch-nginx.sh <blue|green>}"

case "$TARGET_SLOT" in
  blue)
    cp /opt/myapp/nginx/upstream-blue.conf /etc/nginx/conf.d/upstream-active.conf
    ;;
  green)
    cp /opt/myapp/nginx/upstream-green.conf /etc/nginx/conf.d/upstream-active.conf
    ;;
  *)
    echo "Unknown slot: $TARGET_SLOT" >&2
    exit 1
    ;;
esac

nginx -t
systemctl reload nginx
printf '%s
' "$TARGET_SLOT" > /opt/myapp/runtime/active-slot
