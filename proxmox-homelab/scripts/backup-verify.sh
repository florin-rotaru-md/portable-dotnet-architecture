#!/usr/bin/env bash
# backup-verify.sh — answers one question: "am I protected RIGHT NOW?"
#
# The backup chain has four links (14.1/14.5): nightly vzdump per VM → USB,
# host-config archives → USB, the 04:00 offsite sync, and the in-VM Postgres
# dump. Notifications only fire on *failure* — a job that silently stopped
# running fires nothing. This checks each link for *freshness*, which is the
# signal silence doesn't give you.
#
# Run on pve1 (where the USB drive and rclone live). On a node without the USB
# storage configured it exits 0 quietly, so the same cron entry can be
# installed everywhere.
#
# Output: one line per check, [ OK ] / [WARN] / [FAIL].
# Exit:   0 = all OK, 1 = warnings, 2 = at least one failure.
#
# Usage: backup-verify [--quiet]
#   --quiet   print only WARN/FAIL lines (for cron with MAILTO=root)

set -uo pipefail

VMS="1010 1020 1030"
CONFIG_HOSTS="pve1 pve2"
MAX_AGE_H=26                    # nightly jobs → anything older than ~a day is stale
MIN_SIZE_MB=100                 # a vzdump smaller than this is almost certainly broken
USB_MOUNT=/mnt/usb-backup
RCLONE_REMOTE=digi-crypt:
RCLONE_LOG=/var/log/rclone-backup.log
PG_VM_IP=192.168.0.30
PG_DUMP_DIR=/opt/postgres/backups

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

RC=0
ok()   { [ "$QUIET" = 1 ] || printf '[ OK ] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; [ "$RC" -lt 1 ] && RC=1; }
fail() { printf '[FAIL] %s\n' "$1"; RC=2; }

# ── The USB drive itself ──────────────────────────────────────────────────────
if ! mountpoint -q "$USB_MOUNT"; then
    if [ -d "$USB_MOUNT" ]; then
        fail "usb: $USB_MOUNT exists but nothing is mounted — the drive dropped off; every tier below is dead (14.2)"
        exit "$RC"
    fi
    # No USB storage configured on this node — it lives on the peer. Nothing to verify here.
    exit 0
fi
ok "usb: drive mounted"

# ── Per-VM vzdump freshness and plausibility ──────────────────────────────────
for vm in $VMS; do
    NEWEST=$(ls -1t "$USB_MOUNT"/dump/vzdump-qemu-"$vm"-*.vma.zst 2>/dev/null | head -1)
    if [ -z "$NEWEST" ]; then
        fail "vzdump $vm: no archive at all on the USB drive — check the job covers this VM (14.3)"
        continue
    fi
    AGE_H=$(( ($(date +%s) - $(stat -c %Y "$NEWEST")) / 3600 ))
    SIZE_MB=$(( $(stat -c %s "$NEWEST") / 1024 / 1024 ))
    if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "vzdump $vm: newest archive is ${AGE_H}h old — the nightly job isn't producing (14.3, notifications)"
    elif [ "$SIZE_MB" -lt "$MIN_SIZE_MB" ]; then
        fail "vzdump $vm: newest archive is only ${SIZE_MB}MB — implausibly small, inspect it before trusting it"
    else
        ok "vzdump $vm: ${AGE_H}h old, ${SIZE_MB}MB"
    fi
done

# ── Host-config archives (pve-config-backup.sh, both nodes) ───────────────────
for host in $CONFIG_HOSTS; do
    NEWEST=$(ls -1t "$USB_MOUNT"/config-backup/"$host"/pve-config-"$host"-*.tar.gz 2>/dev/null | head -1)
    if [ -z "$NEWEST" ]; then
        warn "config $host: no archive — pve-config-backup not running there (scripts/README)"
        continue
    fi
    AGE_H=$(( ($(date +%s) - $(stat -c %Y "$NEWEST")) / 3600 ))
    if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
        warn "config $host: newest archive is ${AGE_H}h old — its cron stopped (on pve2 also check the 10G link)"
    else
        ok "config $host: ${AGE_H}h old"
    fi
done

# ── Offsite: did the last sync run, and is the remote fresh? ──────────────────
if [ -f "$RCLONE_LOG" ]; then
    LOG_AGE_H=$(( ($(date +%s) - $(stat -c %Y "$RCLONE_LOG")) / 3600 ))
    ERRORS=$(tail -50 "$RCLONE_LOG" | grep -c ERROR || true)
    if [ "$LOG_AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "offsite: rclone log untouched for ${LOG_AGE_H}h — the 04:00 cron isn't running (14.6)"
    elif [ "$ERRORS" -gt 0 ]; then
        warn "offsite: $ERRORS ERROR line(s) in the recent log — tail -50 $RCLONE_LOG"
    else
        ok "offsite: sync ran within ${LOG_AGE_H}h, no recent errors"
    fi
else
    fail "offsite: $RCLONE_LOG missing — the sync has never run on this node (14.6)"
fi

# The log proves the sync *ran*; this proves the remote actually *has current data*
# — and, quarterly, scenario E proves the crypt passwords still decrypt it (14.9).
NEWEST_REMOTE_TS=$(timeout 90 rclone lsl "${RCLONE_REMOTE}dump" 2>/dev/null \
    | awk '{print $2 " " substr($3, 1, 8)}' | sort | tail -1)
if [ -z "$NEWEST_REMOTE_TS" ]; then
    warn "offsite: could not list ${RCLONE_REMOTE}dump — remote unreachable or empty (rclone ls ${RCLONE_REMOTE}dump)"
else
    REMOTE_AGE_H=$(( ($(date +%s) - $(date -d "$NEWEST_REMOTE_TS" +%s 2>/dev/null || echo 0)) / 3600 ))
    if [ "$REMOTE_AGE_H" -gt $((MAX_AGE_H + 24)) ]; then
        warn "offsite: newest remote object is ${REMOTE_AGE_H}h old — syncs are running but not uploading new data"
    else
        ok "offsite: newest remote object ${REMOTE_AGE_H}h old"
    fi
fi

# ── WAL stream to the QDevice (10b) — slot active and not lagging ─────────────
# Freshness can't be judged by file age (no traffic → no writes, by design), so
# ask the primary: is the receiver connected, and how far behind is the slot?
WAL_SLOT=wal_archive
WAL_LAG_WARN_MB=64
WAL_STATE=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "devops@$PG_VM_IP" \
    "sudo -u postgres psql -tAc \"select active::text || '|' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint / 1024 / 1024, -1) from pg_replication_slots where slot_name='$WAL_SLOT'\"" 2>/dev/null | tr -d '[:space:]')
if [ -z "$WAL_STATE" ]; then
    ok "wal-stream: no '$WAL_SLOT' slot on $PG_VM_IP — Stage 10b not enabled (fine if that's intentional)"
else
    WAL_ACTIVE=${WAL_STATE%%|*}
    WAL_LAG_MB=${WAL_STATE##*|}
    if [ "$WAL_ACTIVE" != "true" ] && [ "$WAL_ACTIVE" != "t" ]; then
        fail "wal-stream: slot '$WAL_SLOT' INACTIVE — pg-receivewal on the QDevice is down; RPO is back to ~1 min and WAL is accumulating toward the 10GB cap (10b.5)"
    elif [ "${WAL_LAG_MB:-0}" -gt "$WAL_LAG_WARN_MB" ]; then
        warn "wal-stream: receiver connected but ${WAL_LAG_MB}MB behind — check the QDevice's disk and network (10b.3)"
    else
        ok "wal-stream: receiver connected, ${WAL_LAG_MB}MB behind"
    fi
fi

# ── The fourth tier: in-VM Postgres dumps (14.5) ──────────────────────────────
# Uses the host root key, which cloud-init authorized in every VM (18.1).
PG_NEWEST_TS=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "devops@$PG_VM_IP" \
    "sh -c 'f=\$(ls -t $PG_DUMP_DIR/*.dump 2>/dev/null | head -1); [ -n \"\$f\" ] && stat -c %Y \"\$f\"'" 2>/dev/null)
if [ -z "$PG_NEWEST_TS" ]; then
    warn "pg-dump: could not check $PG_VM_IP:$PG_DUMP_DIR — VM down, key missing, or no dumps yet (14.5)"
else
    PG_AGE_H=$(( ($(date +%s) - PG_NEWEST_TS) / 3600 ))
    if [ "$PG_AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "pg-dump: newest dump is ${PG_AGE_H}h old — the 02:15 cron on 1030 stopped (14.5)"
    else
        ok "pg-dump: ${PG_AGE_H}h old"
    fi
fi

exit "$RC"
