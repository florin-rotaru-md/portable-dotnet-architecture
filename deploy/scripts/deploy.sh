#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?Usage: deploy.sh <image>}"
DRAIN_SECONDS="${DRAIN_SECONDS:-20}"
RUNTIME_ROOT="/opt/myapp/runtime"
DOCKER_ROOT="/opt/myapp/docker"
SCRIPTS_ROOT="/opt/myapp/scripts"

CURRENT_SLOT="$($SCRIPTS_ROOT/current-slot.sh)"

if [ "$CURRENT_SLOT" = "blue" ]; then
  TARGET_SLOT="green"
  TARGET_PORT="18082"
  TARGET_SERVICE="myapp-green"
  OLD_SERVICE="myapp-blue"
else
  TARGET_SLOT="blue"
  TARGET_PORT="18081"
  TARGET_SERVICE="myapp-blue"
  OLD_SERVICE="myapp-green"
fi

export APP_IMAGE="$IMAGE"

echo "Current slot: $CURRENT_SLOT"
echo "Target slot:  $TARGET_SLOT"
echo "Image:        $APP_IMAGE"

docker compose   -f "$DOCKER_ROOT/compose.base.yml"   -f "$DOCKER_ROOT/compose.${TARGET_SLOT}.yml"   pull "$TARGET_SERVICE" || true

docker compose   -f "$DOCKER_ROOT/compose.base.yml"   -f "$DOCKER_ROOT/compose.${TARGET_SLOT}.yml"   up -d "$TARGET_SERVICE"

"$SCRIPTS_ROOT/health-check.sh" "http://127.0.0.1:${TARGET_PORT}" 45 2

"$SCRIPTS_ROOT/switch-nginx.sh" "$TARGET_SLOT"

sleep "$DRAIN_SECONDS"

docker compose   -f "$DOCKER_ROOT/compose.base.yml"   -f "$DOCKER_ROOT/compose.${CURRENT_SLOT}.yml"   stop "$OLD_SERVICE"

printf '%s
' "$APP_IMAGE" > "$RUNTIME_ROOT/active-image"
printf '%s | deploy | %s | slot=%s
' "$(date -Iseconds)" "$APP_IMAGE" "$TARGET_SLOT" >> "$RUNTIME_ROOT/deploy-history.log"

echo "Deployment complete"
