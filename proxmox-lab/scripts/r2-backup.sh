#!/usr/bin/env bash
# r2-backup.sh — nightly mirror of the app's Cloudflare R2 media bucket to the
# USB drive, from where the 04:00 offsite sync (17.6) carries it on, encrypted.
#
# Why this exists: every other tier protects the VMs and Postgres. The media
# bucket (user uploads, generated products, published snapshots) lives only in
# Cloudflare — a deleted bucket, a retention-sweep bug or a leaked write-capable
# key would be a permanent loss no VM backup can answer. This makes R2 a tier
# like the others ([17.10](../backup/17-backup-restore.md)).
#
# THREE buckets since the split (platform docs/adr/0034-platform-rename.md D3b
# and D3c) — one per product plus the company's — and all three are mirrored here:
#   waa-storage    Waa's media, roots ro/ en/ dev/ — regenerable in part, and the
#                  reason this script was written.
#   educa-storage  Educa's media. Empty until Educa deploys; an empty bucket
#                  mirrors as an empty directory, not as an error.
#   app-fiscal     the company's filed invoices and accounting packages. It keeps
#                  the estate name deliberately: the ledger belongs to the legal
#                  entity, not to a product. NOT regenerable and not erasable — a
#                  filed record's retention obligation outranks an erasure
#                  request, so losing one is a compliance failure rather than a
#                  broken image. Written by FiscalServer alone and no application
#                  holds a key for it.
# The mirror token must be scoped to ALL THREE; a token that reaches only some of
# them fails the remaining passes with NoSuchBucket (Stage 22, incident table).
# Adding a product means adding its bucket to BUCKETS below and rescoping that
# one token — the mirror is the one place the three are deliberately joined.
#
# Deletions are part of the design: `rclone sync` mirrors them (an erasure
# request must eventually reach the backups too), but everything deleted or
# overwritten is first moved into a dated .trash/ dir and kept TRASH_KEEP_DAYS
# — so a bad mass-delete in R2 stays recoverable for a month, while lawful
# deletions age out of every copy on their own.
#
# Needs: an rclone remote named "r2" (type S3, provider Cloudflare) built from
# an R2 API token with READ-ONLY object access — the backup host must never
# hold a key that can delete production media. Setup: 17.10.
#
# Runs from cron at 03:30. On the node without the USB drive it exits 0
# quietly, so the same cron entry can be installed everywhere.
#
# Usage: r2-backup.sh          (no arguments, safe to re-run any time)

set -euo pipefail

RCLONE_REMOTE=r2
BUCKETS="waa-storage educa-storage app-fiscal"   # space-separated; one per product, plus the company's
USB_MOUNT=/mnt/usb-backup
DEST_ROOT=$USB_MOUNT/r2
TRASH_KEEP_DAYS=30
LOG=/var/log/rclone-r2.log

if ! mountpoint -q "$USB_MOUNT"; then
    if [ -d "$USB_MOUNT" ]; then
        echo "FAIL: $USB_MOUNT exists but nothing is mounted — the drive dropped off (17.2)" >&2
        exit 2
    fi
    # No USB storage configured on this node — the mirror lives on the peer.
    exit 0
fi

if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
    echo "FAIL: rclone remote '${RCLONE_REMOTE}:' is not configured — see 17.10 for the read-only token setup" >&2
    exit 2
fi

STAMP=$(date +%F)
for bucket in $BUCKETS; do
    DEST="$DEST_ROOT/$bucket"
    TRASH="$DEST_ROOT/.trash/$bucket"
    mkdir -p "$DEST" "$TRASH"

    # sync, not copy: deletions must propagate — but through the dated trash
    # dir, which is the undelete window. --fast-list keeps the S3 listing
    # calls (and the R2 bill for them) down.
    rclone sync "${RCLONE_REMOTE}:$bucket" "$DEST" \
        --backup-dir "$TRASH/$STAMP" \
        --fast-list --transfers 4 \
        --log-file "$LOG" --log-level INFO \
        || { echo "FAIL: rclone sync of '$bucket' returned an error — tail $LOG" >&2
             logger -t r2-backup "sync of $bucket FAILED"
             exit 1; }

    # A dated trash dir stops changing after its day; prune by age.
    find "$TRASH" -mindepth 1 -maxdepth 1 -type d -mtime +"$TRASH_KEEP_DAYS" -exec rm -rf {} +

    logger -t r2-backup "mirrored $bucket to $DEST (trash window ${TRASH_KEEP_DAYS}d)"
done
