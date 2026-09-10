#!/usr/bin/env bash
# r2-backup.sh — nightly mirror of the app's three Cloudflare R2 buckets (two of
# media, one of filed invoices — see below) to the USB drive, from where the 04:00
# offsite sync (17.6) carries them on, encrypted.
#
# Why this exists: every other tier protects the VMs and Postgres. What is in R2
# — user uploads, generated products, published snapshots, and the fiscal ledger —
# lives only in Cloudflare, so a deleted bucket, a retention-sweep bug or a leaked
# write-capable key would be a permanent loss no VM backup can answer. This makes
# R2 a tier like the others ([17.10](../backup/17-backup-restore.md)).
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
# Needs: rclone on the host (17.6's `apt install rclone -y` — this tier rides on the
# same binary the 04:00 offsite sync uses) and a remote named "r2" (type S3, provider
# Cloudflare) built from an R2 API token with READ-ONLY object access — the backup host
# must never hold a key that can delete production media. Setup: 17.6, then 17.10.
# Both belong to the node that HOLDS the USB drive; the peer needs neither.
#
# Runs from cron at 03:30. On a node without the USB drive it exits 0 quietly, so
# the same cron entry can be installed everywhere — and that convenience is the
# trap: the branch never tests its own premise, which is that some OTHER node holds
# the drive. On 2026-09-10 neither pve1 nor pve2 had /mnt/usb-backup at all, so both
# took the quiet exit 0 and this tier had never run once — no /var/log/rclone-r2.log
# on either host, rclone not even installed. backup-verify and cluster-health took
# the same hatch, which is why nothing on the estate ever reported the R2 mirror
# absent. Those two now ask the cluster-wide question (is any vzdump job scheduled
# at all?) and fail loudly when the answer is no — in this repo; the copies under
# /usr/local/sbin are the 2026-09-04 ones until 2.4 is re-run on that node. And it
# answers for vzdump, not for this tier: backup-verify's `r2-mirror:` line still sits
# past the USB gate.
# No pmxcfs file answers "is anyone mirroring R2?", so this script stays silent by
# design and the proof has to come from outside it: never count the tier as present
# because the cron entry is installed — /var/log/rclone-r2.log must exist and end in
# a transfer summary with no ERROR (Stage 22.2, the proof table).
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

# Two prerequisites, two different remedies — and one check used to report the first
# as the second. `rclone listremotes` on a host without the binary exits 127, its
# "command not found" goes into the 2>/dev/null below, and grep's empty input makes
# the pipeline fail in exactly the way a missing remote does. The operator was then
# sent to 17.10 — `rclone config` — on a host where that command does not exist.
# Not hypothetical: on 2026-09-10 neither node had rclone installed at all and no
# node held the drive, so this guard had never run once since the script was written;
# the first person to attach a drive would have read precisely the wrong instruction.
# Both checks stay BELOW the mount gate on purpose. rclone is a prerequisite of the
# node that holds the drive, not of the peer (17.10 sets this up on pve1 alone), so
# failing here on a driveless node would paint that node red in the admin UI every
# night, through infra-report, about a node with nothing wrong with it. "Does ANY
# node hold the drive?" is a cluster-wide question and is asked where a node can
# answer it: backup-verify's USB block, against jobs.cfg/vzdump.cron.
if ! command -v rclone >/dev/null 2>&1; then
    echo "FAIL: rclone is not on this host's PATH — install it per 17.6 (\`apt install rclone\`, which lands in /usr/bin and is on cron's PATH; the upstream installer's /usr/local/bin is NOT), then configure the read-only remote per 17.10" >&2
    exit 2
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
