# Stage 17 — Backup & restore

*Part of the [Proxmox lab guide](../README.md).*

## 17.1 The tiers

Each one answers a different disaster. None substitutes for another:

| Tier | Interval | Protects against | Recovery time |
|---|---|---|---|
| **ZFS replication** (Stage 12) | 1-15 min | A node dying | ~2-3 min, automatic |
| **WAL stream → QDevice** ([Stage 13](../ha/13-wal-stream.md)) | Continuous (~seconds) | The last minute a failover would otherwise lose; also unlocks any-second PITR | Minutes ([scenario G](#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice)) |
| **Local backup** (USB) | Daily | Deletion, corruption, a bad deploy, ransomware | Minutes to an hour |
| **Offsite copy** (Digi Storage) | Daily | Fire, theft, flood, both nodes gone | Hours (download-bound) |
| **R2 media mirror** ([17.10](#1710-a-fifth-tier-for-the-r2-media-bucket)) | Daily | The one data set that lives only in Cloudflare — a deleted bucket, a retention-sweep bug, a leaked write-capable key | Minutes (copy back from the drive) |

> Replication is **not** backup. It copies a `DROP TABLE` to the other node just as faithfully as it copies good data.

## 17.2 Backup storage — the USB drive

```bash
lsblk -f          # identify the USB disk (e.g. sdb2)
blkid             # the partition UUID

mkdir -p /mnt/usb-backup
nano /etc/fstab
```
Add (with your UUID):
```
UUID=30848B8B848B51F0 /mnt/usb-backup ntfs-3g defaults,nofail,x-systemd.automount 0 0
```
```bash
systemctl daemon-reload
mount -a
pvesm add dir usb-backup --path /mnt/usb-backup --content backup
```

> **If the drive doesn't need to be Windows-readable, format it ext4 instead of NTFS.** `ntfs-3g` runs in userspace, is noticeably slower on multi-GB writes, and doesn't handle sparse files — an ext4 drive makes nightly backups quicker and smaller. The fstab line becomes `UUID=… /mnt/usb-backup ext4 defaults,nofail 0 2`.

Attach the drive to **pve1** and leave it there. Backups run cluster-wide from whichever node holds each VM, but the job needs the storage to exist where it runs — so either mark the storage as restricted to pve1 (Datacenter → Storage → `usb-backup` → Nodes: pve1) and schedule the job on pve1, or plug a second drive into pve2 and repeat.

## 17.3 The scheduled job

**Datacenter → Backup → Add:**

| Field | Value | Why |
|---|---|---|
| Node | pve1 (where the USB drive is) | |
| Storage | `usb-backup` | |
| Schedule | `03:00` daily | Quiet hours, and deliberately **after** the 02:15 in-VM Postgres dump ([17.5](#175-a-fourth-tier-for-the-database)) so the archive contains a fresh one — still well clear of the 04:00 offsite sync |
| Selection mode | All (or explicitly 1020, 1021, 1022, 1023) | "All" automatically picks up VMs you add later |
| Mode | **Snapshot** | The VM keeps running. With `qemu-guest-agent` installed (Stage 9.2) Proxmox freezes the filesystem for the instant the snapshot is taken, so the image is filesystem-consistent, not just crash-consistent |
| Compression | ZSTD | Best ratio-to-speed on this hardware |
| Retention | keep-daily 7, keep-weekly 4, keep-monthly 3 | ~14 restore points across three months, without unbounded growth |
| Notification | your email | |

Two extras worth setting:
- **Datacenter → Notifications** — make sure failures actually reach you. A backup job that has been failing quietly for three weeks is the classic way to discover you have no backups at the worst possible moment.
- **Bandwidth limit** on the job (Advanced tab) if backups ever interfere with anything: `--bwlimit` in KB/s.

## 17.4 On-demand backup (before anything risky)

Always take one before a migration to new hardware, a major upgrade, or a schema change:

```bash
vzdump 1022 --storage usb-backup --mode snapshot --compress zstd
```

All four at once:
```bash
vzdump 1020 1021 1022 1023 --storage usb-backup --mode snapshot --compress zstd
```

## 17.5 A fourth tier for the database

A VM image restores the whole machine — it cannot give you back one accidentally deleted table. **This tier already exists and needs no work here:** the Ansible `postgres` role installs `/opt/postgres/scripts/pg-backup.sh` and a nightly cron for it, so it lands on 1022 the moment you run `bootstrap.yml`.

What it does each night at **02:15** (`postgres_backup_hour` / `postgres_backup_minute` in group_vars — the schedule is policy, so it lives next to the other policy, not hardcoded in the role), as the `postgres` user:

| | |
|---|---|
| `globals_<stamp>.sql.gz` | roles, passwords, tablespaces — the restore prerequisite people forget |
| `<db>_<stamp>.dump` | one custom-format (`-Fc`) dump per database, parallel-restore friendly and portable across major versions |
| Location | `/opt/postgres/backups` (or `{{ postgres_backup_mount }}/postgres` if you attach a dedicated backup disk) |
| Retention | `backup_retention_days`, default 7 |

Because it writes to the VM's own disk, the dumps are swept up by the nightly `vzdump` and the offsite sync automatically — no extra plumbing. Restoring a single table becomes `pg_restore -t` instead of a full VM restore.

> **Order the two jobs correctly.** With the Proxmox backup at 02:00 and the in-VM dump at 02:15, every archive captures dumps that are already ~24h old. Schedule the Proxmox job at **03:00** ([17.3](#173-the-scheduled-job)) and the chain becomes: 02:15 logical dump → 03:00 VM image containing that dump → 04:00 offsite sync. Same three tiers, one fewer day of drift. If you ever move one side of this contract — the cron vars in group_vars or the vzdump schedule — move the other with it.

## 17.6 Offsite — Digi Storage via rclone

Digi Storage has native rclone support (the `digistorage` provider). First generate an app password: https://storage.rcs-rds.ro/app/admin/preferences/password

On pve1:
```bash
apt install rclone -y
rclone config
# n (new) → name: digi → storage: koofr → provider: digistorage
# user: <your Digi username> → password: <the generated app password>

# Encryption layer on top (customer data shouldn't leave in cleartext):
rclone config
# n → name: digi-crypt → storage: crypt → remote: digi:proxmox-backups
# → choose encryption passwords
```

⚠️ **Write the encryption passwords down and store them somewhere that survives the house** — a password manager, or on paper away from the lab. Without them the offsite backups are mathematically unrecoverable, which turns your disaster tier into an expensive illusion.

Automatic sync after the nightly backup — the whole drive, not just `dump/`, so the host-config archives from [`pve-config-backup`](../scripts/README.md) and the R2 media mirror ([17.10](#1710-a-fifth-tier-for-the-r2-media-bucket)) ride along:
```bash
crontab -e
```
```
0 4 * * * rclone sync /mnt/usb-backup digi-crypt: --transfers 2 --log-file /var/log/rclone-backup.log
```

Verify it's actually landing:
```bash
rclone ls digi-crypt: | tail
tail -20 /var/log/rclone-backup.log
```

---

## 17.7 Restore — pick your scenario

Backups in the UI: select the **storage** in the tree (not the VM) → **Backups** tab. Every archive is listed with its VM ID, date and size.

### A. Restore into a NEW VM ID (safest — start here)

Use this when you want to inspect a backup, recover files, or test that a restore works, without touching the running VM.

```bash
qmrestore /mnt/usb-backup/dump/vzdump-qemu-1021-2026_07_29-03_00_01.vma.zst 1121 \
  --storage apps --unique
```

- `1121` — a free VM ID, not the original
- `--unique` — **important**: regenerates the MAC address so the clone doesn't collide with the still-running original
- After it finishes, change the IP in **Cloud-Init** before starting it, or it will fight the original for `192.168.0.21`

Copy out what you need, then `qm stop 1121 && qm destroy 1121`.

### B. Restore OVER an existing VM (in place)

When the VM itself is broken and you want it back as it was. This **destroys the current disk** — take an on-demand backup first if there's anything salvageable.

```bash
# 1. Take the VM out of HA so it doesn't get restarted mid-restore
ha-manager remove vm:1021

# 2. Stop it
qm stop 1021

# 3. Restore
qmrestore /mnt/usb-backup/dump/vzdump-qemu-1021-2026_07_29-03_00_01.vma.zst 1021 \
  --storage apps --force

# 4. Start and verify
qm start 1021
```

Or from the UI: storage → Backups → select archive → **Restore** → target VM ID → tick *Force* → Restore.

**Then finish the job** — see the post-restore checklist in 17.8.

### C. Restore onto the other node

Same command, run from that node's shell, with the archive reachable from it. If the USB drive is only on pve1, copy the archive across first (the 10G link makes this quick):

```bash
# on pve2
scp root@10.10.10.1:/mnt/usb-backup/dump/vzdump-qemu-1022-2026_07_29-03_00_01.vma.zst /var/lib/vz/dump/
qmrestore /var/lib/vz/dump/vzdump-qemu-1022-2026_07_29-03_00_01.vma.zst 1022 --storage db --force
```

### D. Recovering individual files

Proxmox's single-file restore in the GUI needs Proxmox Backup Server; with plain vzdump archives, the pragmatic route is scenario **A**: restore to a spare VM ID, start it with the network detached (Hardware → Network Device → uncheck *Connected*), and pull the files out via the console or by attaching its disk to another VM.

For the database specifically, the nightly dumps from [17.5](#175-a-fourth-tier-for-the-database) make this unnecessary — `/opt/postgres/backups` is sitting inside the restored disk, and `pg_restore -l` / `-t` gets you a single table out of a `.dump` without touching the running database.

### E. Restore from offsite

```bash
rclone ls digi-crypt:dump                                # find the archive
rclone copy digi-crypt:dump/vzdump-qemu-1022-2026_07_29-03_00_01.vma.zst /mnt/usb-backup/dump/
qmrestore /mnt/usb-backup/dump/vzdump-qemu-1022-2026_07_29-03_00_01.vma.zst 1022 --storage db --force
```

Decryption is transparent — rclone handles it as long as the `digi-crypt` remote is configured with the right passwords.

### F. Full disaster recovery (both nodes gone)

The order matters:

1. Install Proxmox on the replacement hardware (Stages 1-2).
2. Recreate the ZFS pools with the **same names**, `apps` and `db` (Stage 6). Names are what everything else keys off.
3. Install and configure rclone with the `digi-crypt` remote (17.6) — **this is the step that needs the encryption passwords you stored offsite.**
4. Pull the archives down and `qmrestore` each VM.
5. Rebuild the cluster, replication, and HA (Stages 7, 8, 12, 15) — these are configuration, not data, and take minutes.
6. Point Cloudflare Tunnel at the restored app VM.

Note what's *not* in this list: the frontend, which lives on Cloudflare and was never affected.

### G. Replaying the last seconds after a failover (WAL from the QDevice)

Requires [Stage 13](../ha/13-wal-stream.md). The situation: a node died, HA restarted 1022 from a replica up to a minute old, and that minute held writes that matter. The missing seconds exist in the QDevice's WAL archive — the work is standing up a scratch database that replays to the moment of death, then taking what you need from it.

**Build the replayed copy:**

```bash
# 1. Restore last night's 1022 archive to a spare ID — the base must be OLDER
#    than the failover, on the same timeline; the 03:00 vzdump qualifies
qmrestore /mnt/usb-backup/dump/vzdump-qemu-1022-<last-night>.vma.zst 1122 --storage apps --unique
# give it a spare IP via Cloud-Init (say .122 — spare ID 11NN takes spare IP .1NN) before starting — 20.3 step 0 shows this pattern

# 2. Inside 1122: stop postgres, bring the WAL over, arm recovery
systemctl stop postgresql
# WHICH archive: after a failover the window you came for is in the directory the guard moved aside
# (13.5), not in the live one — the receiver has been streaming into a fresh archive ever since it
# restarted. Look before you copy:
#   ssh devops@192.168.0.10 'ls -1d /var/lib/wal-archive*'
# Take the newest `wal-archive.diverged-<timestamp>`; if there is none, the failover did not clobber
# anything and `/var/lib/wal-archive` is the right source.
rsync -a --rsync-path='sudo rsync' devops@192.168.0.10:/var/lib/wal-archive.diverged-<timestamp>/ /var/lib/postgresql/wal-replay/

# The seconds you came here for are in the segment that was still being written,
# and pg_receivewal deliberately leaves it named "<segment>.partial" — it logs
# "not renaming …, segment is not complete" rather than promote it. Postgres only
# ever asks restore_command for the canonical name, so without this rename the
# replay stops at the last COMPLETE segment and silently returns less than the
# replication interval already gave you. A partial segment replays fine: recovery
# reads record by record and stops cleanly at the last whole one.
cd /var/lib/postgresql/wal-replay && for f in *.partial; do
    [ -e "$f" ] && mv "$f" "${f%.partial}"
done

chown -R postgres:postgres /var/lib/postgresql/wal-replay
sudo -u postgres tee -a /etc/postgresql/18/main/postgresql.conf << 'EOF'
restore_command = 'cp /var/lib/postgresql/wal-replay/%f %p'
EOF
sudo -u postgres touch /var/lib/postgresql/18/main/recovery.signal
systemctl start postgresql            # replays everything up to seconds before the death
tail -f /var/log/postgresql/*.log     # watch for "archive recovery complete"
```

**Then pick the path that matches what happened since the failover:**

- **The live 1022 has already taken new writes** (the normal case — HA had it back in ~3 minutes): extract the delta from 1122 — the rows stamped in the lost window — and merge them into the live database (`pg_dump -t <table>` + `INSERT … ON CONFLICT`, or by hand for a handful of rows). Merging is an application-level judgment call: inserts are mechanical, updated rows need a decision about which version wins. Then destroy 1122.
- **The live 1022 has no new writes yet** (you stopped the app slots fast, or the outage is ongoing): don't merge — swap. Stop the app, verify 1122's row counts against live, and promote the replayed copy to be the real 1022 (restore it over per [scenario B](#b-restore-over-an-existing-vm-in-place), or re-IP it). Zero loss, no reconciliation.

**The same recipe is general PITR:** add `recovery_target_time = '2026-07-30 14:31:50+03'` (and `recovery_target_action = 'promote'`) next to `restore_command`, and 1122 stands up as of any second the 7-day archive covers — the "undo the 14:32 mistake" path, with the damage inspected on a scratch VM before you commit to anything.

## 17.8 Post-restore checklist

A restored VM comes back as a plain VM — the cluster machinery around it does not follow automatically:

```bash
# 1. Replication — the old job now points at a disk that no longer exists
pvesr status
# if the job errors, delete and recreate it (a full resync follows):
pvesr delete <jobid>
# then re-add from the UI: VM → Replication → Add

# 2. HA — re-add if you removed it in step B.1
#    both flags default to 1; pass them or the guest comes back movable (15.5)
ha-manager add vm:1021 --state started --failback 0 --auto-rebalance 0
ha-manager status

# 3. Guest agent reporting (confirms the VM booted properly)
qm agent 1021 ping
```

Also check inside the VM:
- The IP is what you expect (`ip a`) — a restore preserves the cloud-init config, but a `--unique` restore changes the MAC, which matters if anything upstream keys off it
- `cloudflared` is running, if this is 1021
- Postgres accepted the restore and recovered cleanly (`systemctl status postgresql`, then check the log tail for recovery messages)

## 17.9 Restore drills

A backup you have never restored is a hypothesis.

- **Monthly:** scenario A on one VM — restore to a spare ID, boot it, confirm it works, destroy it. Ten minutes — or one command: [`restore-drill`](../scripts/README.md) does exactly this (NIC disconnected, guest-agent boot proof, auto-cleanup) and logs the measured RTO to `/var/log/restore-drill.log`.
- **Quarterly:** scenario E — pull one archive from Digi Storage and restore it. This is the only way to find out whether the encryption passwords still work *before* you need them. If [13](../ha/13-wal-stream.md) is enabled, run scenario G's replay against the drill VM while it's up — that proves the WAL archive actually replays, not just accumulates. While you're there, open one file out of the R2 mirror ([17.10](#1710-a-fifth-tier-for-the-r2-media-bucket)) — an image that renders is the whole proof.
- **After any change** to storage layout, Proxmox major version, or backup configuration.

Write down how long each takes. Those numbers are your real RTO, as opposed to the one you assume you have.

## 17.10 A fifth tier for the R2 media bucket

Every tier above protects the VMs and Postgres. The app's media — user uploads, generated
products, published event snapshots — lives in a Cloudflare R2 bucket and **nowhere else**: no
vzdump contains it, no dump can regenerate the originals. Snapshots can be rebuilt by
republishing; a couple's photos cannot. A deleted bucket, a bug in the app's retention sweep
(which deletes whole prefixes by design), or a leaked write-capable key would be a permanent
loss. This tier is the answer: a nightly [`r2-backup`](../scripts/README.md) mirror onto the USB
drive, which the 04:00 sync ([17.6](#176-offsite--digi-storage-via-rclone)) then carries offsite,
encrypted, with everything else.

**One-time setup, on pve1:**

1. In the Cloudflare dashboard: **R2 → Manage API Tokens → Create API Token** — permission
   **Object Read only**, scoped to the bucket. Read-only is the point: the backup host must
   never hold a key that can delete production media, so a compromise of pve1 cannot become a
   compromise of the bucket.
2. Configure the remote (the S3 endpoint is on the same dashboard page):
   ```bash
   rclone config
   # n (new) → name: r2 → storage: s3 → provider: Cloudflare
   # access_key_id / secret_access_key: from the token you just created
   # endpoint: https://<account-id>.r2.cloudflarestorage.com
   ```
3. `rclone ls r2:statics-waa | head` — if that lists objects, the tier works; the cron entry
   from [`install-scripts.sh`](../scripts/README.md) (03:30) does the rest.

The first run downloads the whole bucket — size it against your line, and add `--bwlimit` in the
script for that one night if it competes with anything. Every later run moves only the delta.

**Deletions are mirrored on purpose, with an undo window.** The sync uses `--backup-dir`: anything
deleted or overwritten in R2 is moved into `r2/.trash/<bucket>/<date>/` on the drive and kept 30
days, then pruned. So a bad mass-delete stays recoverable for a month — while a lawful erasure
(GDPR) propagates to the mirror the next night and ages out of the trash, and out of the offsite
copy, on its own. No copy keeps what the law said to delete.

**Restoring media** is `rclone copy` in the other direction — from the mirror (or from
`digi-crypt:r2/...` if the drive is gone too) back into the bucket. Mint a **write-capable token
for the occasion and revoke it afterwards**; the stored remote deliberately cannot write. A single
lost object is `rclone copy /mnt/usb-backup/r2/statics-waa/<path> r2rw:statics-waa/<dir>`; a
prefix works the same way. The app addresses objects by stable paths (`{root}/events/{uid}/…`),
so copied-back objects are immediately served — no database surgery involved.

`backup-verify` watches this tier like the others: sync log fresh, no errors. The quarterly
drill ([17.9](#179-restore-drills)) opens one mirrored file — an image that renders proves the
whole chain, R2 → USB → eye.

Day-to-day operation — the routine proofs, the incident table (failing sync, mass delete,
deleted bucket, leaked token, faster-than-the-window erasure) and the write-back recipe — lives
in [Stage 22](../operations/22-r2-mirror.md).
