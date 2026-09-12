#!/usr/bin/env bash
# backup-verify.sh — answers one question: "am I protected RIGHT NOW?"
#
# The backup chain has five links (17.1/17.5/17.10): nightly vzdump per VM →
# USB, host-config archives → USB, the R2 media mirror → USB, the 04:00
# offsite sync, and the in-VM Postgres dump. Notifications only fire on
# *failure* — a job that silently stopped running fires nothing. This checks
# each link for *freshness*, which is the signal silence doesn't give you.
#
# Runs on both nodes; the same cron entry is installed everywhere. The tiers that live
# on the USB drive are skipped where the drive is not mounted, and the tiers that reach
# VM 1022 over the network run everywhere.
#
# The header used to say "run on pve1, where the USB drive and rclone live". Both halves
# were false, and stating them cost real time: on 2026-09-10 /mnt/usb-backup existed on
# NEITHER node and rclone was installed on neither node (nor on the QDevice) — the offsite
# and R2 tiers had never been built at all, as opposed to having broken. A header that
# names where something lives ends the next reader's search, so it had better be checked
# rather than assumed.
#
# Output: one line per check, [ OK ] / [WARN] / [FAIL].
# Exit:   0 = all OK, 1 = warnings, 2 = at least one failure.
#
# Usage: backup-verify [--quiet]
#   --quiet   print only WARN/FAIL lines (for cron with MAILTO=root)

set -uo pipefail

# Same reasoning as cluster-health.sh: /usr/sbin is where several of the tools below live,
# cron's default PATH does not include it, and cron is not the only thing that runs this.
PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

VMS="1020 1021 1022 1023"
CONFIG_HOSTS="pve1 pve2"
MAX_AGE_H=26                    # nightly jobs → anything older than ~a day is stale
MIN_SIZE_MB=100                 # a vzdump smaller than this is almost certainly broken
PG_MIN_SIZE_MB=1                # likewise for a Postgres dump; the real ones are 12-22 MB
USB_MOUNT=/mnt/usb-backup
RCLONE_REMOTE=digi-crypt:
RCLONE_LOG=/var/log/rclone-backup.log
R2_DIR=/mnt/usb-backup/r2
R2_LOG=/var/log/rclone-r2.log
PG_VM_IP=192.168.0.22
PG_DUMP_DIR=/opt/postgres/backups       # fallback — the real dir is read off the postgres crontab

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

RC=0
record() { :; }
if [ -n "${INFRA_CHECKS_FILE:-}" ]; then
    helper="$(dirname "${BASH_SOURCE[0]}")/infra-check-output"
    [ -r "$helper" ] || helper="$helper.sh"
    # shellcheck source=infra-check-output.sh
    . "$helper" || exit 2
fi
ok()   { record pass "$1"; [ "$QUIET" = 1 ] || printf '[ OK ] %s\n' "$1"; }
warn() { record warn "$1"; printf '[WARN] %s\n' "$1"; [ "$RC" -lt 1 ] && RC=1; return 0; }
fail() { record fail "$1"; printf '[FAIL] %s\n' "$1"; RC=2; return 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# The first line of a failed ssh is often the row of @ signs from the host-key banner,
# which tells the reader nothing. Skip decoration and quote the first line that carries
# actual words, so the message names the fault rather than the frame around it.
first_meaningful() { grep -vE '^[[:space:]@*=-]*$' | head -1; }

# ── The USB drive itself ──────────────────────────────────────────────────────
CHECK_ID=usb CHECK_CATEGORY=backups
# Read the comment below before touching this block; its shape is the entire point.
#
# The old code, on a node with no drive and no /mnt/usb-backup directory, ran
# `exit 0` with no output whatsoever. That was deliberate and it was wrong. It was
# written for the node that does not hold the drive — the peer does, and the peer's
# own run does the verifying — so staying quiet let one cron entry be installed on
# both nodes. But it encodes an assumption it never tests: that some OTHER node is
# covering this. On 2026-09-10 neither node had the drive, so both took this branch,
# both exited 0 silently, and the app dutifully recorded "pass — exit 0, no output"
# for both. Two green ticks, five unverified tiers, and no vzdump had EVER run.
#
# Silence is only honest when something else is doing the work. So prove that
# something is, using the one source that answers for the whole cluster rather than
# for this node: jobs.cfg and vzdump.cron live in pmxcfs and read the same on either
# side. No job anywhere means nobody is covering anybody, and that is a FAIL wherever
# it is noticed first.
JOBS_MODERN=$(grep -c '^vzdump:' /etc/pve/jobs.cfg 2>/dev/null)
JOBS_LEGACY=$(grep -cE '^[^#]*[[:space:]]vzdump[[:space:]]' /etc/pve/vzdump.cron 2>/dev/null)
BACKUP_JOBS=$(( ${JOBS_MODERN:-0} + ${JOBS_LEGACY:-0} ))

# USB_OK gates only the tiers that genuinely live on the drive. It used to be an early
# `exit`, and that was a second bug hiding behind the first: the WAL-slot and in-VM
# pg-dump checks at the bottom of this file never touch /mnt/usb-backup — they reach
# VM 1022 over the network — yet they sat below the gate, so on a node with no drive
# they did not run. With no drive on EITHER node that meant the one tier that actually
# exists, the nightly Postgres dump, was the only thing in the estate still protecting
# anything and the only thing nothing ever checked. Absence of the drive is a reason to
# skip the drive's tiers, not a reason to stop asking questions.
USB_OK=1
if ! mountpoint -q "$USB_MOUNT"; then
    USB_OK=0
    if [ -d "$USB_MOUNT" ]; then
        fail "usb: $USB_MOUNT exists but nothing is mounted — the drive dropped off, so every tier that lives on it is dead (17.2)"
    elif [ "$BACKUP_JOBS" -eq 0 ]; then
        fail "usb: no backup drive on this node AND no vzdump job scheduled anywhere in the cluster — no other node is covering this, nothing is being backed up at all (17.1)"
    else
        ok "usb: no drive on this node; $BACKUP_JOBS job(s) scheduled cluster-wide, so the peer's run verifies those tiers"
    fi
else
    ok "usb: drive mounted"
fi

if [ "$USB_OK" = 1 ]; then

# ── Per-VM vzdump freshness and plausibility ──────────────────────────────────
CHECK_ID=vzdump CHECK_CATEGORY=backups
for vm in $VMS; do
    NEWEST=$(ls -1t "$USB_MOUNT"/dump/vzdump-qemu-"$vm"-*.vma.zst 2>/dev/null | head -1)
    if [ -z "$NEWEST" ]; then
        fail "vzdump $vm: no archive at all on the USB drive — check the job covers this VM (17.3)"
        continue
    fi
    AGE_H=$(( ($(date +%s) - $(stat -c %Y "$NEWEST")) / 3600 ))
    SIZE_MB=$(( $(stat -c %s "$NEWEST") / 1024 / 1024 ))
    if [ "$AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "vzdump $vm: newest archive is ${AGE_H}h old — the nightly job isn't producing (17.3, notifications)"
    elif [ "$SIZE_MB" -lt "$MIN_SIZE_MB" ]; then
        fail "vzdump $vm: newest archive is only ${SIZE_MB}MB — implausibly small, inspect it before trusting it"
    else
        ok "vzdump $vm: ${AGE_H}h old, ${SIZE_MB}MB"
    fi
done

# ── Host-config archives (pve-config-backup.sh, both nodes) ───────────────────
CHECK_ID=config-backups CHECK_CATEGORY=backups
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
CHECK_ID=offsite CHECK_CATEGORY=backups
if [ -f "$RCLONE_LOG" ]; then
    LOG_AGE_H=$(( ($(date +%s) - $(stat -c %Y "$RCLONE_LOG")) / 3600 ))
    ERRORS=$(tail -50 "$RCLONE_LOG" | grep -c ERROR || true)
    if [ "$LOG_AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "offsite: rclone log untouched for ${LOG_AGE_H}h — the 04:00 cron isn't running (17.6)"
    elif [ "$ERRORS" -gt 0 ]; then
        warn "offsite: $ERRORS ERROR line(s) in the recent log — tail -50 $RCLONE_LOG"
    else
        ok "offsite: sync ran within ${LOG_AGE_H}h, no recent errors"
    fi
else
    fail "offsite: $RCLONE_LOG missing — the sync has never run on this node (17.6)"
fi

# The log proves the sync *ran*; this proves the remote actually *has current data*
# — and, quarterly, scenario E proves the crypt passwords still decrypt it (17.9).
NEWEST_REMOTE_TS=$(have rclone && timeout 90 rclone lsl "${RCLONE_REMOTE}dump" 2>/dev/null \
    | awk '{print $2 " " substr($3, 1, 8)}' | sort | tail -1)
if ! have rclone; then
    # Distinct from "the remote did not answer": no binary means the offsite tier was
    # never built on this node, which is a different conversation from a bad night.
    fail "offsite: rclone is not installed on this node — the offsite tier does not exist here at all, it is not merely stale (17.6)"
elif [ -z "$NEWEST_REMOTE_TS" ]; then
    warn "offsite: could not list ${RCLONE_REMOTE}dump — remote unreachable or empty (rclone ls ${RCLONE_REMOTE}dump)"
else
    REMOTE_AGE_H=$(( ($(date +%s) - $(date -d "$NEWEST_REMOTE_TS" +%s 2>/dev/null || echo 0)) / 3600 ))
    if [ "$REMOTE_AGE_H" -gt $((MAX_AGE_H + 24)) ]; then
        warn "offsite: newest remote object is ${REMOTE_AGE_H}h old — syncs are running but not uploading new data"
    else
        ok "offsite: newest remote object ${REMOTE_AGE_H}h old"
    fi
fi

# ── R2 media mirror (17.10) — the bucket's only copy outside Cloudflare ──────
CHECK_ID=r2 CHECK_CATEGORY=backups
if [ ! -d "$R2_DIR" ]; then
    CHECK_OBSERVATION=unknown warn "r2-mirror: not set up on this drive — no R2 mirror coverage verified (17.10)"
elif [ ! -f "$R2_LOG" ]; then
    fail "r2-mirror: $R2_DIR exists but $R2_LOG is missing — the 03:30 sync has never run (17.10)"
else
    R2_AGE_H=$(( ($(date +%s) - $(stat -c %Y "$R2_LOG")) / 3600 ))
    R2_ERRORS=$(tail -50 "$R2_LOG" | grep -c ERROR || true)
    if [ "$R2_AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "r2-mirror: log untouched for ${R2_AGE_H}h — the 03:30 cron isn't running (17.10)"
    elif [ "$R2_ERRORS" -gt 0 ]; then
        warn "r2-mirror: $R2_ERRORS ERROR line(s) in the recent log — tail -50 $R2_LOG"
    else
        ok "r2-mirror: synced within ${R2_AGE_H}h, no recent errors"
    fi
fi

fi  # end of the USB-drive-dependent tiers; everything below reaches the network instead

# ── WAL stream to the QDevice (Stage 13) — slot active and not lagging ────────
CHECK_ID=wal CHECK_CATEGORY=backups
# Freshness can't be judged by file age (no traffic → no writes, by design), so
# ask the primary: is the receiver connected, and how far behind is the slot?
WAL_SLOT=wal_archive
WAL_LAG_WARN_MB=64
#
# The SSH exit status is kept SEPARATELY from the query result, and that separation is the
# whole point of this block's shape. Both used to collapse into one empty string, so an
# unreachable VM printed "no slot — Stage 13 not enabled (fine if that's intentional)":
# a reassuring green line manufactured entirely by a connection failure. It was not
# hypothetical — on 2026-09-10 pve1 could not reach 192.168.0.22 at all
# ("REMOTE HOST IDENTIFICATION HAS CHANGED", the VM having been rebuilt during the
# 2026-09-05..07 database reset without anyone updating the host's known_hosts) and this
# line had been reporting the WAL tier as deliberately-off ever since. "I could not ask"
# and "I asked and the answer was no" are different sentences and must print differently.
WAL_RAW=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "devops@$PG_VM_IP" \
    "sudo -u postgres psql -tAc \"select active::text || '|' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint / 1024 / 1024, -1) from pg_replication_slots where slot_name='$WAL_SLOT'\"" 2>&1)
WAL_RC=$?
WAL_STATE=$(echo "$WAL_RAW" | tr -d '[:space:]')
if [ "$WAL_RC" -ne 0 ]; then
    fail "wal-stream: could not query $PG_VM_IP (ssh/psql exit $WAL_RC) — the slot state is UNKNOWN, not absent: $(echo "$WAL_RAW" | first_meaningful)"
elif [ -z "$WAL_STATE" ]; then
    CHECK_OBSERVATION=unknown warn "wal-stream: no '$WAL_SLOT' slot on $PG_VM_IP — no WAL streaming protection verified (Stage 13)"
else
    WAL_ACTIVE=${WAL_STATE%%|*}
    WAL_LAG_MB=${WAL_STATE##*|}
    if [ "$WAL_ACTIVE" != "true" ] && [ "$WAL_ACTIVE" != "t" ]; then
        fail "wal-stream: slot '$WAL_SLOT' INACTIVE — pg-receivewal on the QDevice is down; RPO is back to ~1 min and WAL is accumulating toward the 10GB cap (13.5)"
    elif [ "${WAL_LAG_MB:-0}" -gt "$WAL_LAG_WARN_MB" ]; then
        warn "wal-stream: receiver connected but ${WAL_LAG_MB}MB behind — check the QDevice's disk and network (13.3)"
    else
        ok "wal-stream: receiver connected, ${WAL_LAG_MB}MB behind"
    fi
fi

# ── The fourth tier: in-VM Postgres dumps (17.5) ──────────────────────────────
CHECK_ID=postgres-dumps CHECK_CATEGORY=backups
# Reached with the devops key + passwordless sudo — the same pair the WAL check
# above uses. Plain devops cannot read the dump dir (0750 postgres:postgres),
# and the dir itself is read off the postgres crontab, because the Ansible role
# relocates it to {{ postgres_backup_mount }}/postgres when a dedicated backup
# disk is attached; PG_DUMP_DIR is only the fallback.
#
# Size is fetched alongside the timestamp, and it is not decoration. The vzdump tier
# above has always paired freshness with plausibility — MIN_SIZE_MB, "almost certainly
# broken" — while this block read mtime alone, so a pg_dump that died after creating its
# output file left a fresh, tiny archive and this printed "[ OK ] pg-dump: 3h old". The
# tier that most needs the plausibility test is this one: with no vzdump anywhere, the
# nightly dump on 1022 has been the only surviving copy of the databases.
PG_STAT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "devops@$PG_VM_IP" \
    "sudo -n -u postgres sh -c 'd=\$(crontab -l 2>/dev/null | sed -n \"s|.*>> \\(.*\\)/cron\\.log.*|\\1|p\" | head -1); d=\${d:-$PG_DUMP_DIR}; f=\$(ls -t \"\$d\"/*.dump 2>/dev/null | head -1); [ -n \"\$f\" ] && stat -c \"%Y %s\" \"\$f\"'" 2>&1)
PG_RC=$?
PG_NEWEST_TS=$(echo "$PG_STAT" | awk 'NF == 2 {print $1}')
PG_NEWEST_SZ=$(echo "$PG_STAT" | awk 'NF == 2 {print $2}')
if [ "$PG_RC" -ne 0 ]; then
    fail "pg-dump: could not reach $PG_VM_IP (ssh/sudo exit $PG_RC) — the state of the only surviving database copy is UNKNOWN: $(echo "$PG_STAT" | first_meaningful)"
elif [ -z "$PG_NEWEST_TS" ]; then
    fail "pg-dump: $PG_VM_IP answered but reported no .dump file at all — the nightly dump has never produced one (17.5)"
else
    PG_AGE_H=$(( ($(date +%s) - PG_NEWEST_TS) / 3600 ))
    PG_SIZE_MB=$(( ${PG_NEWEST_SZ:-0} / 1024 / 1024 ))
    if [ "$PG_AGE_H" -gt "$MAX_AGE_H" ]; then
        fail "pg-dump: newest dump is ${PG_AGE_H}h old — the nightly cron on 1022 stopped (17.5)"
    elif [ "$PG_SIZE_MB" -lt "$PG_MIN_SIZE_MB" ]; then
        fail "pg-dump: newest dump is only ${PG_NEWEST_SZ:-0} bytes — fresh but implausibly small, so the dump aborted after creating the file; inspect it before trusting it (17.5)"
    else
        ok "pg-dump: ${PG_AGE_H}h old, ${PG_SIZE_MB}MB"
    fi
fi

[ -z "${INFRA_CHECKS_FILE:-}" ] || printf '@complete\n' >> "$INFRA_CHECKS_FILE"
exit "$RC"
