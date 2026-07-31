# Stage 2 — Post-install (both nodes)

*Part of the [Proxmox homelab guide](../README.md).*

## 2.1 Switch to the No-Subscription repositories

A fresh install points apt at the **enterprise** repositories, which require a paid subscription — until you change this, `apt update` fails with a 401 error and the node gets no updates at all.

In the web UI, select the **node** in the left tree (not Datacenter) → **Updates → Repositories**:

1. Select the row with `https://enterprise.proxmox.com/debian/pve` → **Disable**
2. Select the row with `https://enterprise.proxmox.com/debian/ceph-squid` → **Disable** (the Ceph version in the URL varies by release; disable whatever `enterprise.proxmox.com/debian/ceph-*` row is there — this build doesn't use Ceph either way)
3. **Add → No-Subscription → Add**

The result should show the enterprise rows greyed out and a `pve-no-subscription` row enabled. Repeat on the other node — repositories are per node, not cluster-wide.

> The "No valid subscription" dialog at login stays — it's a reminder, not an error, and everything works. The no-subscription repo is the officially provided free tier; its packages are the same, just published without the extra enterprise QA soak.

## 2.2 Update and reboot

**Shell** (node → Shell, or SSH as root):
```bash
apt update && apt full-upgrade -y
reboot
```

## 2.3 Hardware check

**Shell:**
```bash
lspci | grep -i ethernet     # pve1: two X550 entries
lsblk                        # all 3 NVMe drives visible
```

If an NVMe drive is missing from `lsblk`, it's almost always VMD/RST still enabled in BIOS (Stage 0.1) — fix that before going further, not after.

## 2.4 Install the helper scripts (both nodes)

The repo ships a small set of host-side scripts — a one-command health check, backup freshness verification, a nightly archive of the host's own config, and guided versions of the two riskiest procedures (node return, restore drill). What each does and when: [`scripts/README.md`](../scripts/README.md).

```bash
apt install -y git smartmontools
mkdir -p /root/src && cd /root/src
git clone https://github.com/florin-rotaru-md/portable-dotnet-architecture
chmod +x install-scripts.sh
cd portable-dotnet-architecture/proxmox-homelab/scripts
./install-scripts.sh
```

This installs them into `/usr/local/sbin` (so `cluster-health` works from anywhere) and schedules the recurring ones via `/etc/cron.d/pve-helper-scripts`. To update later: `cd /root/src/portable-dotnet-architecture && git pull && proxmox-homelab/scripts/install-scripts.sh`.

Right now, most `cluster-health` lines will be warnings — no cluster, no pools, no replication yet. That's expected; it becomes the daily "is everything fine" command once the build reaches Stage 13. Run it after each stage from here on and watch warnings turn into `[ OK ]` lines as the pieces come up.
