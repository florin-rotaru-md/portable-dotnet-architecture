#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:?Set APP_NAME}"
APP_ROOT="${APP_ROOT:?Set APP_ROOT, for example /opt/apps/${APP_NAME}}"
SCRIPTS_ROOT="$APP_ROOT/scripts"
CURRENT_SLOT="$($SCRIPTS_ROOT/current-slot.sh)"

if [ "$CURRENT_SLOT" = "blue" ]; then
  PREVIOUS_SLOT="green"
else
  PREVIOUS_SLOT="blue"
fi

"$SCRIPTS_ROOT/switch-nginx.sh" "$PREVIOUS_SLOT"
printf '%s | rollback | slot=%s\n' "$(date -Iseconds)" "$PREVIOUS_SLOT" >> "$APP_ROOT/runtime/deploy-history.log"

echo "Rollback switched traffic to ${PREVIOUS_SLOT}"
