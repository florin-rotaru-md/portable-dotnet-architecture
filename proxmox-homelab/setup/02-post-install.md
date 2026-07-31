# Stage 2 — Post-install (both nodes)

*Part of the [waa Proxmox homelab guide](../README.md).*

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
