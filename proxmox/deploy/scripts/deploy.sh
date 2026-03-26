#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:?Set APP_NAME}"
APP_ROOT="${APP_ROOT:?Set APP_ROOT, for example /opt/apps/${APP_NAME}}"
APP_BLUE_PORT="${APP_BLUE_PORT:?Set APP_BLUE_PORT}"
APP_GREEN_PORT="${APP_GREEN_PORT:?Set APP_GREEN_PORT}"
IMAGE="${1:?Usage: deploy.sh <image>}"
DRAIN_SECONDS="${DRAIN_SECONDS:-20}"
RUNTIME_ROOT="$APP_ROOT/runtime"
DOCKER_ROOT="$APP_ROOT/docker"
SCRIPTS_ROOT="$APP_ROOT/scripts"

CURRENT_SLOT="$($SCRIPTS_ROOT/current-slot.sh)"

if [ "$CURRENT_SLOT" = "blue" ]; then
  TARGET_SLOT="green"
  TARGET_PORT="$APP_GREEN_PORT"
  TARGET_SERVICE="${APP_NAME}-green"
  OLD_SERVICE="${APP_NAME}-blue"
else
  TARGET_SLOT="blue"
  TARGET_PORT="$APP_BLUE_PORT"
  TARGET_SERVICE="${APP_NAME}-blue"
  OLD_SERVICE="${APP_NAME}-green"
fi

export APP_IMAGE="$IMAGE"

echo "Application:  $APP_NAME"
echo "Current slot: $CURRENT_SLOT"
echo "Target slot:  $TARGET_SLOT"
echo "Image:        $APP_IMAGE"

docker compose   -f "$DOCKER_ROOT/compose.base.yml"   -f "$DOCKER_ROOT/compose.${TARGET_SLOT}.yml"   pull "$TARGET_SERVICE" || true

docker compose   -f "$DOCKER_ROOT/compose.base.yml"   -f "$DOCKER_ROOT/compose.${TARGET_SLOT}.yml"   up -d "$TARGET_SERVICE"

"$SCRIPTS_ROOT/health-check.sh" "http://127.0.0.1:${TARGET_PORT}" 45 2

"$SCRIPTS_ROOT/switch-nginx.sh" "$TARGET_SLOT"

sleep "$DRAIN_SECONDS"

docker compose   -f "$DOCKER_ROOT/compose.base.yml"   -f "$DOCKER_ROOT/compose.${CURRENT_SLOT}.yml"   stop "$OLD_SERVICE"

printf '%s\n' "$APP_IMAGE" > "$RUNTIME_ROOT/active-image"
printf '%s | deploy | %s | slot=%s\n' "$(date -Iseconds)" "$APP_IMAGE" "$TARGET_SLOT" >> "$RUNTIME_ROOT/deploy-history.log"

echo "Deployment complete"
