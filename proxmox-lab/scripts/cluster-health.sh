#!/usr/bin/env bash
# cluster-health.sh — the 18.7 health checks as one command, plus the ones that
# are easy to forget: pool capacity, pinned snapshots, the fencing watchdog,
# version skew between the nodes, firmware, NVMe wear, power state. Run it on
# either node; a few checks are node-aware (UPS on pve1, battery on pve2).
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
AUTOSTART_VMS="1021 1022 1023"   # must have onboot=1 (10-vms.md); 1020 is manual by design

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
    fail "quorum: NOT quorate — see 18.5 before touching anything"
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
        fail "zfs: pool '$pool' not found — replication has nowhere to go (Stage 6)"
    elif [ "$CAP" -ge "$CAPACITY_WARN" ]; then
        warn "zfs: pool '$pool' at ${CAP}% — investigate before it becomes an outage (pinned snapshots? see 16.2)"
    else
        ok "zfs: pool '$pool' at ${CAP}%"
    fi
done

BIG_SNAPS=$(zfs list -t snapshot -H -o name,used 2>/dev/null | awk -v lim="$SNAPSHOT_WARN_GB" '
    /G$/ { gsub(/G$/, "", $2); if ($2 + 0 > lim) print $1 " (" $2 "G)" }')
if [ -n "$BIG_SNAPS" ]; then
    warn "zfs: large pinned snapshot(s): $(echo "$BIG_SNAPS" | tr '\n' ' ')— a stale replication or forgotten qm snapshot (16.2 / 20.3)"
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

# Placement flags. `failback` and `auto-rebalance` both default to 1 and come
# back on silently every time a resource is re-added (17.7 step 2, 19.2 step 8).
# On, they let the cluster move a guest by itself the moment a node affinity
# rule or CRS rebalancing is switched on — and on this build a guest that drifts
# to pve2 stops being backed up (15.5). Cluster-wide config: either node sees it.
HA_CONF=$(ha-manager config 2>/dev/null)
HA_COUNT=$(echo "$HA_CONF" | grep -c '^vm:')
if [ "${HA_COUNT:-0}" -gt 0 ]; then
    FB=$(echo "$HA_CONF" | grep -c 'failback 0')
    AR=$(echo "$HA_CONF" | grep -c 'auto-rebalance 0')
    if [ "$FB" -lt "$HA_COUNT" ] || [ "$AR" -lt "$HA_COUNT" ]; then
        warn "ha: placement flags not cleared on every resource (failback $FB/$HA_COUNT, auto-rebalance $AR/$HA_COUNT) — ha-manager config, then 15.5"
    else
        ok "ha: placement flags cleared on all $HA_COUNT resources"
    fi
fi

# ── Watchdog (fencing) ────────────────────────────────────────────────────────
# Self-fencing is what makes automatic recovery safe rather than reckless (18.2),
# and it is the one piece of the HA stack that fails completely silently: nothing
# in the UI, and nothing else in this script, reports a watchdog that never got
# armed. You would find out during the incident. 15.4 has the detail.
if systemctl is-active --quiet watchdog-mux; then
    WD_MOD=$(lsmod | awk '/^(softdog|iTCO_wdt|wdat_wdt|sp5100_tco)[[:space:]]/ {print $1}' | head -1)
    ok "watchdog: watchdog-mux running${WD_MOD:+ ($WD_MOD)}"
else
    fail "watchdog: watchdog-mux NOT running — a node that loses quorum will not fence itself (15.4)"
fi

# ── Start at boot ─────────────────────────────────────────────────────────────
# HA guests are started by the HA stack; every other VM comes back after a node
# reboot only if onboot is set. Nothing else surfaces a missing flag — you find
# out the next time you reboot (10-vms.md, "Start at boot"). Node-local: VMs
# living on the peer are its own run's business.
NO_ONBOOT=""
for id in $AUTOSTART_VMS; do
    CONF=$(qm config "$id" 2>/dev/null) || continue     # not on this node
    echo "$CONF" | grep -q '^onboot: 1' || NO_ONBOOT="$NO_ONBOOT $id"
done
if [ -n "$NO_ONBOOT" ]; then
    warn "autostart:$NO_ONBOOT would stay stopped after a node reboot — qm set <id> --onboot 1 (Stage 10)"
else
    ok "autostart: every VM that should start at boot is set to"
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
        warn "versions: skew — local $LOCAL_VER vs peer $PEER_VER. Migrate old→new only; align before returning workload (16.2)"
    fi
else
    warn "versions: could not find a peer in corosync.conf"
fi

# ── Firmware ──────────────────────────────────────────────────────────────────
# Detection only — nothing here ever flashes anything (16.3: flashing is a
# planned window, per machine, on a reason). fwupd refreshes LVFS metadata on
# its own timer and this just reads the result. A machine LVFS doesn't cover
# reports zero forever, which is NOT the same as being current — that one stays
# a quarterly look at the vendor's page.
BIOS_VER=$(dmidecode -s bios-version 2>/dev/null | head -1)
if command -v fwupdmgr >/dev/null 2>&1; then
    FW_PENDING=$(fwupdmgr get-updates --json 2>/dev/null | grep -c '"Releases"')
    if [ "${FW_PENDING:-0}" -gt 0 ]; then
        warn "firmware: $FW_PENDING device(s) with an update on LVFS — read 16.3 before flashing; it is a maintenance window, not an apt run"
    else
        ok "firmware: nothing pending on LVFS${BIOS_VER:+ (BIOS $BIOS_VER)}"
    fi
else
    warn "firmware: fwupd not installed — no detection at all on this node (2.2)"
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
        warn "backup: no vzdump newer than ${BACKUP_MAX_AGE_H}h on $USB_MOUNT — check the job and its notifications (17.3)"
    fi
elif [ -d "$USB_MOUNT" ]; then
    fail "backup: $USB_MOUNT exists but nothing is mounted there — the USB drive dropped off (17.2)"
else
    ok "backup: no USB storage on this node (it lives on the peer)"
fi

# ── NVMe health and wear ──────────────────────────────────────────────────────
for dev in /dev/nvme?n1; do
    [ -e "$dev" ] || continue
    if smartctl -H "$dev" 2>/dev/null | grep -qiE 'PASSED|OK'; then
        WEAR=$(smartctl -A "$dev" 2>/dev/null | awk -F: '/Percentage Used/ {gsub(/[ %]/, "", $2); print $2}')
        if [ -n "$WEAR" ] && [ "$WEAR" -ge "$NVME_WEAR_WARN" ]; then
            warn "nvme: $dev at ${WEAR}% endurance used — plan a replacement (Stage 19)"
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
        OB*)  warn "power: RUNNING ON UPS BATTERY — an outage is in progress (4.4 timeline applies)" ;;
        "")   warn "power: NUT installed but not answering — the UPS safety net is offline (Stage 4)" ;;
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
