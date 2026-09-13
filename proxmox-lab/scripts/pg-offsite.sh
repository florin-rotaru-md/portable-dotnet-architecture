#!/usr/bin/env bash
# pg-offsite.sh — every minute on both nodes. On the node running VM 1022 ("the active node"), pull what
# the postgres role spools in the VM — WAL files, the weekly base backup, the nightly logical dumps — into
# local staging, upload it to Digi Storage, and only then release it from the VM
# (proxmox-lab/backup/17-backup-restore.md, 17.4). The other node exits at once, so the job follows the
# database through a migration or an HA failover without anyone moving it.
#
# A WAL file leaves the VM's spool only after its upload succeeded and it is settled here; until then
# every run retries it, from whichever node is active. Output goes to /var/log/pg-offsite.log (the cron
# line); nothing here reports to the app per run — backup-verify proves each morning that the newest
# archived WAL file, base backup and dump run are on Digi.
#
# Usage: pg-offsite [--now]
#   --now   also run the base/logical pass and the retention pass, whatever the clock says

set -uo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}
export PATH

VMID=1022
PG_VM_IP=192.168.0.22
SPOOL=/opt/postgres/wal-spool
BASE_DIR=/opt/postgres/base
DUMP_DIR=/opt/postgres/backups
STAGE=${PG_OFFSITE_STAGE:-/var/lib/vz/postgres}
REMOTE=digi-crypt:postgres
LOCAL_BASES_KEEP=2
REMOTE_BASES_KEEP=4
LOCAL_LOGICAL_DAYS=9            # longer than the VM keeps them (7), or expired runs are pulled again
REMOTE_LOGICAL_DAYS=30
RETENTION=${BACKUP_RETENTION:-$(dirname "$(readlink -f "$0")")/backup-retention.py}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
RCLONE_OPTS=(--retries 3 --low-level-retries 5 --stats 0 --log-level ERROR)
WAL_NAME='^[0-9A-F]{8}([0-9A-F]{16})?(\.[0-9A-F]{8}\.backup|\.partial|\.history)?\.zst$'

[ "$(qm status "$VMID" 2>/dev/null | awk '{print $2}')" = running ] || exit 0

exec 9> "${PG_OFFSITE_LOCK:-/run/pg-offsite.lock}"
flock -n 9 || exit 0

NOW=0
[ "${1:-}" = "--now" ] && NOW=1
RC=0
log()    { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
fail()   { log "FAIL: $*"; RC=1; }
remote() { $SSH "devops@$PG_VM_IP" "$@"; }
rcl()    { timeout 900 rclone "$@"; }
pull() {  # <remote dir> <local dir> [rsync filter args...]
    local src=$1 dst=$2
    shift 2
    rsync -a --timeout=60 -e "$SSH" --rsync-path='sudo -n rsync' "$@" "devops@$PG_VM_IP:$src/" "$dst/"
}

command -v rclone > /dev/null || { fail "rclone is not installed on this node (17.3)"; exit 1; }
umask 077
mkdir -p "$STAGE/wal/incoming" "$STAGE/base/incoming" "$STAGE/logical/incoming"

retention() {
    local tmp oldest cutoff stamp
    tmp=$(mktemp -d)

    # Here: the newest LOCAL_BASES_KEEP bases, the WAL since the oldest of them, dumps by age.
    while read -r stamp; do
        rm -rf -- "${STAGE:?}/base/$stamp" && log "retention: local base $stamp removed"
    done < <(ls -1 "$STAGE/base" | python3 "$RETENTION" newest-prune "$LOCAL_BASES_KEEP")
    oldest=$(ls -1 "$STAGE/base" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | head -1)
    if [ -n "$oldest" ] && cutoff=$(python3 "$RETENTION" wal-start "$STAGE/base/$oldest/backup_manifest"); then
        ls -1 "$STAGE/wal" | python3 "$RETENTION" wal-prune "$cutoff" | sed "s|^|$STAGE/wal/|" | xargs -r -d '\n' rm -f --
    fi
    ls -1 "$STAGE/logical" | python3 "$RETENTION" older-than "$LOCAL_LOGICAL_DAYS" \
        | sed "s|^|$STAGE/logical/|" | xargs -r -d '\n' rm -f --

    # Digi: the same rules over longer windows. WAL is never pruned without a base to cut it against.
    if rcl lsf --dirs-only "$REMOTE/base" > "$tmp/bases" 2> /dev/null; then
        while read -r stamp; do
            if rcl purge "$REMOTE/base/$stamp" "${RCLONE_OPTS[@]}"; then
                log "retention: Digi base $stamp removed"
            else
                fail "retention: could not remove Digi base $stamp"
            fi
        done < <(python3 "$RETENTION" newest-prune "$REMOTE_BASES_KEEP" < "$tmp/bases")
        oldest=$(sed 's:/$::' "$tmp/bases" | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort | tail -n "$REMOTE_BASES_KEEP" | head -1)
        if [ -n "$oldest" ] && rcl cat "$REMOTE/base/$oldest/backup_manifest" > "$tmp/manifest" 2> /dev/null \
            && cutoff=$(python3 "$RETENTION" wal-start "$tmp/manifest"); then
            rcl lsf --files-only "$REMOTE/wal" 2> /dev/null | python3 "$RETENTION" wal-prune "$cutoff" > "$tmp/wal"
            if [ -s "$tmp/wal" ]; then
                if rcl delete "$REMOTE/wal" --files-from "$tmp/wal" --no-traverse "${RCLONE_OPTS[@]}"; then
                    log "retention: $(wc -l < "$tmp/wal") WAL file(s) before $cutoff removed from Digi"
                else
                    fail "retention: WAL cleanup on Digi failed"
                fi
            fi
        fi
    else
        fail "retention: cannot list $REMOTE/base"
    fi
    rcl lsf --files-only "$REMOTE/logical" 2> /dev/null | python3 "$RETENTION" older-than "$REMOTE_LOGICAL_DAYS" > "$tmp/logical"
    if [ -s "$tmp/logical" ] && ! rcl delete "$REMOTE/logical" --files-from "$tmp/logical" --no-traverse "${RCLONE_OPTS[@]}"; then
        fail "retention: dump cleanup on Digi failed"
    fi
    rm -rf "$tmp"
}

# ── WAL: list the spool, pull, upload, settle, release ───────────────────────
# Released only when this run pulled cleanly and nothing is left waiting in incoming: after an HA
# failover the VM can spool a file under a name already settled here with other content, and releasing
# by name alone would delete it unseen. A clean pull has copied any such file into incoming.
if SPOOLED=$(remote "sudo -n find $SPOOL -maxdepth 1 -type f -name '*.zst' -printf '%f\n'"); then
    PULLED=1
    if [ -n "$SPOOLED" ]; then
        pull "$SPOOL" "$STAGE/wal/incoming" --include='*.zst' --exclude='*' --compare-dest="$STAGE/wal/" \
            || { PULLED=0; fail "wal: pull from $PG_VM_IP:$SPOOL failed"; }
    fi
    mapfile -t NEW < <(find "$STAGE/wal/incoming" -maxdepth 1 -type f -name '*.zst' -printf '%f\n' | sort)
    if [ "${#NEW[@]}" -gt 0 ]; then
        if rcl copy "$STAGE/wal/incoming" "$REMOTE/wal" --no-traverse --transfers 4 "${RCLONE_OPTS[@]}"; then
            for name in "${NEW[@]}"; do
                mv -f "$STAGE/wal/incoming/$name" "$STAGE/wal/$name"
            done
            log "wal: uploaded ${#NEW[@]} file(s), newest ${NEW[-1]}"
        else
            fail "wal: upload of ${#NEW[@]} file(s) to $REMOTE/wal failed; kept in incoming for the next run"
        fi
    fi
    if [ "$PULLED" = 1 ] && [ -n "$SPOOLED" ] && [ -z "$(ls -A "$STAGE/wal/incoming")" ]; then
        SETTLED=$(printf '%s\n' "$SPOOLED" | grep -E "$WAL_NAME" | while read -r name; do
            [ -f "$STAGE/wal/$name" ] && printf '%s/%s\n' "$SPOOL" "$name"
        done)
        if [ -n "$SETTLED" ]; then
            printf '%s\n' "$SETTLED" | remote "sudo -n xargs -r -d '\n' rm -f --" \
                || fail "wal: could not release settled files from $PG_VM_IP:$SPOOL"
        fi
    fi
else
    fail "wal: cannot list $PG_VM_IP:$SPOOL"
fi

# ── Base backups and logical dumps: every 15 minutes ─────────────────────────
if [ "$NOW" = 1 ] || [ $((10#$(date +%M) % 15)) -eq 0 ]; then
    NEW_BASE=0

    # Only completed, verified directories: pg-basebackup.sh writes <stamp>.partial and renames last.
    if pull "$BASE_DIR" "$STAGE/base/incoming" --exclude='*.partial' --exclude='*.log' --compare-dest="$STAGE/base/"; then
        for dir in "$STAGE"/base/incoming/*/; do
            [ -f "${dir}backup_manifest" ] || continue
            stamp=$(basename "$dir")
            if rcl copy "$dir" "$REMOTE/base/$stamp" --transfers 2 "${RCLONE_OPTS[@]}"; then
                rm -rf -- "${STAGE:?}/base/$stamp"
                mv "$dir" "$STAGE/base/$stamp"
                log "base: uploaded $stamp"
                NEW_BASE=1
            else
                fail "base: upload of $stamp failed; kept in incoming for the next run"
            fi
        done
        find "$STAGE/base/incoming" -mindepth 1 -type d -empty -delete
    else
        fail "base: pull from $PG_VM_IP:$BASE_DIR failed"
    fi

    # Only the files of runs whose "Backup complete" line pg-backup.sh has written.
    if pull "$DUMP_DIR" "$STAGE/logical/incoming" --include='*.dump' --include='globals_*.sql.gz' \
        --include='cron.log' --exclude='*' --compare-dest="$STAGE/logical/"; then
        [ -f "$STAGE/logical/incoming/cron.log" ] && mv -f "$STAGE/logical/incoming/cron.log" "$STAGE/logical/cron.log"
        DONE=$(grep -o 'Backup complete - globals_[0-9]\{8\}-[0-9]\{6\}' "$STAGE/logical/cron.log" 2> /dev/null | sed 's/.*globals_//' | sort -u)
        LIST=$(mktemp)
        for file in "$STAGE"/logical/incoming/*; do
            [ -f "$file" ] || continue
            stamp=$(basename "$file" | grep -o '[0-9]\{8\}-[0-9]\{6\}')
            [ -n "$stamp" ] && printf '%s\n' "$DONE" | grep -qx "$stamp" && basename "$file" >> "$LIST"
        done
        if [ -s "$LIST" ]; then
            if rcl copy "$STAGE/logical/incoming" "$REMOTE/logical" --files-from "$LIST" --no-traverse "${RCLONE_OPTS[@]}"; then
                while read -r name; do
                    mv -f "$STAGE/logical/incoming/$name" "$STAGE/logical/$name"
                done < "$LIST"
                log "logical: uploaded $(wc -l < "$LIST") file(s)"
            else
                fail "logical: upload failed; kept in incoming for the next run"
            fi
        fi
        rm -f "$LIST"
    else
        fail "logical: pull from $PG_VM_IP:$DUMP_DIR failed"
    fi

    if [ "$NEW_BASE" = 1 ] || [ "$NOW" = 1 ] || [ "$(date +%H%M)" = "0430" ]; then
        retention
    fi
fi

exit "$RC"
