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
# WHAT THIS ARCHIVE IS, before you copy it anywhere: /etc/pve is not only config, it is the
# cluster's private key material. priv/authkey.key signs every PVE auth ticket — a copy forges
# a root@pam session with no password; priv/pve-root-ca.key is the cluster CA; priv/token.cfg
# holds existing API token secrets in plaintext; each node's pve-ssl.key is in there too. PVE
# rotates authkey.key daily, so KEEP=14 below means fourteen days of valid signing keys sitting
# in one directory. Root's umask 022 would leave the tarball 0644 under a world-readable
# /var/backups, and the USB hop makes it worse: 17.2's drive is ntfs-3g by default and carries
# no Unix permissions at all, and only the 17.6 rclone hop to Digi is encrypted — the drive
# itself is not. Hence the umask and the explicit chmod below. If that drive can ever leave the
# rack, encrypt the drive too, or this is a key-exfiltration path with a retention policy.
# Neither can retighten what is already written: on a node that ran the old version, do it once
# by hand — `chmod 700 /var/backups/pve-config && chmod 600 /var/backups/pve-config/*.tar.gz`.
# (2.5 says a skeleton key "doesn't belong there" — true of the 0.5 root pair it means, and not
# true of what the /etc/pve line above already writes to the same drive every night.)
#
# Runs on BOTH nodes via cron (02:40). The archive lands in /var/backups/pve-config locally and is
# MEANT to land on the USB backup drive as well — from where the 04:00 rclone sync (Stage 17.6)
# carries it offsite, encrypted. pve2 has no USB drive: it ships its copy to pve1 over the LAN,
# never over the on-demand 10G cable (see USB_PEER_IP below).
#
# ON THIS BUILD THAT SECOND HALF HAS NEVER RUN, and the 10G link is not the reason. Stage 17.2 was
# never done — no USB drive is attached anywhere, /mnt/usb-backup exists on neither node — so the
# local branch is skipped on pve1 and pve2 alike and both fall straight through to the failure at
# the bottom. They have logged "USB drive unreachable — kept local copy only" every single night as
# far back as the journal goes, weeks before the link went down on 2026-09-04. Repair the link and
# nothing here changes; attach the drive and it does.
#
# One trap waits behind the drive for the day 17.2 happens, and it is why the ssh below names a
# known-hosts file: pve2's plain root SSH to pve1 answers "Host key verification failed". pve2 does
# have a /root/.ssh/known_hosts, but nothing in it is pve1 — `ssh-keygen -F pve1` and `-F
# 192.168.0.11` both come back empty (2026-09-10) — nor does it have the /etc/ssh/ssh_known_hosts
# symlink pve1 happens to carry. That is an outright error here and not the fingerprint prompt a
# human gets, because the calls below pass -o BatchMode=yes. So the fallback branch — the only
# branch pve2 can ever take — would have died on trust rather than on reachability, and reported
# it as a missing drive. PVE's own migration and replication are unaffected by this: PVE passes
# its own known-hosts file on every ssh; until today this did not.
#
# WHERE THE COMPLAINT GOES, and it is not root's mail. The else-branch prints a FAIL line to stderr
# and exits 1. The copy INSTALLED on both nodes is still the 2026-09-04 one, and its cron line is a
# bare `pve-config-backup >/dev/null`: stderr does reach cron there, cron mails it to root, postfix
# hands it to a provider that rejects it outright ("550 5.7.1 ... Spamhaus") and then drops it
# (15.3) — which is how a nightly warning went unread for weeks. Re-run 2.4 and the repo's schedule
# takes over: `infra-report pve-config-backup >/dev/null`, which folds stderr into stdout for that
# redirect to discard and POSTs the outcome instead — a non-zero exit is scored Fail and the FAIL
# line becomes the report's detail in the app's admin UI, the one channel that currently arrives.
# Under both forms the local log is the thing you can read without waiting for a channel:
# `journalctl -t pve-config-backup | tail -5` must NOT be showing that line. Until a drive exists,
# each node holds exactly one copy of its own configuration, and it is on the node that copy
# describes: /var/backups is on the LVM root (`/dev/mapper/pve-root`), not on `apps` or `db` —
# which changes nothing about the risk, because root and pools alike are one bare disk each here,
# no mirror behind any of them.
#
# Usage: pve-config-backup.sh          (no arguments, safe to re-run any time)

set -euo pipefail
# Before mktemp, before tar: this has to cover the manifests and the copies too, not only
# the tarball. Root's default 022 would publish a directory of live cluster signing keys.
umask 077

LOCAL_DIR=/var/backups/pve-config
USB_MOUNT=/mnt/usb-backup
# The node holding the USB drive, reached over the LAN — deliberately NOT the 10G address
# it used to be. That link is plugged in on demand and unplugged again (5.2), so the old
# 10.10.10.1 aimed a nightly job at an address that is absent most of the time. Correcting
# it changes nothing on its own — the drive, not the link, is why this branch has never
# succeeded (see above) — but nothing scheduled may depend on the on-demand cable, and
# this was the last thing that did.
USB_PEER_IP=192.168.0.11
USB_PEER_NODE=pve1              # PVE node name — the name its host key is filed under
# Which known-hosts file, and why not a plain `ssh` — the trap above is the reason, this is the
# mechanism. PVE::SSHInfo::ssh_info_to_ssh_opts passes /etc/pve/nodes/<node>/ssh_known_hosts with
# HostKeyAlias=<node>; pmxcfs distributes that file, so both nodes always hold both keys and it
# works in either direction, which is why this script rests on it rather than on a symlink one
# node happens to have. Same store cluster-health.sh checks with. HostKeyAlias is not optional:
# that file keys the peer under its NODE NAME alone, so without it any address form fails
# verification. The lasting repair for a node that cannot ssh by hand is not the same repair —
# `pvecm updatecerts` rewrites these per-node files, while a human's `ssh pve1` reads
# /root/.ssh/known_hosts and needs the pin from 21.7. The -f test mirrors SSHInfo's own, for a
# node whose key file has not been generated yet; if it is absent this ssh still carries the
# alias with no known-hosts file behind it, fails verification, and the else-branch reports it
# as a missing drive — which is why the FAIL text at the bottom names that case.
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o HostKeyAlias=$USB_PEER_NODE"
if [ -f "/etc/pve/nodes/$USB_PEER_NODE/ssh_known_hosts" ]; then
    SSH_OPTS="$SSH_OPTS -o UserKnownHostsFile=/etc/pve/nodes/$USB_PEER_NODE/ssh_known_hosts -o GlobalKnownHostsFile=none"
fi
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
    etc/systemd/system \
    usr/local/bin \
    usr/local/sbin \
    -C "$TMP" \
    pveversion.txt root-crontab.txt dpkg-selections.txt ip-addresses.txt zpool-status.txt \
    2>/dev/null || true

gzip -t "$LOCAL_DIR/$ARCHIVE_NAME"      # fail loudly if the archive is unreadable

# Prune local copies beyond retention
ls -1t "$LOCAL_DIR"/pve-config-"$HOST"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --

# Logged here, above the shipping block, and not at the end of the file: the else branch below
# exits 1, so a line placed after it would only ever record the nights that shipped.
logger -t pve-config-backup "archived $ARCHIVE_NAME"

# Ship to the USB drive: locally if it's here, to the node that holds it over the LAN if not.
DEST_DIR="$USB_MOUNT/config-backup/$HOST"
# shellcheck disable=SC2086  # SSH_OPTS must word-split into separate -o arguments
if mountpoint -q "$USB_MOUNT"; then
    mkdir -p "$DEST_DIR"
    cp "$LOCAL_DIR/$ARCHIVE_NAME" "$DEST_DIR/"
    ls -1t "$DEST_DIR"/pve-config-"$HOST"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --
elif ssh $SSH_OPTS "root@$USB_PEER_IP" "mountpoint -q $USB_MOUNT" 2>/dev/null; then
    ssh $SSH_OPTS "root@$USB_PEER_IP" "mkdir -p $DEST_DIR"
    scp -q $SSH_OPTS "$LOCAL_DIR/$ARCHIVE_NAME" "root@$USB_PEER_IP:$DEST_DIR/"
    ssh $SSH_OPTS "root@$USB_PEER_IP" \
        "ls -1t $DEST_DIR/pve-config-$HOST-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm --"
else
    # Failing here is deliberate. The old exit 0 is what let this run unread from 2026-08-01 to
    # the audit on 2026-09-10: the exit code agreed with the silence, so nothing downstream had
    # anything to disagree with. What is being reported is not a missing convenience — the only
    # copy of a hand-managed node's config is on the node it describes, on a bare disk with no
    # mirror (the LVM root; see the header), and no vzdump exists anywhere in this cluster to
    # hold a second one, so the archive would die with the machine it describes.
    # That is a FAIL, not a WARN. Where the exit code and the line below actually surface:
    # WHERE THE COMPLAINT GOES, in the header.
    logger -t pve-config-backup "USB drive unreachable (local and via $USB_PEER_IP) — kept local copy only"
    echo "FAIL: USB drive unreachable — $ARCHIVE_NAME exists only in $LOCAL_DIR, on the same node and the same single-disk pool it describes" >&2
    echo "      Two faults share that word: no drive anywhere (17.2 never done), or the peer refused the ssh — if /etc/pve/nodes/$USB_PEER_NODE/ssh_known_hosts is absent it is the second (21.7)." >&2
    exit 1
fi
