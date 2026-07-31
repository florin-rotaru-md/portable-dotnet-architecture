#!/usr/bin/env bash
# cluster-health.sh — the 16.7 health checks as one command, plus the ones that
# are easy to forget: pool capacity, pinned snapshots, version skew between the
# nodes, NVMe wear, power state. Run it on either node; a few checks are
# node-aware (UPS on pve1, battery on pve2).
#
# Output: one line per check, [ OK ] / [WARN] / [FAIL].
# Exit:   0 = all OK, 1 = warnings, 2 = at least one failure.
#
# Usage: cluster-health [--quiet]
#   --quiet   print only WARN/FAIL lines — for cron with MAILTO, so a healthy
#             cluster sends no mail and a sick one sends exactly the problems.

set -uo pipefail

POOLS="apps db"
CAPACITY_WARN=80          # % pool usage that triggers a warning
SNAPSHOT_WARN_GB=50       # a single snapshot pinning more than this → warning
NVME_WEAR_WARN=85         # % NVMe endurance used
BACKUP_MAX_AGE_H=26       # newest vzdump older than this → warning
USB_MOUNT=/mnt/usb-backup

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

RC=0
ok()   { [ "$QUIET" = 1 ] || printf '[ OK ] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; [ "$RC" -lt 1 ] && RC=1; }
fail() { printf '[FAIL] %s\n' "$1"; RC=2; }

# ── Quorum ────────────────────────────────────────────────────────────────────
PVECM=$(pvecm status 2>&1)
if echo "$PVECM" | grep -q 'Quorate:.*Yes'; then
    TOTAL=$(echo "$PVECM" | awk '/Total votes:/ {print $3}')
    EXPECTED=$(echo "$PVECM" | awk '/Expected votes:/ {print $3}')
    if [ "${TOTAL:-0}" = "${EXPECTED:-3}" ]; then
        ok "quorum: quorate, $TOTAL/$EXPECTED votes"
    else
        warn "quorum: quorate but only $TOTAL/$EXPECTED votes — a node or the QDevice is missing; no margin until it's back"
    fi
else
    fail "quorum: NOT quorate — see 16.5 before touching anything"
fi

# ── Corosync rings ────────────────────────────────────────────────────────────
LINKS=$(corosync-cfgtool -s 2>&1)
if echo "$LINKS" | grep -qiE 'faulty|disconnected'; then
    warn "corosync: a link is down — likely the 10G cable or the TB adapter ($(echo "$LINKS" | grep -icE 'faulty|disconnected') bad entries; run corosync-cfgtool -s)"
else
    ok "corosync: all links healthy"
fi

# ── ZFS pools: health, capacity, pinned snapshots ─────────────────────────────
ZHEALTH=$(zpool status -x 2>&1)
if [ "$ZHEALTH" = "all pools are healthy" ]; then
    ok "zfs: all pools healthy"
else
    fail "zfs: $(echo "$ZHEALTH" | head -1) — run zpool status"
fi

for pool in $POOLS; do
    CAP=$(zpool list -H -o capacity "$pool" 2>/dev/null | tr -d '%')
    if [ -z "$CAP" ]; then
        fail "zfs: pool '$pool' not found — replication has nowhere to go (Stage 5)"
    elif [ "$CAP" -ge "$CAPACITY_WARN" ]; then
        warn "zfs: pool '$pool' at ${CAP}% — investigate before it becomes an outage (pinned snapshots? see 14.2)"
    else
        ok "zfs: pool '$pool' at ${CAP}%"
    fi
done

BIG_SNAPS=$(zfs list -t snapshot -H -o name,used 2>/dev/null | awk -v lim="$SNAPSHOT_WARN_GB" '
    /G$/ { gsub(/G$/, "", $2); if ($2 + 0 > lim) print $1 " (" $2 "G)" }')
if [ -n "$BIG_SNAPS" ]; then
    warn "zfs: large pinned snapshot(s): $(echo "$BIG_SNAPS" | tr '\n' ' ')— a stale replication or forgotten qm snapshot (14.2 / 18.3)"
else
    ok "zfs: no oversized snapshots"
fi

# ── Replication ───────────────────────────────────────────────────────────────
REPL=$(pvesr status 2>&1)
# Columns: JobID Enabled Target LastSync NextSync Duration FailCount State
BAD_JOBS=$(echo "$REPL" | awk 'NR > 1 && ($7 + 0 > 0 || $8 != "OK") {print $1 "(" $8 ", fails=" $7 ")"}')
if [ -n "$BAD_JOBS" ]; then
    fail "replication: $BAD_JOBS — your RPO is drifting right now (pvesr status)"
elif [ "$(echo "$REPL" | wc -l)" -le 1 ]; then
    warn "replication: no jobs on this node (fine if all VMs live on the peer — check there)"
else
    ok "replication: all jobs OK"
fi

# ── HA ────────────────────────────────────────────────────────────────────────
HA_BAD=$(ha-manager status 2>/dev/null | grep '^service' | grep -v started || true)
if [ -n "$HA_BAD" ]; then
    warn "ha: not all services started: $(echo "$HA_BAD" | tr '\n' ' ')"
else
    ok "ha: all services started"
fi

# ── Version skew vs the peer node ─────────────────────────────────────────────
PEER_ADDR=$(awk -v me="$(hostname)" '
    /node {/ {name=""; addr=""}
    $1 == "name:" {name=$2}
    $1 == "ring0_addr:" {addr=$2}
    /}/ { if (name != "" && name != me && addr != "") print addr }' /etc/pve/corosync.conf | head -1)
if [ -n "$PEER_ADDR" ]; then
    PEER_VER=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$PEER_ADDR" pveversion 2>/dev/null)
    LOCAL_VER=$(pveversion)
    if [ -z "$PEER_VER" ]; then
        warn "versions: peer $PEER_ADDR unreachable over SSH — can't compare (node down, or during maintenance: expected)"
    elif [ "$PEER_VER" = "$LOCAL_VER" ]; then
        ok "versions: both nodes on $LOCAL_VER"
    else
        warn "versions: skew — local $LOCAL_VER vs peer $PEER_VER. Migrate old→new only; align before returning workload (14.2)"
    fi
else
    warn "versions: could not find a peer in corosync.conf"
fi

# ── Time sync ─────────────────────────────────────────────────────────────────
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
    ok "time: synchronized"
else
    warn "time: NOT synchronized — expect confusing logs and cert complaints (timedatectl)"
fi

# ── Backup freshness (only where the USB drive lives) ─────────────────────────
if mountpoint -q "$USB_MOUNT"; then
    NEWEST=$(find "$USB_MOUNT/dump" -name 'vzdump-qemu-*' -mmin -$((BACKUP_MAX_AGE_H * 60)) 2>/dev/null | head -1)
    if [ -n "$NEWEST" ]; then
        ok "backup: fresh vzdump on the USB drive (<${BACKUP_MAX_AGE_H}h) — backup-verify has the per-VM detail"
    else
        warn "backup: no vzdump newer than ${BACKUP_MAX_AGE_H}h on $USB_MOUNT — check the job and its notifications (15.3)"
    fi
elif [ -d "$USB_MOUNT" ]; then
    fail "backup: $USB_MOUNT exists but nothing is mounted there — the USB drive dropped off (15.2)"
else
    ok "backup: no USB storage on this node (it lives on the peer)"
fi

# ── NVMe health and wear ──────────────────────────────────────────────────────
for dev in /dev/nvme?n1; do
    [ -e "$dev" ] || continue
    if smartctl -H "$dev" 2>/dev/null | grep -qiE 'PASSED|OK'; then
        WEAR=$(smartctl -A "$dev" 2>/dev/null | awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2}')
        if [ -n "$WEAR" ] && [ "$WEAR" -ge "$NVME_WEAR_WARN" ]; then
            warn "nvme: $dev at ${WEAR}% endurance used — plan a replacement (Stage 17)"
        else
            ok "nvme: $dev healthy${WEAR:+ (${WEAR}% endurance used)}"
        fi
    else
        fail "nvme: $dev SMART health check failed — run smartctl -a $dev"
    fi
done

# ── Power (node-aware) ────────────────────────────────────────────────────────
if command -v upsc >/dev/null 2>&1; then
    UPS_STATUS=$(upsc ups@localhost ups.status 2>/dev/null)
    case "$UPS_STATUS" in
        OL*)  ok "power: UPS on line power" ;;
        OB*)  warn "power: RUNNING ON UPS BATTERY — an outage is in progress (3b.4 timeline applies)" ;;
        "")   warn "power: NUT installed but not answering — the UPS safety net is offline (Stage 3b)" ;;
        *)    warn "power: UPS status '$UPS_STATUS'" ;;
    esac
fi
for ac in /sys/class/power_supply/AC*/online; do
    [ -e "$ac" ] || continue
    if [ "$(cat "$ac")" = "0" ]; then
        warn "power: laptop is ON BATTERY — clean shutdown at 10% (Stage 3.2)"
    else
        ok "power: laptop on AC"
    fi
done

exit "$RC"
