#!/usr/bin/env bash
# pve-config-backup.sh — nightly archive of this host's hand-managed configuration.
#
# vzdump covers the VMs; nothing covers the hypervisor itself — and these hosts
# are managed by hand (the guide IS their automation), so their config exists
# nowhere else. This archives everything needed to rebuild a node without
# reverse-engineering it: /etc/pve (storage, replication, HA, backup jobs,
# corosync, VM configs), network, fstab, NUT, the stage-3 scripts, crontab,
# and a package manifest.
#
# Runs on BOTH nodes via cron (02:40). The archive lands in /var/backups/pve-config
# locally, plus on the USB backup drive — from where the 04:00 rclone sync
# (Stage 14.6) carries it offsite, encrypted. pve2 has no USB drive: it ships
# its copy to pve1 over the 10G link instead.
#
# Usage: pve-config-backup.sh          (no arguments, safe to re-run any time)

set -euo pipefail

LOCAL_DIR=/var/backups/pve-config
USB_MOUNT=/mnt/usb-backup
USB_PEER_IP=10.10.10.1          # the node holding the USB drive, over the 10G link
KEEP=14                         # archives to keep, per location

HOST=$(hostname)
STAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_NAME="pve-config-${HOST}-${STAMP}.tar.gz"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Manifests — things that aren't files but you want on record after a disaster
pveversion -v          > "$TMP/pveversion.txt"        2>/dev/null || true
crontab -l             > "$TMP/root-crontab.txt"      2>/dev/null || true
dpkg --get-selections  > "$TMP/dpkg-selections.txt"
ip -br a               > "$TMP/ip-addresses.txt"
zpool status           > "$TMP/zpool-status.txt"      2>/dev/null || true

# One archive: host config (paths that don't exist on this node are skipped) + manifests
mkdir -p "$LOCAL_DIR"
tar czf "$LOCAL_DIR/$ARCHIVE_NAME" \
    --ignore-failed-read --warning=no-file-ignored \
    -C / \
    etc/pve \
    etc/network/interfaces \
    etc/fstab \
    etc/hosts \
    etc/nut \
    etc/apt/sources.list.d \
    etc/cron.d \
    etc/crontab \
    etc/systemd/system \
    usr/local/bin \
    usr/local/sbin \
    -C "$TMP" \
    pveversion.txt root-crontab.txt dpkg-selections.txt ip-addresses.txt zpool-status.txt \
    2>/dev/null || true

gzip -t "$LOCAL_DIR/$ARCHIVE_NAME"      # fail loudly if the archive is unreadable

# Prune local copies beyond retention
ls -1t "$LOCAL_DIR"/pve-config-"$HOST"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --

# Ship to the USB drive: locally if it's here, over the 10G link if not
DEST_DIR="$USB_MOUNT/config-backup/$HOST"
if mountpoint -q "$USB_MOUNT"; then
    mkdir -p "$DEST_DIR"
    cp "$LOCAL_DIR/$ARCHIVE_NAME" "$DEST_DIR/"
    ls -1t "$DEST_DIR"/pve-config-"$HOST"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --
elif ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$USB_PEER_IP" "mountpoint -q $USB_MOUNT" 2>/dev/null; then
    ssh -o BatchMode=yes "root@$USB_PEER_IP" "mkdir -p $DEST_DIR"
    scp -q "$LOCAL_DIR/$ARCHIVE_NAME" "root@$USB_PEER_IP:$DEST_DIR/"
    ssh -o BatchMode=yes "root@$USB_PEER_IP" \
        "ls -1t $DEST_DIR/pve-config-$HOST-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --"
else
    logger -t pve-config-backup "USB drive unreachable (local and via $USB_PEER_IP) — kept local copy only"
    echo "WARN: USB drive unreachable — archive kept only in $LOCAL_DIR" >&2
fi

logger -t pve-config-backup "archived $ARCHIVE_NAME"
