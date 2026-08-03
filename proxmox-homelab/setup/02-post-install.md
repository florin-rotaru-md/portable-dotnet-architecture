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

## 2.2 Update, microcode, and reboot

**Shell** (node → Shell, or SSH as root):
```bash
apt update && apt full-upgrade -y
```

Then the firmware baseline. Two of the three layers in [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely) are ordinary apt packages, and this is where they go in: **CPU microcode**, which is where most firmware-level security fixes actually reach you, and **`fwupd`**, which from here on tells you what the *flashed* firmware is running without you having to look it up. Microcode lives in Debian's `non-free-firmware` component, which a Proxmox install doesn't enable:

```bash
# adjust the suite to your Proxmox release: trixie on PVE 9, bookworm on PVE 8
echo 'deb http://deb.debian.org/debian trixie main contrib non-free-firmware' \
    > /etc/apt/sources.list.d/non-free-firmware.list
apt update && apt install -y intel-microcode fwupd
reboot
```

After the reboot, `grep -m1 microcode /proc/cpuinfo` should show a higher revision than before, and `journalctl -k | grep -i microcode` records the early load. Do the same on the QDevice when you get to [Stage 8](../cluster/08-qdevice.md) — same two packages, stock Debian repositories, no extra line needed.

Take these updates whenever they appear; they carry no more risk than any other package. That is emphatically **not** the policy for flashing a BIOS, which is the rest of [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely).

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
cd portable-dotnet-architecture/proxmox-homelab/scripts
chmod +x install-scripts.sh
./install-scripts.sh
```

This installs them into `/usr/local/sbin` (so `cluster-health` works from anywhere) and schedules the recurring ones via `/etc/cron.d/pve-helper-scripts`. To update later: `cd /root/src/portable-dotnet-architecture && git pull && proxmox-homelab/scripts/install-scripts.sh`.

Right now, most `cluster-health` lines will be warnings — no cluster, no pools, no replication yet. That's expected; it becomes the daily "is everything fine" command once the build reaches Stage 13. Run it after each stage from here on and watch warnings turn into `[ OK ]` lines as the pieces come up.

## 2.5 Install the node's key pair (both nodes)

The pairs were generated in [0.5](00-preparation.md#05-keys--generate-all-of-them-now); this installs each node's own. Do it now rather than at [9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults) — the key is what will open every VM later, and a node without it can't reach its own guests.

From your workstation, with the node's root password (the hosts *do* accept passwords — only the VMs don't):

```bash
# pve1 — its own pair, plus the four public halves that 9.4 turns into vm_keys.pub
scp ~/lab-keys/pve1_root ~/lab-keys/*.pub root@192.168.0.11:/tmp/
ssh root@192.168.0.11 'install -d -m 700 /root/.ssh &&
    install -m 600 /tmp/pve1_root     /root/.ssh/id_ed25519 &&
    install -m 644 /tmp/pve1_root.pub /root/.ssh/id_ed25519.pub &&
    install -m 644 /tmp/*.pub         /root/.ssh/ && rm -f /tmp/*_root /tmp/*.pub'

# pve2 — its own pair only
scp ~/lab-keys/pve2_root ~/lab-keys/pve2_root.pub root@192.168.0.12:/tmp/
ssh root@192.168.0.12 'install -d -m 700 /root/.ssh &&
    install -m 600 /tmp/pve2_root     /root/.ssh/id_ed25519 &&
    install -m 644 /tmp/pve2_root.pub /root/.ssh/id_ed25519.pub && rm -f /tmp/pve2_root*'
```

On Windows use `$env:USERPROFILE\lab-keys\...` in the `scp` lines; the remote halves are identical.

Verify on each node — the fingerprint should match the one your password manager holds for that key:

```bash
ssh-keygen -lf /root/.ssh/id_ed25519.pub
```

**Then delete the staging folder** (`rm -rf ~/lab-keys`, or `Remove-Item -Recurse -Force "$env:USERPROFILE\lab-keys"`). The two node keys are now on their nodes *and* in your password manager, the four public halves are on pve1, and the break-glass private key belongs nowhere but the password manager and paper. What's left after this point is one copy of each key on the machine that uses it — which is the property the rest of [21.5](../operations/21-credentials.md#215-recovery-scenarios--what-losing-each-thing-actually-means) assumes.

Two things this is **not**. It is not the key Proxmox uses between the nodes — cluster root SSH is set up by `pvecm add` and lives in `/etc/pve/priv/authorized_keys`, untouched by any of this. And it is not backed up by [`pve-config-backup`](../scripts/README.md), deliberately: that archive lands unencrypted on the USB drive, and a skeleton key doesn't belong there. The password manager copy from [0.5](00-preparation.md#05-keys--generate-all-of-them-now) is this key's backup — which is also what turns a rebuilt node ([19.2 step 5](../operations/19-node-replacement.md#5-build-the-new-node)) back into a node that opens every existing VM.
