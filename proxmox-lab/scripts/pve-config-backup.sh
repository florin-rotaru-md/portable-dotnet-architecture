#!/usr/bin/env bash
# pve-config-backup.sh — nightly archive of this host's hand-managed configuration.
#
# vzdump covers the VMs; nothing covers the hypervisor itself — and these hosts are managed by hand (the
# guide IS their automation), so their configuration exists nowhere else. This archives everything
# needed to rebuild a node without reverse-engineering it: /etc/pve (storage, replication, HA, backup
# jobs, corosync, VM configs), network, fstab, NUT, the stage-3 scripts, cron files, and manifests.
#
# WHAT THIS ARCHIVE IS, before you copy it anywhere: /etc/pve is not only configuration, it is the
# cluster's private key material. priv/authkey.key signs every PVE auth ticket — a copy forges a
# root@pam session with no password; priv/pve-root-ca.key is the cluster CA; priv/token.cfg holds API
# token secrets in plaintext; each node's pve-ssl.key is in there too. PVE rotates authkey.key daily,
# so KEEP=14 below means fourteen days of valid signing keys in one directory. Hence the umask and the
# chmod below, and hence offsite-sync uploads these archives only through the encrypted digi-crypt:
# remote. Never copy one anywhere that is not encrypted.
#
# Runs on BOTH nodes via cron (02:40, wrapped in infra-report). The archive stays in
# /var/backups/pve-config, on the node it describes; offsite-sync uploads it to Digi at 05:00.
#
# Usage: pve-config-backup.sh          (no arguments, safe to re-run any time)

set -euo pipefail
# Before mktemp, before tar: this has to cover the manifests too, not only the tarball. Root's default
# 022 would publish a directory of live cluster signing keys.
umask 077

LOCAL_DIR=/var/backups/pve-config
KEEP=14                         # archives kept here; Digi keeps 30 days (offsite-sync)

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
lvs                    > "$TMP/lvs.txt"               2>/dev/null || true

# One archive: host config (paths that don't exist on this node are skipped) + manifests
mkdir -p "$LOCAL_DIR"
chmod 700 "$LOCAL_DIR"     # umask does not retighten a directory that already exists
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
    etc/logrotate.d \
    etc/systemd/system \
    usr/local/bin \
    usr/local/sbin \
    -C "$TMP" \
    pveversion.txt root-crontab.txt dpkg-selections.txt ip-addresses.txt zpool-status.txt lvs.txt \
    2>/dev/null || true

gzip -t "$LOCAL_DIR/$ARCHIVE_NAME"      # fail loudly if the archive is unreadable

# Prune local copies beyond retention
ls -1t "$LOCAL_DIR"/pve-config-"$HOST"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --

logger -t pve-config-backup "archived $ARCHIVE_NAME"
echo "[ OK ] config: archived $ARCHIVE_NAME ($(du -h "$LOCAL_DIR/$ARCHIVE_NAME" | cut -f1)); offsite-sync uploads it at 05:00"
