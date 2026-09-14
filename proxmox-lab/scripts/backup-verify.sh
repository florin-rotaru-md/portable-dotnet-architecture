#!/usr/bin/env bash
# backup-verify.sh — answers one question: "am I protected RIGHT NOW?"
#
# Every tier ends on Digi Storage (portable-dotnet-architecture/proxmox-lab/RECOVERY.md), so most questions are
# asked of Digi rather than of the staging a tier passes through: the newest WAL file Postgres archived
# is offsite, the newest weekly base is younger than 8 days, the newest complete logical-dump run is
# offsite, every VM has an image younger than a quarter, and every node's host-config archive is from
# last night. Two questions go to the source, because Digi cannot answer them: is the archiver on 1022
# failing, and is its spool being drained.
#
# Runs on both nodes (cron 07:30, wrapped in infra-report); each run checks the whole estate, so a node
# that is down leaves the other one answering.
#
# Output: one line per check, [ OK ] / [WARN] / [FAIL].
# Exit:   0 = all OK, 1 = warnings, 2 = at least one failure.
#
# Usage: backup-verify [--quiet]
#   --quiet   print only WARN/FAIL lines (for cron)

set -uo pipefail

# /usr/sbin holds several of the tools below, cron's default PATH does not include it, and cron is not
# the only thing that runs this.
PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

VMS="1020 1021 1022 1023"
CONFIG_HOSTS="pve1 pve2"
PG_VM_IP=192.168.0.22
PG_DUMP_DIR=/opt/postgres/backups       # fallback — the real dir is read off the postgres crontab
SPOOL=/opt/postgres/wal-spool
REMOTE=digi-crypt:
VZDUMP_MAX_AGE_D=93                     # quarterly images plus slack
BASE_MAX_AGE_D=8                        # weekly base plus slack
CONFIG_MAX_AGE_H=30                     # 02:40 archive, 05:00 upload
SPOOL_MAX_AGE_MIN=15                    # pg-offsite drains the spool every minute
LOGICAL_MAX_AGE_H=26                    # nightly logical dump
LOGICAL_UPLOAD_GRACE_H=1                # a run younger than this may not have been pulled yet
PG_SHRINK_FLOOR_BYTES=65536             # a dump under half its predecessor warns, once that predecessor is past this
RETENTION=${BACKUP_RETENTION:-$(dirname "$(readlink -f "$0")")/backup-retention.py}

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
rcl()  { timeout 300 rclone "$@"; }
# stdin names -> "<name><TAB><hours>" of the newest of that kind (backup-retention.py newest-age)
newest() { python3 "$RETENTION" newest-age "$@"; }

# The first line of a failed ssh is often the row of @ signs from the host-key banner, which tells the
# reader nothing. Quote the first line that carries actual words.
first_meaningful() { grep -vE '^[[:space:]@*=-]*$' | head -1; }

# ── Offsite: can this node see Digi at all? ──────────────────────────────────
CHECK_ID=offsite CHECK_CATEGORY=backups
OFFSITE=0
if ! have rclone; then
    fail "offsite: rclone is not installed; see RECOVERY.md#digi-storage-and-rclone"
elif ! rclone listremotes 2>/dev/null | grep -qx "$REMOTE"; then
    fail "offsite: rclone remote '$REMOTE' is missing; see RECOVERY.md#digi-storage-and-rclone"
elif ! have python3 || [ ! -r "$RETENTION" ]; then
    fail "offsite: $RETENTION is missing, so ages on Digi cannot be read — re-run install-scripts.sh"
elif ! PROBE=$(rcl lsf --max-depth 1 "$REMOTE" 2>&1); then
    fail "offsite: Digi did not answer a listing of '$REMOTE': $(printf '%s\n' "$PROBE" | first_meaningful); see RECOVERY.md#digi-storage-and-rclone"
else
    OFFSITE=1
    ok "offsite: '$REMOTE' answers"
fi

# The archiver on 1022 and its spool
CHECK_ID=pg-archive CHECK_CATEGORY=backups
# Asked of the source, because Digi cannot see it: a failing archive_command leaves no file to find
# offsite, only WAL piling up in pg_wal. The remote half travels on stdin — ssh, sudo and sh -c would
# otherwise be three layers of quoting.
read -r -d '' ARCHIVER_SCRIPT << 'EOS'
psql -XAtF '|' -c "select current_setting('archive_mode'), archived_count, coalesce(last_archived_wal, ''),
  coalesce(extract(epoch from last_archived_time)::bigint, 0), failed_count, coalesce(last_failed_wal, ''),
  coalesce(extract(epoch from last_failed_time)::bigint, 0), extract(epoch from now())::bigint
  from pg_stat_archiver" | sed 's/^/archiver|/'
now=$(date +%s)
find "$1" -maxdepth 1 -type f -name '*.zst' -printf '%T@\n' 2>/dev/null | sort -n \
  | awk -v now="$now" 'NR == 1 {oldest = $1} END {printf "spool|%d|%d\n", NR, NR ? now - oldest : 0}'
printf 'diverged|%d\n' "$(find "$1" -maxdepth 1 -type f -name '*.diverged-*' 2>/dev/null | wc -l)"
exit 0
EOS
ARCH=$(printf '%s\n' "$ARCHIVER_SCRIPT" | ssh -o BatchMode=yes -o ConnectTimeout=5 "devops@$PG_VM_IP" \
    "sudo -n -u postgres sh -s -- '$SPOOL'" 2>&1)
ARCH_RC=$?
IFS='|' read -r _ A_MODE _ A_LAST A_LAST_T A_FAILED A_FAILED_WAL A_FAILED_T A_NOW \
    <<< "$(printf '%s\n' "$ARCH" | grep '^archiver|' | head -1)"
IFS='|' read -r _ S_COUNT S_OLDEST <<< "$(printf '%s\n' "$ARCH" | grep '^spool|' | head -1)"
IFS='|' read -r _ DIVERGED <<< "$(printf '%s\n' "$ARCH" | grep '^diverged|' | head -1)"
if [ "$ARCH_RC" -ne 0 ] || [ -z "${A_MODE:-}" ]; then
    fail "pg-archive: could not query $PG_VM_IP (ssh/sudo/psql exit $ARCH_RC), so the WAL tier's state is UNKNOWN: $(printf '%s\n' "$ARCH" | first_meaningful)"
    A_LAST=""
elif [ "$A_MODE" != "on" ]; then
    fail "pg-archive: archive_mode is '$A_MODE' on 1022 — no WAL is archived, so nothing can be replayed onto a base"
    A_LAST=""
elif [ "${A_FAILED_T:-0}" -gt "${A_LAST_T:-0}" ]; then
    fail "pg-archive: archive_command is failing — $A_FAILED failure(s), the last on $A_FAILED_WAL $(( (A_NOW - A_FAILED_T) / 60 )) min ago; WAL is piling up in pg_wal on 1022"
elif [ "${S_OLDEST:-0}" -gt $((SPOOL_MAX_AGE_MIN * 60)) ]; then
    fail "pg-archive: the spool on 1022 holds ${S_COUNT:-?} file(s), the oldest $(( S_OLDEST / 60 )) min old — pg-offsite is not draining it (on the node running 1022: tail /var/log/pg-offsite.log)"
elif [ "${A_LAST_T:-0}" -eq 0 ]; then
    warn "pg-archive: archiving is on but nothing has been archived yet"
else
    ok "pg-archive: last archived $A_LAST $(( (A_NOW - A_LAST_T) / 60 )) min ago, spool holds ${S_COUNT:-0} file(s)"
fi
if [ "${DIVERGED:-0}" -gt 0 ]; then
    warn "pg-archive: $DIVERGED WAL file(s) set aside as *.diverged-* in $SPOOL on 1022 — a failover rewrote archived WAL; inspect, then delete them"
fi

CHECK_ID=pg-wal-offsite CHECK_CATEGORY=backups
if [ "$OFFSITE" = 1 ] && [ -n "${A_LAST:-}" ]; then
    if rcl lsf --files-only "${REMOTE}postgres/wal" --include "$A_LAST.zst" 2>/dev/null | grep -qx "$A_LAST.zst"; then
        ok "pg-wal-offsite: newest archived WAL file $A_LAST is on Digi"
    elif [ $(( A_NOW - A_LAST_T )) -lt $((SPOOL_MAX_AGE_MIN * 60)) ]; then
        warn "pg-wal-offsite: newest archived WAL file $A_LAST is not on Digi yet ($(( (A_NOW - A_LAST_T) / 60 )) min old)"
    else
        fail "pg-wal-offsite: newest archived WAL file $A_LAST is NOT on Digi, $(( (A_NOW - A_LAST_T) / 60 )) min after it was archived"
    fi
fi

# The weekly base backup
CHECK_ID=pg-base CHECK_CATEGORY=backups
if [ "$OFFSITE" = 1 ]; then
    NEWEST_BASE=$(rcl lsf --dirs-only "${REMOTE}postgres/base" 2>/dev/null | newest base)
    if [ -z "$NEWEST_BASE" ]; then
        fail "pg-base: no base backup on Digi — the WAL there has nothing to replay onto"
    else
        BASE_H=${NEWEST_BASE##*$'\t'}
        BASE_H=${BASE_H%.*}
        if [ "$BASE_H" -gt $((BASE_MAX_AGE_D * 24)) ]; then
            fail "pg-base: newest base backup on Digi is ${NEWEST_BASE%%$'\t'*}, $(( BASE_H / 24 )) days old — the weekly job on 1022 or its upload stopped"
        else
            ok "pg-base: newest base backup on Digi is ${NEWEST_BASE%%$'\t'*} (${BASE_H}h old)"
        fi
    fi
fi

# The nightly logical dumps
CHECK_ID=postgres-dumps CHECK_CATEGORY=backups
# A run proves itself: pg-backup.sh (roles/postgres) runs under `set -euo pipefail`, stamps every file of
# one run with the same STAMP, and prints "Backup complete - globals_<STAMP>.sql.gz + <N> database(s)" as
# its last act, so a pg_dump that fails stops the script before that line exists. The check is that the
# newest stamp is fresh, the completion line names it, and N dumps carry it. Size survives only as a
# comparison with the same database's previous dump, as a WARN: a clean dump of a database that lost
# its rows is still a clean dump, and the retention window is what makes noticing it urgent. An absolute
# size floor cannot tell a small database from a truncated dump, and the databases here are small.
read -r -d '' DUMP_SCRIPT << 'EOS'
d=$(crontab -l 2>/dev/null | sed -n 's|.*>> \(.*\)/cron\.log.*|\1|p' | head -1)
d=${d:-$1}
echo "dir $d"
grep 'Backup complete' "$d/cron.log" 2>/dev/null | tail -1 | sed 's/^/done /'
find "$d" -maxdepth 1 -type f \( -name '*.dump' -o -name 'globals_*.sql.gz' \) -printf 'file %T@ %s %f\n' 2>/dev/null
exit 0
EOS
PG_REPORT=$(printf '%s\n' "$DUMP_SCRIPT" | ssh -o BatchMode=yes -o ConnectTimeout=5 "devops@$PG_VM_IP" \
    "sudo -n -u postgres sh -s -- '$PG_DUMP_DIR'" 2>&1)
PG_RC=$?
PG_DIR=$(printf '%s\n' "$PG_REPORT" | sed -n 's/^dir //p' | head -1)
PG_DONE=$(printf '%s\n' "$PG_REPORT" | sed -n 's/^done //p' | tail -1)
# "<mtime> <bytes> <name>", one line per file. Every name ends in _<YYYYmmdd-HHMMSS>.dump or .sql.gz,
# and those stamps sort as text, so the greatest one is the newest run.
PG_FILES=$(printf '%s\n' "$PG_REPORT" | awk '$1 == "file" && NF == 4 {printf "%d %s %s\n", $2, $3, $4}')
PG_STAMP=$(printf '%s\n' "$PG_FILES" | awk 'NF == 3 {
    n = $3; sub(/\.dump$/, "", n); sub(/\.sql\.gz$/, "", n); s = substr(n, length(n) - 14)
    if (length(s) == 15 && s ~ /^[0-9]+-[0-9]+$/) print s }' | sort | tail -1)
if [ "$PG_RC" -ne 0 ] || [ -z "$PG_DIR" ]; then
    fail "pg-dump: could not reach $PG_VM_IP (ssh/sudo exit $PG_RC), so the state of the logical dumps is UNKNOWN: $(printf '%s\n' "$PG_REPORT" | first_meaningful)"
elif [ -z "$PG_STAMP" ]; then
    fail "pg-dump: $PG_VM_IP answered but $PG_DIR holds no dump at all — the nightly dump has never produced one"
else
    PG_NEWEST_TS=$(printf '%s\n' "$PG_FILES" | awk -v s="_$PG_STAMP." 'index($3, s) {print $1}' | sort -n | tail -1)
    PG_AGE_H=$(( ($(date +%s) - ${PG_NEWEST_TS:-0}) / 3600 ))
    PG_DONE_STAMP=$(printf '%s\n' "$PG_DONE" | sed -n 's/.*globals_\([0-9-]*\)\.sql\.gz.*/\1/p')
    PG_DONE_COUNT=$(printf '%s\n' "$PG_DONE" | sed -n 's/.* + \([0-9][0-9]*\) database.*/\1/p')
    PG_COUNT=$(printf '%s\n' "$PG_FILES" | awk -v s="_$PG_STAMP.dump" 'NF == 3 && substr($3, length($3) - length(s) + 1) == s' | wc -l)
    PG_KB=$(printf '%s\n' "$PG_FILES" | awk -v s="_$PG_STAMP." 'index($3, s) {t += $2} END {printf "%d", t / 1024}')
    PG_COMPLETE=0
    if [ "$PG_AGE_H" -gt "$LOGICAL_MAX_AGE_H" ]; then
        fail "pg-dump: newest run ($PG_STAMP) is ${PG_AGE_H}h old — the nightly cron on 1022 stopped"
    elif [ "$PG_DONE_STAMP" != "$PG_STAMP" ]; then
        fail "pg-dump: newest run ($PG_STAMP) never logged 'Backup complete' — pg-backup.sh stops at the first failed pg_dump, so at least one database has no dump from it (last completed run: ${PG_DONE_STAMP:-none}); tail $PG_DIR/cron.log"
    elif [ "$PG_COUNT" -ne "${PG_DONE_COUNT:-0}" ]; then
        fail "pg-dump: run $PG_STAMP logged ${PG_DONE_COUNT:-?} database(s) but $PG_COUNT dump file(s) carry its stamp — a dump was removed after the run; inspect $PG_DIR"
    else
        ok "pg-dump: run $PG_STAMP complete — $PG_COUNT database(s), ${PG_AGE_H}h old, ${PG_KB} KB"
        PG_COMPLETE=1
    fi
    # Asked whatever the verdict above. For each database: this run's dump against the newest older dump
    # of the same database. The name is <db>_<stamp>.dump and a database name may itself contain
    # underscores, so the stamp is cut off by length, not at the last "_".
    PG_SHRUNK=$(printf '%s\n' "$PG_FILES" | awk -v S="$PG_STAMP" -v floor="$PG_SHRINK_FLOOR_BYTES" '
        NF == 3 && $3 ~ /\.dump$/ {
            n = $3; sub(/\.dump$/, "", n)
            s = substr(n, length(n) - 14); db = substr(n, 1, length(n) - 16)
            if (length(s) != 15 || s !~ /^[0-9]+-[0-9]+$/ || db == "") next
            if (s == S) cur[db] = $2 + 0
            else if (s < S && s > seen[db]) { seen[db] = s; prev[db] = $2 + 0 }
        }
        END { for (db in cur) if ((db in prev) && prev[db] >= floor + 0 && cur[db] * 2 < prev[db]) print db, prev[db], cur[db] }')
    # A here-string, not a pipe: warn() must set RC in this shell, not in a subshell.
    while read -r db was now; do
        [ -n "$db" ] || continue
        warn "pg-dump: $db shrank from $was to $now bytes since its previous dump — a clean dump of a database that lost rows, or a deliberate purge; confirm which before retention rotates the larger dump away"
    done <<< "$PG_SHRUNK"

    CHECK_ID=pg-dump-offsite
    if [ "$OFFSITE" = 1 ] && [ "$PG_COMPLETE" = 1 ]; then
        if rcl lsf --files-only "${REMOTE}postgres/logical" --include "globals_$PG_STAMP.sql.gz" 2>/dev/null \
            | grep -qx "globals_$PG_STAMP.sql.gz"; then
            ok "pg-dump-offsite: run $PG_STAMP is on Digi"
        elif [ "$PG_AGE_H" -lt "$LOGICAL_UPLOAD_GRACE_H" ]; then
            warn "pg-dump-offsite: run $PG_STAMP is not on Digi yet (${PG_AGE_H}h old)"
        else
            fail "pg-dump-offsite: run $PG_STAMP (${PG_AGE_H}h old) is NOT on Digi — pg-offsite pulls completed runs every 15 minutes"
        fi
    fi
fi

# VM images
CHECK_ID=vzdump CHECK_CATEGORY=backups
if [ "$OFFSITE" = 1 ]; then
    IMAGES=$(rcl lsf --files-only "${REMOTE}vzdump" --include 'vzdump-qemu-*.vma.zst' 2>/dev/null)
    for vm in $VMS; do
        NEWEST_IMAGE=$(printf '%s\n' "$IMAGES" | newest vzdump "$vm")
        if [ -z "$NEWEST_IMAGE" ]; then
            fail "vzdump $vm: no image on Digi — run the job or Backup now, then offsite-sync"
            continue
        fi
        IMAGE_H=${NEWEST_IMAGE##*$'\t'}
        IMAGE_D=$(( ${IMAGE_H%.*} / 24 ))
        if [ "$IMAGE_D" -gt "$VZDUMP_MAX_AGE_D" ]; then
            fail "vzdump $vm: newest image on Digi is $IMAGE_D days old — the quarterly job missed a run"
        else
            ok "vzdump $vm: newest image on Digi is $IMAGE_D day(s) old"
        fi
    done
fi

# Host configuration archives
CHECK_ID=config-backups CHECK_CATEGORY=backups
if [ "$OFFSITE" = 1 ]; then
    for host in $CONFIG_HOSTS; do
        NEWEST_CONFIG=$(rcl lsf --files-only "${REMOTE}config/$host" 2>/dev/null | newest stamped "pve-config-$host-")
        if [ -z "$NEWEST_CONFIG" ]; then
            fail "config $host: no archive on Digi — pve-config-backup or offsite-sync is not running there"
            continue
        fi
        CONFIG_H=${NEWEST_CONFIG##*$'\t'}
        CONFIG_H=${CONFIG_H%.*}
        if [ "$CONFIG_H" -gt "$CONFIG_MAX_AGE_H" ]; then
            fail "config $host: newest archive on Digi is ${CONFIG_H}h old — pve-config-backup or offsite-sync stopped on $host"
        else
            ok "config $host: newest archive on Digi is ${CONFIG_H}h old"
        fi
    done
fi

[ -z "${INFRA_CHECKS_FILE:-}" ] || printf '@complete\n' >> "$INFRA_CHECKS_FILE"
exit "$RC"
