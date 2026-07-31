# Stage 5 — The `apps` and `db` ZFS pools (both nodes)

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
