#!/usr/bin/env bash
# restore-drill.sh — run the documented isolated VM restore as one command: restore the newest archive of one
# VM to a spare ID, with the NIC disconnected, boot it, prove the guest agent answers,
# report, destroy.
#
# "A backup you have never restored is a hypothesis." This turns the ten-minute
# manual drill into one command and a log line, and its duration is your real
# per-VM RTO — written down, not assumed.
#
# NOTHING RUNS THIS FOR YOU. install-scripts.sh leaves it out of the cron file on
# purpose — procedures that create and destroy VMs deserve a human watching
# (scripts/README.md) — so the quarterly drill is a promise your calendar keeps or
# nobody does.
#
# Run on either node: it restores the newest image of that VM in /var/lib/vz/dump
# there. Storage `local` keeps one image per VM, on the node that ran the guest; to
# drill an image from Digi, copy it into that directory first, which makes the
# drill a proof of the offsite tier too. Results append to /var/log/restore-drill.log.
# On failure the drill VM is KEPT for inspection.
#
# Usage: restore-drill [vmid] [--keep]
#   vmid      which VM's backup to drill (default: rotates 1020/1021/1022/1023 by month)
#   --keep    don't destroy the drill VM on success (inspect it, then
#             qm stop <id> && qm destroy <id>)

set -euo pipefail

DUMP=/var/lib/vz/dump
STORAGE=apps                    # drill restores are throwaway — apps has the room
BOOT_TIMEOUT=300                # seconds to wait for the guest agent
LOG=/var/log/restore-drill.log

KEEP=0; VMID=""
for a in "$@"; do
    case "$a" in
        --keep) KEEP=1 ;;
        [0-9]*) VMID=$a ;;
        *) echo "usage: restore-drill [vmid] [--keep]" >&2; exit 2 ;;
    esac
done

if [ -z "$VMID" ]; then
    set -- 1020 1021 1022 1023
    shift $(( $(date +%-m) % 4 ))
    VMID=$1
    echo "No VM given — this month's rotation picks $VMID."
fi

TARGET=$((VMID + 900))          # 1020→1920, 1021→1921, 1022→1922, 1023→1923

ARCHIVE=$(ls -1t "$DUMP"/vzdump-qemu-"$VMID"-*.vma.zst 2>/dev/null | head -1)
[ -n "$ARCHIVE" ] || { echo "FAIL: no image of VM $VMID in $DUMP on this node — copy one from Digi first: rclone lsf digi-crypt:vzdump | grep qemu-$VMID, then rclone copy digi-crypt:vzdump/<name> $DUMP/; see RECOVERY.md#drill-acceptance" >&2; exit 2; }
if qm status "$TARGET" >/dev/null 2>&1; then
    echo "FAIL: VM ID $TARGET already exists — a previous drill wasn't cleaned up (qm stop $TARGET && qm destroy $TARGET)" >&2
    exit 2
fi

AGE_H=$(( ($(date +%s) - $(stat -c %Y "$ARCHIVE")) / 3600 ))
echo "Drilling VM $VMID from $(basename "$ARCHIVE") (${AGE_H}h old) into spare ID $TARGET..."
START=$(date +%s)

fail() {
    echo "FAIL: $1" >&2
    echo "$(date '+%F %T') FAIL vm=$VMID target=$TARGET archive=$(basename "$ARCHIVE") reason=\"$1\"" >> "$LOG"
    echo "The drill VM (if created) is kept for inspection: qm status $TARGET" >&2
    exit 1
}

# Restore to the spare ID; --unique regenerates the MAC so nothing collides.
qmrestore "$ARCHIVE" "$TARGET" --storage "$STORAGE" --unique >/dev/null || fail "qmrestore returned an error"
RESTORE_S=$(( $(date +%s) - START ))

# Belt and suspenders on top of --unique: boot with the NIC link down, so the
# clone can never fight the original for its static IP.
NET0=$(qm config "$TARGET" | awk -F': ' '/^net0:/ {print $2}')
[ -n "$NET0" ] && qm set "$TARGET" --net0 "${NET0},link_down=1" >/dev/null

# And disarm its boot flags. qmrestore replays the ARCHIVED config and --unique rewrites
# only the MAC, so the clone inherits `onboot: 1` and the original's `startup` order
# (1022: order=1,up=60). A drill VM left behind — by --keep, or by fail(), which keeps it
# on purpose — would then start itself on the next node reboot ahead of everything else,
# and for 1022 that is a second 32 GiB Postgres on a stale copy racing the real one for a
# 62 GiB node's RAM. link_down keeps the clone off the network; it does not keep it from
# booting. If we cannot disarm it, we do not boot it.
# ("cannot delete 'startup' - not set" is an expected warn for 1920 — 1020 has no startup key.)
qm set "$TARGET" --onboot 0 --delete startup >/dev/null 2>&1 \
    || fail "could not clear onboot/startup on the drill clone — destroy $TARGET now (qm destroy $TARGET --purge); an armed copy must not outlive the drill"

qm start "$TARGET" >/dev/null || fail "restored VM refused to start"

# The guest agent answering proves the disk is a bootable, running system —
# not just an archive that unpacked cleanly
DEADLINE=$(( $(date +%s) + BOOT_TIMEOUT ))
until qm agent "$TARGET" ping >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$DEADLINE" ] || fail "guest agent not answering after ${BOOT_TIMEOUT}s — boots broken, inspect the console of $TARGET"
    sleep 5
done
TOTAL_S=$(( $(date +%s) - START ))

echo "PASS: restore ${RESTORE_S}s, restore+boot ${TOTAL_S}s — that is your measured RTO for VM $VMID from a local image."
echo "$(date '+%F %T') PASS vm=$VMID target=$TARGET archive=$(basename "$ARCHIVE") restore=${RESTORE_S}s total=${TOTAL_S}s" >> "$LOG"

if [ "$KEEP" = 1 ]; then
    echo "Kept for inspection (--keep): NIC is link-down; use the console. Clean up with: qm stop $TARGET && qm destroy $TARGET"
else
    qm stop "$TARGET" >/dev/null 2>&1 || true
    qm destroy "$TARGET" --purge >/dev/null || fail "drill passed but cleanup failed — destroy $TARGET by hand"
    echo "Drill VM destroyed. History: $LOG"
fi
