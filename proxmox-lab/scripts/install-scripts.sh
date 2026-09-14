#!/usr/bin/env bash
# install-scripts.sh — installs the helper scripts on this node and schedules
# the recurring ones. Run on BOTH nodes, from this directory (portable-dotnet-architecture/proxmox-lab/BUILD.md#hardware-and-firmware):
#
#   cd ~/src/portable-dotnet-architecture/proxmox-lab/scripts
# ./install-scripts.sh
#
# Idempotent — re-run it after a git pull to pick up script updates.
# Scripts land in /usr/local/sbin without the .sh suffix, so the commands read
# naturally: cluster-health, backup-verify, node-return, restore-drill.

set -euo pipefail
cd "$(dirname "$0")"

for f in cluster-health.sh backup-verify.sh pve-config-backup.sh pg-offsite.sh offsite-sync.sh node-return.sh restore-drill.sh create-vms.sh infra-report.sh infra-check-output.sh infra-report-payload.py infra-host-metrics.py backup-retention.py; do
    target=${f%.sh}
    install -m 755 "$f" "/usr/local/sbin/$target"
done
rm -f /usr/local/sbin/r2-backup     # not part of the documented backup tiers

# APT success stamp. infra-host-metrics.py's package-updates probe trusts only
# /var/lib/apt/periodic/update-success-stamp, and on Debian/PVE NOTHING writes that file:
# the hook that does ships in Ubuntu's update-notifier-common, and apt.systemd.daily writes
# update-stamp instead. Without this hook the probe warned "no successful APT metadata
# refresh recorded within 48h" on both nodes permanently (found 2026-09-12). The refresh
# itself is PVE's own — pve-daily-update.timer runs `apt-get update` daily — and the hook
# fires on its success, as it does on any successful `apt update` by hand.
cat > /etc/apt/apt.conf.d/15update-success-stamp << 'EOF'
APT::Update::Post-Invoke-Success {"touch /var/lib/apt/periodic/update-success-stamp 2>/dev/null || true";};
EOF

cat > /etc/cron.d/pve-helper-scripts << 'EOF'
# Helper-script schedule — proxmox-lab/scripts/README.md
#
# Cron mails whatever the commands print; with --quiet they print only problems, so a
# healthy day sends nothing. READ THIS BEFORE RELYING ON THAT: as of 2026-09-10 root mail
# on these nodes reaches postfix correctly and is then rejected outright by the recipient's
# provider — "550 5.7.1 ... blocked using Spamhaus" on the home IP — after which postfix
# discards it. Nothing is retained locally, nothing bounces back, and PVE's own vzdump,
# replication, HA and fencing notifications go the same way, because they share the target.
# MAILTO is kept because it costs nothing and becomes useful again the moment delivery is
# fixed, but the ONLY channel that currently arrives is the infra-report POST below. Every
# recurring job is wrapped in it for exactly that reason.
MAILTO=root

# PATH is NOT decoration. Cron's default is /usr/bin:/bin, which does not include
# /usr/sbin — where smartctl, corosync-cfgtool, ha-manager, qm, dmidecode and lsmod
# live. Without this line the nightly checks still ran, still exited, still mailed,
# and were wrong in BOTH directions: smartctl missing made every healthy NVMe report
# [FAIL], while corosync-cfgtool missing made a genuinely dead ring report [ OK ].
# Both nodes sat red for a fake reason for days while a real fault read as healthy
# (2026-09-10). Note that /etc/pve/vzdump.cron, which PVE generates itself, carries
# exactly this line — the helpers simply never copied it.
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 02:40 host-config archive (both nodes), kept locally; offsite-sync uploads it at 05:00.
40 2 * * * root /usr/local/sbin/infra-report pve-config-backup >/dev/null

# Every minute: Postgres WAL, the weekly base and the nightly dumps, pulled off VM 1022 and
# uploaded to Digi. It acts only on the node running 1022 and exits at once on the
# other, so it follows the database through a migration or a failover. Not wrapped in
# infra-report — 1440 reports a day would drown the ingest; backup-verify proves each
# morning that it kept up.
* * * * * root /usr/local/sbin/pg-offsite >> /var/log/pg-offsite.log 2>&1

# 05:00 VM images and host-config archives to Digi, with their offsite retention.
0 5 * * * root /usr/local/sbin/infra-report offsite-sync >/dev/null

# The two nightly copy jobs are wrapped in infra-report rather than run bare: their failure
# would otherwise travel only as stderr -> cron mail -> root, which the top of this file
# explains delivers nothing, and the app cannot notice a job that never reports.

# Morning sweep: cluster health, then backup freshness once the offsite
# sync window has passed. infra-report passes output and exit code through
# untouched (so the mail behaviour is unchanged) and POSTs the outcome to the
# app's infra monitor — a no-op until /etc/infra-report.conf exists
# (platform/docs/ARCHITECTURE.md#probes-and-infrastructure in the app repo).
#
# 07:07 rather than 07:00 because the `*:0` replication jobs fire at HH:00:00-:09,
# and a check at 07:00:01 kept catching a normal in-flight sync and calling it a
# failure. Do NOT read the seven minutes as the fix, though: job 1022-0 is scheduled
# `*/1` and fires 1440 times a day, so no cron minute can dodge a sync. What actually
# fixed it is cluster-health no longer treating SYNCING as a fault (2026-09-10);
# moving off the top of the hour is tidiness layered on top of a real fix.
7  7 * * * root /usr/local/sbin/infra-report cluster-health --quiet
30 7 * * * root /usr/local/sbin/infra-report backup-verify  --quiet
EOF

cat > /etc/logrotate.d/pg-offsite << 'EOF'
/var/log/pg-offsite.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

# Ingest config guard — the wrapper installed above reads /etc/infra-report.conf and, when that
# file is absent, silently skips the POST: same output, same exit code, same cron mail, no reports.
# On 2026-09-04 a routine run of THIS script did exactly that on both nodes, swapping in a wrapper
# that reads a path neither node had, and ingest went dark for four days with nothing saying so.
# Hence this guard: installing the wrapper is the last moment anything says the config is missing.
# Creating it: platform/docs/waa/OPERATIONS.md#infrastructure-and-application-probes.
CONF=/etc/infra-report.conf

echo
if [ -r "$CONF" ]; then
    echo "Ingest: $CONF present — the wrapper will report."
    grep -q '^INFRA_PEER_ADDRESS=' "$CONF" ||
        echo "...but without INFRA_PEER_ADDRESS (the OTHER node's LAN address), so cluster-health's lan-sample warns on every run — platform/docs/waa/OPERATIONS.md#infrastructure-and-application-probes."
else
    echo "Ingest: WARNING — no $CONF on this host."
    echo "  infra-report is a silent pass-through: the checks still run and still mail, but the"
    echo "  app is told nothing. Create the file per platform/docs/waa/OPERATIONS.md#infrastructure-and-application-probes"
    echo "  section 1, step 4 (INFRA_URL + INFRA_TOKEN, mode 600), then re-run one by hand."
fi
command -v sensors >/dev/null 2>&1 ||
    echo "Sensors: WARNING — lm-sensors is not installed, so cluster-health's temperatures check warns on every run: apt install -y lm-sensors (portable-dotnet-architecture/proxmox-lab/BUILD.md#hardware-and-firmware)."
[ -e /var/lib/apt/periodic/update-success-stamp ] ||
    echo "APT: the success stamp does not exist yet — run 'apt-get update' once, or package-updates warns until pve-daily-update.timer next succeeds."
if ! command -v rclone >/dev/null 2>&1; then
    echo "Offsite: WARNING — rclone is not installed, so pg-offsite and offsite-sync upload nothing."
    echo "  Install/configure it per proxmox-lab/RECOVERY.md#digi-storage-and-rclone, then rerun this installer."
elif ! rclone listremotes 2>/dev/null | grep -qx 'digi-crypt:'; then
    echo "Offsite: WARNING — 'digi-crypt:' is missing; both upload jobs fail until the encrypted remote passes the documented acceptance check."
fi
echo

echo "Installed to /usr/local/sbin: cluster-health backup-verify pve-config-backup pg-offsite offsite-sync node-return restore-drill create-vms infra-report"
echo "Scheduled via /etc/cron.d/pve-helper-scripts (config backup 02:40, Postgres offsite every minute, images + config offsite 05:00, health 07:07, backup check 07:30)"
echo "NOTE: that cron file is rewritten wholesale on every run — put operator additions in a separate /etc/cron.d/ file, not in this one."
echo "Not scheduled on purpose: node-return, restore-drill and create-vms are attended operations."
