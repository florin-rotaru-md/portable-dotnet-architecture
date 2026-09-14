#!/usr/bin/env bash
# offsite-sync.sh — nightly on both nodes (05:00, wrapped in infra-report): upload this node's VM images
# and host-config archives to Digi Storage and apply their offsite retention
# (portable-dotnet-architecture/proxmox-lab/RECOVERY.md). Postgres travels on its own, every minute,
# with pg-offsite.
#
# Each node uploads what only it holds: vzdump writes a guest's image on the node running that guest,
# and each node archives its own configuration. The image retention on Digi spans the whole estate, so
# only the node running 1022 applies it — one pruner, never two racing.
#
# Output: [ OK ] / [FAIL] lines. Exit: 0 when everything reached Digi, 1 otherwise.

set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

REMOTE=digi-crypt:
DUMP=${OFFSITE_DUMP_DIR:-/var/lib/vz/dump}
CONFIG=${OFFSITE_CONFIG_DIR:-/var/backups/pve-config}
VZDUMP_KEEP=2                   # images per VM on Digi; the node keeps 1 (storage prune-backups)
CONFIG_DAYS=30
PRUNER_VMID=1022
RETENTION=${BACKUP_RETENTION:-$(dirname "$(readlink -f "$0")")/backup-retention.py}
RCLONE_OPTS=(--retries 3 --low-level-retries 5 --stats 0 --log-level ERROR)
HOST=$(hostname)
RC=0
ok()   { printf '[ OK ] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; RC=1; }
rcl()  { timeout 7200 rclone "$@"; }

if ! command -v rclone > /dev/null; then
    fail "offsite: rclone is not installed; see RECOVERY.md#digi-storage-and-rclone"
    exit 1
fi
if ! rclone listremotes 2> /dev/null | grep -qx "$REMOTE"; then
    fail "offsite: rclone remote '$REMOTE' is missing; see RECOVERY.md#digi-storage-and-rclone"
    exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── VM images written on this node ───────────────────────────────────────────
IMAGES=$(find "$DUMP" -maxdepth 1 -type f -name 'vzdump-qemu-*.vma.zst' 2> /dev/null | wc -l)
if [ "$IMAGES" -eq 0 ]; then
    ok "vzdump: no image on this node to upload"
elif rcl copy "$DUMP" "${REMOTE}vzdump" --include 'vzdump-qemu-*' --transfers 2 "${RCLONE_OPTS[@]}"; then
    ok "vzdump: $IMAGES image(s) on this node are on Digi"
else
    fail "vzdump: upload from $DUMP to ${REMOTE}vzdump failed"
fi

if [ "$(qm status "$PRUNER_VMID" 2> /dev/null | awk '{print $2}')" = running ]; then
    if rcl lsf --files-only "${REMOTE}vzdump" > "$TMP/vzdump" 2> /dev/null; then
        python3 "$RETENTION" vzdump-prune "$VZDUMP_KEEP" < "$TMP/vzdump" > "$TMP/prune"
        if [ ! -s "$TMP/prune" ]; then
            ok "vzdump: Digi holds no image beyond the newest $VZDUMP_KEEP per VM"
        elif rcl delete "${REMOTE}vzdump" --files-from "$TMP/prune" --no-traverse "${RCLONE_OPTS[@]}"; then
            ok "vzdump: removed $(wc -l < "$TMP/prune") file(s) beyond the newest $VZDUMP_KEEP per VM from Digi"
        else
            fail "vzdump: pruning ${REMOTE}vzdump failed"
        fi
    else
        fail "vzdump: cannot list ${REMOTE}vzdump"
    fi
fi

# ── This node's configuration archives ───────────────────────────────────────
if ! ls "$CONFIG"/pve-config-"$HOST"-*.tar.gz > /dev/null 2>&1; then
    fail "config: no archive in $CONFIG — pve-config-backup has not run on this node"
elif rcl copy "$CONFIG" "${REMOTE}config/$HOST" --include "pve-config-$HOST-*.tar.gz" "${RCLONE_OPTS[@]}"; then
    ok "config: archives are on Digi under config/$HOST"
    rcl lsf --files-only "${REMOTE}config/$HOST" 2> /dev/null | python3 "$RETENTION" older-than "$CONFIG_DAYS" > "$TMP/config"
    if [ -s "$TMP/config" ] && ! rcl delete "${REMOTE}config/$HOST" --files-from "$TMP/config" --no-traverse "${RCLONE_OPTS[@]}"; then
        fail "config: pruning ${REMOTE}config/$HOST failed"
    fi
else
    fail "config: upload to ${REMOTE}config/$HOST failed"
fi

exit "$RC"
