#!/usr/bin/env bash
# install-scripts.sh — installs the helper scripts on this node and schedules
# the recurring ones. Run on BOTH nodes, from this directory (Stage 2.4):
#
#   cd ~/src/portable-dotnet-architecture/proxmox-lab/scripts
#   ./install-scripts.sh
#
# Idempotent — re-run it after a git pull to pick up script updates.
# Scripts land in /usr/local/sbin without the .sh suffix, so the commands read
# naturally: cluster-health, backup-verify, node-return, restore-drill.

set -euo pipefail
cd "$(dirname "$0")"

for f in cluster-health.sh backup-verify.sh pve-config-backup.sh r2-backup.sh node-return.sh restore-drill.sh create-vms.sh infra-report.sh; do
    install -m 755 "$f" "/usr/local/sbin/${f%.sh}"
done

cat > /etc/cron.d/pve-helper-scripts << 'EOF'
# Helper-script schedule — proxmox-lab/scripts/README.md
# Cron mails whatever the commands print; with --quiet they print only
# problems, so root gets mail exactly when something needs a human.
MAILTO=root

# 02:40 host-config archive (both nodes) — after the 02:15 in-VM pg dump,
# before the 03:00 vzdump and the 04:00 offsite sync (the 17.5 ordering chain)
40 2 * * * root /usr/local/sbin/pve-config-backup >/dev/null

# 03:30 R2 media mirror (17.10) — lands on the USB drive in time for the
# 04:00 offsite sync to ship it; exits quietly on the node without the drive
30 3 * * * root /usr/local/sbin/r2-backup >/dev/null

# Morning sweep: cluster health, then backup freshness once the offsite
# sync window has passed (backup-verify exits quietly on the non-USB node).
# infra-report passes output and exit code through untouched (so the mail
# behaviour is unchanged) and POSTs the outcome to the app's infra monitor —
# a no-op until /etc/waa-infra-report.conf exists (ADR-0015 in the app repo).
0  7 * * * root /usr/local/sbin/infra-report cluster-health --quiet
30 7 * * * root /usr/local/sbin/infra-report backup-verify  --quiet
EOF

echo "Installed to /usr/local/sbin: cluster-health backup-verify pve-config-backup r2-backup node-return restore-drill create-vms"
echo "Scheduled via /etc/cron.d/pve-helper-scripts (config backup 02:40, R2 mirror 03:30, health 07:00, backup check 07:30)"
echo "Not scheduled on purpose: node-return, restore-drill and create-vms are attended operations."
