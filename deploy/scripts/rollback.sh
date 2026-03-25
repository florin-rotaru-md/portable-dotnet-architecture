#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_ROOT="/opt/myapp/scripts"
CURRENT_SLOT="$($SCRIPTS_ROOT/current-slot.sh)"

if [ "$CURRENT_SLOT" = "blue" ]; then
  PREVIOUS_SLOT="green"
else
  PREVIOUS_SLOT="blue"
fi

"$SCRIPTS_ROOT/switch-nginx.sh" "$PREVIOUS_SLOT"
printf '%s | rollback | slot=%s
' "$(date -Iseconds)" "$PREVIOUS_SLOT" >> /opt/myapp/runtime/deploy-history.log

echo "Rollback switched traffic to ${PREVIOUS_SLOT}"
