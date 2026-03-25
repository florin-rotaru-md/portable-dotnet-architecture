#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:?Set APP_NAME}"
APP_ROOT="${APP_ROOT:?Set APP_ROOT, for example /opt/apps/${APP_NAME}}"
TARGET_SLOT="${1:?Usage: switch-nginx.sh <blue|green>}"

case "$TARGET_SLOT" in
  blue)
    cp "$APP_ROOT/nginx/upstream-blue.conf" "/etc/nginx/conf.d/${APP_NAME}-upstream-active.conf"
    ;;
  green)
    cp "$APP_ROOT/nginx/upstream-green.conf" "/etc/nginx/conf.d/${APP_NAME}-upstream-active.conf"
    ;;
  *)
    echo "Unknown slot: $TARGET_SLOT" >&2
    exit 1
    ;;
esac

nginx -t
systemctl reload nginx
printf '%s\n' "$TARGET_SLOT" > "$APP_ROOT/runtime/active-slot"
