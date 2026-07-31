# Stage 6 — The `apps` and `db` ZFS pools (both nodes)

*Part of the [Proxmox homelab guide](../README.md).*

⚠️ Pool names must be **identical** on both nodes — replication matches on pool name, character for character.

**First identify which disk is which** (Shell):
```bash
lsblk
```
```
NAME               MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
nvme0n1            259:0    0 476.9G  0 disk            ← the OS disk: has partitions
├─nvme0n1p2        259:2    0     1G  0 part /boot/efi     and pve-root / pve-swap LVs
└─nvme0n1p3        259:3    0   475G  0 part               under it. DON'T touch it.
  ├─pve-swap       252:0    0     8G  0 lvm  [SWAP]
  └─pve-root       252:1    0    96G  0 lvm  /
nvme1n1            259:4    0   1.9T  0 disk            ← data disk → pool `apps`
nvme2n1            259:8    0   1.9T  0 disk            ← data disk → pool `db`
```

The OS disk is the one carrying `/boot/efi` and the `pve-*` LVM volumes. The other two — no partitions, or leftovers from a previous life — are the data disks. If they were previously used, wipe them (CAREFUL with device names — one letter picks the wrong disk):
```bash
wipefs -a /dev/nvme1n1
wipefs -a /dev/nvme2n1
```

Then from the UI, on each node: **Disks → ZFS → Create: ZFS**
- Pool 1: Name `apps`, disk 2, RAID Level **Single Disk**, compression on, ✔ Add Storage
- Pool 2: Name `db`, disk 3, same settings

Verify: **Datacenter → Storage** — `apps` and `db` visible on both nodes.

## 6.1 Thin provisioning — set it before any VM disk exists

The **Add Storage** checkbox above registers each pool with `sparse` **off**, which is the Proxmox default and the wrong one here. A thick zvol carries a ZFS `refreservation` equal to its declared size, so the 320GB template disk in [Stage 9](../vms/09-ubuntu-template.md#92-create-the-vm-shell) would claim 320GB of real NVMe the moment it's created — for a filesystem holding about 5GB.

Turn it on now, while both pools are still empty. `sparse` applies only to volumes created *after* it's set, and at this point there is nothing to migrate:

**Datacenter → Storage → `apps` → Edit → ✔ Thin provision**, then the same for `db`. Or from the shell:
```bash
pvesm set apps --sparse 1
pvesm set db --sparse 1
grep -A6 -e 'zfspool: apps' -e 'zfspool: db' /etc/pve/storage.cfg   # expect "sparse 1" under each
```

Two consequences worth understanding, because both bite silently:

- **`discard=on` only works on thin volumes.** The VM disks in Stage 9 pass TRIM through so deleted guest blocks return to the pool — on a thick zvol the reservation holds that space anyway, and the setting buys you nothing.
- **`zpool list` reports *allocated* space, not reserved.** A thick pool can be effectively full — Proxmox refusing to create the next disk — while `zpool list` still shows single-digit usage. [`cluster-health`](../scripts/README.md) reads exactly that field, so thin provisioning is what makes its capacity check mean what it appears to mean.

> **Re-check after the cluster is formed.** `/etc/pve/storage.cfg` is cluster-wide: when pve2 joins in [Stage 7](07-cluster.md) it adopts pve1's copy and discards its own. Set this on pve1, then confirm it survived the join — before any VM disk is created in Stage 9.

**This is not overcommit.** The declared sizes fit both pools even if every guest filled its disk to the last byte: `apps` holds the template plus 1010 and 1020 (960GB of ~1.8TB usable), `db` holds 1030 alone (1TB of the same). Thin provisioning here reclaims space that was never written; it isn't a bet that the VMs stay small. The arithmetic is in [Stage 9.3](../vms/09-ubuntu-template.md#93-install-ubuntu).
