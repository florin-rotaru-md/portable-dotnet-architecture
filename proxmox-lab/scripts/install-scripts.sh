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

for f in cluster-health.sh backup-verify.sh pve-config-backup.sh node-return.sh restore-drill.sh create-vms.sh; do
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

# Morning sweep: cluster health, then backup freshness once the offsite
# sync window has passed (backup-verify exits quietly on the non-USB node)
0  7 * * * root /usr/local/sbin/cluster-health --quiet
30 7 * * * root /usr/local/sbin/backup-verify  --quiet
EOF

echo "Installed to /usr/local/sbin: cluster-health backup-verify pve-config-backup node-return restore-drill create-vms"
echo "Scheduled via /etc/cron.d/pve-helper-scripts (config backup 02:40, health 07:00, backup check 07:30)"
echo "Not scheduled on purpose: node-return, restore-drill and create-vms are attended operations."
