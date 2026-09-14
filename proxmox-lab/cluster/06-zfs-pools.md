# Stage 6 — The `apps` and `db` ZFS pools (both nodes)

*Part of the [Proxmox lab guide](../README.md).*

⚠️ Pool names must be **identical** on both nodes — replication matches on pool name, character for character.

**First identify which disk is which** (Shell):
```bash
lsblk
```
```
NAME               MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
nvme0n1            259:0    0 476.9G  0 disk            ← the OS disk: has partitions
├─nvme0n1p2        259:2    0     1G  0 part /boot/efi     and pve-root / pve-swap LVs
└─nvme0n1p3        259:3    0 475.9G  0 part               under it. DON'T touch it.
  ├─pve-swap       252:0    0     8G  0 lvm  [SWAP]
  └─pve-root       252:1    0 467.9G  0 lvm  /
nvme1n1            259:4    0   3.7T  0 disk            ← data disk → pool `db`
nvme2n1            259:8    0   1.9T  0 disk            ← data disk → pool `apps`
```

That is **pve2**. pve1 looks nothing like it, and the difference is the whole reason this section exists:

| | OS disk | pool `apps` | pool `db` |
|---|---|---|---|
| **pve1** | `/dev/sda` — INTEL SSDSC2BA400G4, 372.6G SATA | `/dev/sdb` — SAMSUNG MZ7KM1T9HAJM, 1.7T **SATA SSD** | `/dev/nvme0n1` — KINGSTON SFYR2S2T0, 1.9T |
| **pve2** | `/dev/nvme0n1` — SK hynix PC801, 476.9G | `/dev/nvme2n1` — KINGSTON SKC3000D2048G, 1.9T | `/dev/nvme1n1` — WD PC SN8000S, 3.7T |

Identify the OS disk from the *output* — the one carrying `/boot/efi` and the `pve-*` LVs — never from the device name. `nvme0n1` is the OS disk on pve2 and the **`db` pool** on pve1; pve1 has no `nvme1n1` or `nvme2n1` at all, and its `apps` pool is a SATA SSD rather than an NVMe. "The `nvme0n1` that must be the OS disk" is how you wipe `db`.

The pools also differ in size between the nodes (1.7T/1.9T on pve1, 1.9T/3.7T on pve2). That costs nothing — replication matches on *name*, not on geometry — but it is one more reason not to recognise a disk by its shape.

If a data disk was used before, wipe it through the path that names the hardware, not the enumeration order the kernel happened to hand out this boot (CAREFUL — one letter picks the wrong disk):
```bash
ls -l /dev/disk/by-id/                               # match model + serial against the table
wipefs -a /dev/disk/by-id/<this node's apps disk>    # e.g. ata-SAMSUNG_MZ7KM…       on pve1
wipefs -a /dev/disk/by-id/<this node's db disk>      # e.g. nvme-KINGSTON_SFYR2S2T0_… on pve1
```
`wipefs` follows the symlink, so this is the same operation under a name that survives a reboot, an added drive or a chassis swap — the three things that renumber `sdX`/`nvmeXn1` underneath you.

Both pools are created below as **Single Disk**. On a first build they are empty and a wrong wipe costs a reinstall. The cost is real when this stage is re-run against a live cluster — rebuilding one node ([Stage 19](../operations/19-node-replacement.md)) or a full restore ([Stage 17](../backup/17-backup-restore.md)) — where the peer's replica is the only other copy.

Then from the UI, on each node: **Disks → ZFS → Create: ZFS**
- Pool 1: Name `apps`, that node's `apps` disk from the table above, RAID Level **Single Disk**, compression on, ✔ Add Storage
- Pool 2: Name `db`, that node's `db` disk, same settings

Verify on each node: `zpool list` — `apps` and `db` ONLINE.

⚠️ **"Single Disk" is literal — one disk per pool, two pools per node, no mirror and no parity anywhere in this cluster.** ZFS still checksums every block and the monthly scrub Proxmox ships still reads them all ([18.7](../ha/18-failover.md#187-health-checks-worth-running-periodically)), so rot is *detected* — but with no second copy inside the vdev there is nothing to repair it from, and a disk that dies takes its pool and every VM on it with it ([18.3](../ha/18-failover.md#183-scenario-table), row *A data disk fails*). Read [`cluster-health`](../scripts/README.md)'s `zfs: all pools healthy` line that way: it says the one disk under each pool has not failed yet, and nothing more.

The trade is deliberate — two data bays per node buy either two pools or one mirrored pool, and this build takes the two, because `apps` and `db` want separate spindles more than either wants a twin. What it does is move the whole resilience story one level up, onto the two tiers underneath: the peer's replica ([Stage 12](../ha/12-replication.md)) and the backups ([Stage 17](../backup/17-backup-restore.md)). Both have to be real before this cluster carries anything you would miss, because they cover different halves. A replica is a second copy of a disk, not a backup: `pvesr` ships a wrong `zfs destroy`, a wrong `qm destroy` or a guest-side `rm -rf` to the peer on its next run — within the minute for 1022. Until Stage 17's tiers are running *and* proved by a restore drill ([17.9](../backup/17-backup-restore.md#179-restore-drills)), losing a disk is survivable and one wrong command is not.

Know the alarm path while you are here, because it is thinner than the software suggests: ZFS's own watchdog, `zed`, is active on both nodes with `ZED_EMAIL_ADDR="root"`, so it reports by mailing root and is only as alive as the [15.3](../ha/15-ha.md#153-notifications) notification chain. Prove that chain on both nodes: today root mail is generated correctly on both and then rejected by the recipient (`550 5.7.1 … blocked using Spamhaus`) and discarded, so `zed`'s mail goes nowhere at all. A failing disk then announces itself in exactly one place — `cluster-health`'s nightly `disk:` line, carried out of the node by the `infra-report` POST to the app rather than by mail ([6.2](#62-what-watches-these-pools-afterwards) has which disks it asks). That line needs `smartctl`, which lives in `/usr/sbin`, outside cron's default `PATH=/usr/bin:/bin` — which is why both the script and its cron file set `PATH`, and why a missing tool is reported as a check that did not run, never as a verdict on the disk.

⚠️ **Don't trust Datacenter → Storage here.** *Add Storage* does two things: it creates the pool *and* registers a storage entry pinned to the node you ran it on (`nodes pve1`). The nodes are still independent at this stage, so each has its own `/etc/pve/storage.cfg` and both screens look right — but at the [Stage 7](07-cluster.md) join pve2 discards its copy and adopts pve1's, leaving both pools declared pve1-only. The ZFS pools still exist on pve2 (Disks → ZFS shows them, it reads ZFS directly); the *storage* doesn't. Nothing complains until [Stage 12](../ha/12-replication.md), which fails with `storage 'apps' is not available on node 'pve2'`.

Drop the pinning now, on pve1 — deleting the restriction needs no node names, so it works before the cluster exists and survives a node replacement ([Stage 19](../operations/19-node-replacement.md)):
```bash
pvesm set apps --delete nodes
pvesm set db   --delete nodes
```

## 6.1 Thin provisioning — set it before any VM disk exists

The **Add Storage** checkbox above registers each pool with `sparse` **off**, which is the Proxmox default and the wrong one here. A thick zvol carries a ZFS `refreservation` equal to its declared size, so the 1024GB postgres disk from [Stage 10](../vms/10-vms.md#grow-the-disk--per-vm) would claim 1024GB of real NVMe the day it's created — for a database that starts near empty.

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

> **Re-check after the cluster is formed.** `/etc/pve/storage.cfg` is cluster-wide: when pve2 joins in [Stage 7](07-cluster.md) it adopts pve1's copy and discards its own. Set both this and the node un-pinning above on pve1, then confirm they survived the join — before any VM disk is created in Stage 9:
> ```bash
> grep -A8 -e 'zfspool: apps' -e 'zfspool: db' /etc/pve/storage.cfg   # "sparse 1" under each, and no "nodes" line
> pvesh get /nodes/pve2/storage                                       # apps and db listed and active
> ```

**This is not overcommit.** The declared sizes fit both pools even if every guest filled its disk to the last byte: `apps` carries the template plus 1020, 1021 and 1023 — 512GB of ~1.8TB usable — and `db` carries 1022's 1024GB alone. Thin provisioning here reclaims space that was never written; it isn't a bet that the VMs stay small. The per-VM sizes are set in [Stage 10](../vms/10-vms.md#grow-the-disk--per-vm).

## 6.2 What watches these pools afterwards

Both pools are single-disk vdevs, so SMART is the whole early-warning system: one drive going bad *is* the pool, and the first sign is either a SMART line or a missing pool. That makes *which* disks get asked a load-bearing detail, and it is exactly where the check used to go wrong. [`cluster-health`](../scripts/README.md) globbed `/dev/nvme?n1`, which describes pve2 and not pve1 — pve1's `apps` pool, holding the system disk of every guest in the cluster, sits on the SATA `/dev/sdb` from the table above and was never once looked at. No `[FAIL]`, no `[WARN]`, just silence that reads exactly like health; `smartctl -H /dev/sdb` answers `PASSED` perfectly well when something finally asks it.

The script now enumerates every block device `lsblk` reports as a disk and then drops the ones with no `/sys/block/<name>/device` link behind them, so both nodes are covered whatever they are built from — but that only reaches a node when [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run *there*. Until it has been, and any time you want the answer without waiting for cron:

```bash
for n in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [ -e "/sys/block/$n/device" ] || continue     # zvol / dm / loop — not hardware
    smartctl -H "/dev/$n"
done
```

The second line is the whole difference between three answers and thirteen. `lsblk` calls every ZFS zvol a disk as well, so each guest volume shows up as `zd0`, `zd16`, `zd32`… — ten of them on pve1 today — and `smartctl -H /dev/zd0` replies `Unable to detect device type` with a non-zero exit, which is neither a pass nor a failure. `/sys/block/<name>/device` exists only for something backed by real hardware, which is the same discriminator [`cluster-health`](../scripts/README.md) uses and needs no list to maintain. One device per invocation — `smartctl` takes no list — and expect one `PASSED` per physical disk, three on each node. Run it from the quarterly pass in [23.3](../operations/23-drill-book.md#233-the-calendar) as well: on pools with no redundancy, where the next copy of a guest is the peer's replica or its last quarterly image ([17.1](../backup/17-backup-restore.md#171-the-tiers)), an early SMART warning is the only cheap outcome available.
