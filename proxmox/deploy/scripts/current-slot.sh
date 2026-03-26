#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:?Set APP_NAME}"
APP_ROOT="${APP_ROOT:?Set APP_ROOT, for example /opt/apps/${APP_NAME}}"
APP_BLUE_PORT="${APP_BLUE_PORT:?Set APP_BLUE_PORT}"

if [ -f "$APP_ROOT/runtime/active-slot" ]; then
  tr -d '\n' < "$APP_ROOT/runtime/active-slot"
  exit 0
fi

if grep -q "$APP_BLUE_PORT" "/etc/nginx/conf.d/${APP_NAME}-upstream-active.conf"; then
  echo blue
else
  echo green
fi
