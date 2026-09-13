# Stage 17 — Backup & restore

*Part of the [Proxmox lab guide](../README.md).*

## 17.1 The tiers

Every tier ends on Digi Storage, encrypted client-side, and passes through local staging on a node first. Times are host time (Europe/Bucharest, summer); VM 1022 keeps its clock on UTC.

| Tier | What | When | Kept on the node | Kept on Digi | Answers |
|---|---|---|---|---|---|
| **Postgres WAL** ([17.4](#174-postgres--continuous-wal-and-a-weekly-base)) | every completed WAL file of the cluster on 1022 | continuously — ≤ 60 s to the VM's spool, ≤ 1 min to Digi | since the older of 2 bases | since the oldest of 4 bases | deletion, corruption, a bad migration — back to any second the WAL covers |
| **Postgres base** (17.4) | a verified physical base backup | weekly, Sunday 03:45 | 2 | 4 | the starting point the WAL replays onto |
| **Postgres logical dumps** (17.4) | `pg_dump -Fc` per database, plus globals | nightly, 03:15 | 9 days | 30 days | one table or one database back without a replay; a restore into another major version |
| **VM images** ([17.5](#175-vm-images--quarterly-and-on-demand)) | vzdump of 1020–1023 | quarterly (1 Jan/Apr/Jul/Oct, 04:15) and on demand | newest 1 per VM | newest 2 per VM | a broken VM; whatever Ansible does not rebuild |
| **Host configuration** ([17.6](#176-host-configuration-and-the-ansible-inventory)) | `/etc/pve`, network, cron files, manifests — per node | nightly, 02:40 | 14 archives | 30 days | rebuilding a node |
| **Ansible inventory** (17.6) | the operator inventory, `vault.yml` included | by hand, after every change | — | dated copies | rebuilding the VMs from git |
| **ZFS replication** ([Stage 12](../ha/12-replication.md)) | VM disks, pve1 → pve2 | 1–60 min per VM | — | — | a node dying |

> **Replication is not backup.** It copies a `DROP TABLE` to the other node just as faithfully as it copies good data.

**The R2 buckets are not backed up.** `waa-storage`, `educa-storage` and `app-fiscal` — user uploads, generated products, published snapshots and the company's filed fiscal documents — exist only in Cloudflare R2. Nothing in this estate copies them: a deleted bucket, a bug in a retention sweep or a leaked write-capable key is a permanent loss. That is a decision, not an unbuilt tier.

**Recovery points.** Database: ~1–2 minutes offsite, and point-in-time recovery to any second since the oldest kept base (≈ 2 weeks from the node, ≈ 4 weeks from Digi). After an unplanned HA failover the writes 1022's replica did not yet have — at most its one-minute replication interval — are gone; the archive holds what the server wrote, not what it lost. VM images: the last quarterly or on-demand image, and every VM is also rebuildable from git and Ansible given the inventory. Host configuration: one day.

**What watches it.** [`backup-verify`](../scripts/README.md) at 07:30 on both nodes asks Digi, not the staging: the newest WAL file Postgres archived is there, the newest base is younger than 8 days, the newest complete dump run is there, every VM has an image younger than 93 days, every node's config archive is from last night — and it asks 1022 whether the archiver is failing and the spool is draining. `cluster-health` fails when no vzdump job is scheduled anywhere. The app's infra monitor sees each VM's newest image task (93 days) and whether the nightly jobs reported at all (platform `docs/waa/infra/OPERATIONS.md`). A green line is a claim; the restore drills in [17.9](#179-restore-drills) are the proof.

## 17.2 Local staging — `local` on each node

Backups are written to the node's `local` storage (`/var/lib/vz`, on the `pve/root` volume) before they go offsite. The installer's `local-lvm` thin pool holds nothing on this build — every VM disk lives on the ZFS pools — so its space is given to `local`. Check it is empty first, then on **each node**:

```bash
lvs -a pve                               # data: Data% 0.00, and no thin volumes listed under it
pvesm remove local-lvm                   # once, from either node — the storage list is cluster-wide
lvremove -y pve/data
lvextend -r -l +100%FREE pve/root        # grows the ext4 root online
df -h /                                  # ~350G on pve1, ~460G on pve2
```

Then, once, the storage settings that make `local` the backup target and bound what it keeps:

```bash
pvesm set local --content iso,vztmpl,backup,import --prune-backups keep-last=1
```

`keep-last=1` applies to every image written to `local`, by the job and by *Backup now* alike — the second copy of each image lives on Digi.

What lands where:

| Path | Holds | Written by |
|---|---|---|
| `/var/lib/vz/dump/` | VM images and their `.log`/`.notes` | vzdump, on the node running the guest |
| `/var/lib/vz/postgres/wal/`, `base/`, `logical/` | the Postgres tiers pulled off 1022 | `pg-offsite`, on the node running 1022 |
| `/var/backups/pve-config/` | this node's configuration archives | `pve-config-backup`, on both nodes |

**The active node** is the one running 1022. It pulls and uploads the Postgres tiers and prunes the images on Digi; the other node does neither, and takes over the moment 1022 migrates or fails over to it — nothing needs moving.

> **`/` is now also the backup volume.** A full root filesystem stops pmxcfs, the API and every guest configuration with it. Retention is what bounds it — one image per VM, two bases, nine days of dumps — and the app's `storage` check warns at 80 % and fails at 90 % for `local` on both nodes. An on-demand image of every VM costs roughly 10 GB; take them, but do not stockpile them here.

## 17.3 Offsite — Digi Storage

The offsite store is a **Digi Storage Business** account (RCS & RDS). rclone reaches it through its Koofr backend (provider `digistorage`), authenticated by an app password, with an rclone **crypt** remote on top so nothing leaves the lab in cleartext.

Two properties of the service shape everything else: a deleted file stays recoverable in Digi's *Deleted Files* for **48 hours** only, and there is **no version history**. Whoever holds the app password can delete every backup; the retention in 17.4–17.6 is the only thing that deletes on purpose.

**One-time setup.** Generate an app password at https://storage.rcs-rds.ro/app/admin/preferences/password, then on **pve1**:

```bash
apt install -y rclone rsync
rclone config
# n → name: digi → storage: koofr → provider: digistorage
#   user: <the account e-mail> → password: <the app password>
rclone config
# n → name: digi-crypt → storage: crypt → remote: digi:proxmox-backups
#   filename_encryption: standard → directory_name_encryption: true
#   password: generate → password2 (salt): generate
rclone lsf digi-crypt:                   # no error; empty on a new account
```

⚠️ **Store the app password and both crypt passwords in the password manager before you upload anything** ([21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives)). Without the crypt passwords every copy on Digi is unreadable, which turns the only offsite tier into an expensive illusion — and they cannot come from a backup, because the backups are what they unlock.

Give pve2 the same configuration — the active node can be either:

```bash
# on pve1
scp -o HostKeyAlias=pve2 -o UserKnownHostsFile=/etc/pve/nodes/pve2/ssh_known_hosts -o GlobalKnownHostsFile=none \
    /root/.config/rclone/rclone.conf root@192.168.0.12:/root/rclone.conf
# on pve2
apt install -y rclone rsync
install -D -m 600 /root/rclone.conf /root/.config/rclone/rclone.conf && rm /root/rclone.conf
rclone lsf digi-crypt:
```

`rclone.conf` holds all three secrets, obscured rather than encrypted, and it is deliberately in no archive — rebuild it from the password manager.

**Layout and retention on Digi** (`digi-crypt:` root):

| Path | Contents | Pruned by | Keeps |
|---|---|---|---|
| `vzdump/` | `vzdump-qemu-<vmid>-<timestamp>.vma.zst` (+ `.log`, `.notes`) | `offsite-sync` on the active node | newest 2 per VM |
| `postgres/wal/` | `<walfile>.zst` | `pg-offsite` | from the start of the oldest kept base |
| `postgres/base/<stamp>/` | `base.tar.zst`, `pg_wal.tar.zst`, `backup_manifest` | `pg-offsite` | newest 4 |
| `postgres/logical/` | `globals_<stamp>.sql.gz`, `<db>_<stamp>.dump` | `pg-offsite` | 30 days |
| `config/<host>/` | `pve-config-<host>-<stamp>.tar.gz` | `offsite-sync` on that host | 30 days |
| `inventory/<date>/` | the Ansible inventory | the operator, by hand | as many as you keep |

Size the plan with `rclone size digi-crypt:` after the first full cycle; the images dominate, and they grow with what the VMs hold.

## 17.4 Postgres — continuous WAL and a weekly base

Inside 1022 the Ansible `postgres` role owns everything ([the ownership boundary](../operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere)); the hosts only pull. In `group_vars/all/main.yml`:

```yaml
postgres_wal_archive_enabled: true
postgres_archive_timeout: 60          # seconds a segment holding writes may stay unfinished
postgres_wal_spool_max_mb: 20480      # archive_command refuses beyond this
postgres_basebackup_weekday: "0"      # Sunday
postgres_basebackup_hour:   "0"       # 00:45 UTC = 03:45 on the hosts in summer
postgres_basebackup_minute: "45"
postgres_backup_hour:   "0"           # the nightly logical dump: 00:15 UTC = 03:15
postgres_backup_minute: "15"
```

Then, from control-ubuntu, in a quiet moment — switching `archive_mode` on restarts Postgres:

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible-playbook playbooks/bootstrap.yml --limit postgres --diff
```

What the role puts in place:

| | |
|---|---|
| `conf.d/20-archive.conf` | `archive_mode = on`, `archive_timeout = 60`, `archive_command` → `pg-wal-archive.sh` |
| `/opt/postgres/scripts/pg-wal-archive.sh` | compresses each completed WAL file into `/opt/postgres/wal-spool/<walfile>.zst` (written aside, synced, renamed) before telling Postgres it is safe |
| `/opt/postgres/scripts/pg-basebackup.sh` + weekly cron | `pg_basebackup` in tar format with the WAL it needs inside, zstd-compressed, checked with `pg_verifybackup` before the directory loses its `.partial` suffix; the VM keeps only the newest |
| `/opt/postgres/scripts/pg-backup.sh` + nightly cron | one `pg_dump -Fc` per database plus `globals_<stamp>.sql.gz` in `/opt/postgres/backups`, kept 7 days; a run is complete when `cron.log` says `Backup complete - globals_<stamp>.sql.gz + <N> database(s)` |
| `pg_hba.conf` | `local replication postgres peer`, for the base backup over the local socket |

On the hosts, [`pg-offsite`](../scripts/README.md) runs every minute from [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes)'s cron file and acts only on the node running 1022. Each run pulls the spooled WAL files into `/var/lib/vz/postgres/wal/incoming`, uploads them, moves them into place, and only then deletes them from the VM's spool — a file that did not reach Digi stays in the spool and is retried by the next run, from whichever node is active by then. Every 15 minutes it also pulls completed base backups (never a `.partial`) and the files of completed dump runs (never a run without its completion line), uploads them the same way, and applies the retention of 17.1 — locally and on Digi — whenever a new base has landed and once a day. WAL is only ever pruned against a base: a file is removed when it precedes the first WAL file the oldest kept base needs.

Take the first base now rather than waiting for Sunday, and push everything out:

```bash
ssh devops@192.168.0.22 'sudo -u postgres /opt/postgres/scripts/pg-basebackup.sh'
pg-offsite --now                       # on the node running 1022
```

**Prove it.**

```bash
ssh devops@192.168.0.22 "sudo -u postgres psql -Atc 'select last_archived_wal, last_archived_time, failed_count from pg_stat_archiver'"
ssh devops@192.168.0.22 'sudo ls /opt/postgres/wal-spool | wc -l'    # near 0: the pull drains it every minute
tail -5 /var/log/pg-offsite.log                                       # on the node running 1022
rclone lsf digi-crypt:postgres/base; rclone lsf digi-crypt:postgres/wal | tail -3
backup-verify                                                         # pg-archive, pg-wal-offsite, pg-base, pg-dump lines
```

**When it breaks.**

- **The archiver fails** (spool full, disk trouble, a broken script): Postgres keeps the WAL in `pg_wal` and retries — nothing is lost, but `pg_wal` grows on the `db` pool until the cause is fixed. `backup-verify` fails `pg-archive` with the failing file; the Postgres log on 1022 has the command's error.
- **The spool is not draining** (node cannot reach 1022, rclone or Digi failing): files wait in `/opt/postgres/wal-spool` up to `postgres_wal_spool_max_mb`, after which the archiver starts failing as above. `backup-verify` fails `pg-archive` once the oldest file is 15 minutes old; `/var/log/pg-offsite.log` on the node running 1022 names the step.
- **After an HA failover** 1022 restarts from a replica up to a minute old and writes new WAL under names it had already archived. The archive script keeps the running server's version and sets the older one aside as `<walfile>.zst.diverged-<epoch>` in the spool; the pull replaces the copies on the node and on Digi. The set-aside files are the lost minute: `backup-verify` warns about them — look at what they hold if that minute matters, then delete them.

## 17.5 VM images — quarterly and on demand

Every VM rebuilds from git and Ansible, and the database has its own tier, so images are not the first line: they are a faster way back, and the only copy of whatever the playbooks do not own. They are taken quarterly and before anything risky.

**The job** — **Datacenter → Backup → Add**:

| Field | Value |
|---|---|
| Schedule | `*-01,04,07,10-01 04:15` — the first of January, April, July and October |
| Selection | 1020, 1021, 1022, 1023 (the template 9000 is rebuilt from Stage 9, not backed up) |
| Storage | `local` |
| Mode | **Snapshot** — the guest keeps running; with the guest agent the filesystem is frozen for the instant of the snapshot |
| Compression | ZSTD |
| Retention | Keep Last 1 |

or, from either node:

```bash
pvesh create /cluster/backup --id quarterly-vms --schedule '*-01,04,07,10-01 04:15' \
  --vmid 1020,1021,1022,1023 --storage local --mode snapshot --compress zstd \
  --prune-backups keep-last=1 --enabled 1
cat /etc/pve/jobs.cfg
```

vzdump writes each image on the node running that guest; [`offsite-sync`](../scripts/README.md) uploads it at 05:00 and the active node keeps the newest two per VM on Digi.

**On demand** — before a configuration change a playbook does not capture, a major upgrade or a schema change: select the VM → **Backup** → **Backup now** → storage `local`, mode Snapshot, ZSTD. The same from a shell:

```bash
vzdump 1022 --storage local --mode snapshot --compress zstd
offsite-sync                            # upload now instead of at 05:00
```

With Keep Last 1, an on-demand image replaces that VM's previous image on the node; Digi still holds the one before.

## 17.6 Host configuration and the Ansible inventory

The hosts are managed by hand, so their configuration exists nowhere but on themselves. [`pve-config-backup`](../scripts/README.md) archives it on both nodes at 02:40 into `/var/backups/pve-config` — `/etc/pve`, network, fstab, `/etc/hosts`, NUT, cron and logrotate files, systemd units, `/usr/local/{bin,sbin}`, and manifests (`pveversion`, packages, addresses, `zpool status`, `lvs`) — and `offsite-sync` uploads it to `digi-crypt:config/<host>/` at 05:00.

> **The archive is key material.** `/etc/pve` carries the cluster's ticket-signing key, its CA key and API token secrets. It travels only through the crypt remote; never copy one anywhere unencrypted.

To rebuild a node from it: `rclone copy digi-crypt:config/pve1/<archive> /root/` on any machine with the rclone configuration, then take the files you need out of it — it is a reference to restore from, not a tarball to unpack over a fresh install.

**The Ansible inventory** (`d:/git/ansible/inventory` on the workstation, mirrored in `~/app-inventory` on control-ubuntu) is what turns "rebuild the VM from git" into a command, and `vault.yml` in it is plaintext. It lives outside every repository, so it is copied by hand after every change, from the workstation, with rclone and the same configuration as the nodes:

```bash
rclone copy d:/git/ansible/inventory "digi-crypt:inventory/$(date +%Y%m%d)"
rclone lsf digi-crypt:inventory
```

## 17.7 Restore — pick your scenario

Images in the UI: select the storage `local` of the node in the tree → **Backups**. Every image on that node is listed with its VM ID, date and size; images of guests that ran on the other node are on the other node, and older images are on Digi (E).

### A. Restore into a NEW VM ID (safest — start here)

Use this to inspect a backup, recover files, or prove a restore works, without touching the running VM.

```bash
qmrestore /var/lib/vz/dump/vzdump-qemu-1021-2026_10_01-04_15_00.vma.zst 1121 --storage apps --unique
```

- `1121` — a free VM ID, not the original
- `--unique` — regenerates the MAC so the clone does not collide with the running original
- Before starting it, give it a spare IP in **Cloud-Init** (spare ID 11NN takes .1NN), or it fights the original for its address

Copy out what you need, then `qm stop 1121 && qm destroy 1121`. [`restore-drill`](../scripts/README.md) is this scenario as one command.

### B. Restore OVER an existing VM (in place)

When the VM itself is broken and you want it back as it was. This **destroys the current disk** — take *Backup now* first if anything on it is salvageable.

```bash
ha-manager remove vm:1021           # 1. out of HA, so it is not restarted mid-restore
qm stop 1021                        # 2.
qmrestore /var/lib/vz/dump/vzdump-qemu-1021-2026_10_01-04_15_00.vma.zst 1021 --storage apps --force
qm start 1021                       # 3.
```

Or from the UI: storage → Backups → the image → **Restore** → tick *Force*. Then the [post-restore checklist](#178-post-restore-checklist).

For 1022 an image restores the database as it was at that instant; to bring it forward to a later second, restore it and then follow **G** against it, or skip the image entirely and use **G** onto a scratch VM.

### C. Restore onto the other node

The image is on the node that ran the guest when it was taken. From the other node, either take it from Digi (**E**), or copy it across the LAN with ssh pointed at the cluster's own host keys:

```bash
# on pve2
scp -o HostKeyAlias=pve1 -o UserKnownHostsFile=/etc/pve/nodes/pve1/ssh_known_hosts -o GlobalKnownHostsFile=none \
    root@192.168.0.11:/var/lib/vz/dump/vzdump-qemu-1022-2026_10_01-04_15_00.vma.zst /var/lib/vz/dump/
qmrestore /var/lib/vz/dump/vzdump-qemu-1022-2026_10_01-04_15_00.vma.zst 1022 --storage db --force
```

Plain `scp root@192.168.0.11` from pve2 has no pinned host key and fails under `BatchMode` or prompts at a console; the three `-o` flags use the per-node store pmxcfs distributes, which is what PVE's own migration uses. The durable repair for interactive ssh is in [troubleshooting](../troubleshooting.md). `10.10.10.1` is the on-demand 10G cable and is normally unplugged — never aim a restore at it.

### D. Recovering individual files

vzdump images restore whole: restore to a spare ID (**A**) with the network detached, and take the files out through the console or by attaching its disk to another VM.

For the database, restore from a logical dump instead — no VM involved. The dumps are in `/var/lib/vz/postgres/logical/` on the node running 1022 (nine days) and in `digi-crypt:postgres/logical/` (thirty):

```bash
# on the node running 1022: one table of one database, into a scratch database on 1022
scp /var/lib/vz/postgres/logical/waa_ro_app_20261001-001501.dump devops@192.168.0.22:/tmp/
ssh devops@192.168.0.22
sudo -u postgres createdb restore_scratch
sudo -u postgres pg_restore -d restore_scratch -t <table> /tmp/waa_ro_app_20261001-001501.dump
```

Compare, copy back what you need (`INSERT … SELECT` or `pg_dump -t` of the scratch table), then `dropdb restore_scratch` and delete the file.

### E. Restore from offsite

From any node with the rclone configuration (17.3):

```bash
rclone lsf digi-crypt:vzdump | grep qemu-1022
rclone copy digi-crypt:vzdump/vzdump-qemu-1022-2026_07_01-04_15_00.vma.zst /var/lib/vz/dump/
qmrestore /var/lib/vz/dump/vzdump-qemu-1022-2026_07_01-04_15_00.vma.zst 1122 --storage apps --unique
```

Decryption is transparent as long as `digi-crypt` has the right passwords — the quarterly drill is where you find out.

### F. Full disaster recovery (both nodes gone)

The order matters:

1. Install Proxmox on the replacement hardware (Stages 1–2), and give `local-lvm`'s space to `local` (17.2).
2. Recreate the ZFS pools with the **same names**, `apps` and `db` (Stage 6).
3. Install rclone and rebuild `digi-crypt` from the password manager (17.3) — **the step that needs the crypt passwords you stored outside the lab**.
4. Bring the cluster back (Stages 7–8) using the host-configuration archives on Digi (17.6) as the reference.
5. Restore the VMs: from their newest images (**E**), or rebuilt from git with the inventory copy on Digi (17.6) and Stages 10–11.
6. Bring the database to its last archived second with **G**, onto the restored or rebuilt 1022.
7. Replication and HA (Stages 12, 15), then point Cloudflare Tunnel at the app VM.

The frontend lives on Cloudflare and was never affected — and neither were the R2 buckets, which are only in Cloudflare.

### G. Database point-in-time recovery (base + WAL)

Stands the database up as of any second between the start of a kept base and the newest archived WAL: "undo the migration that ran at 14:32", or bring a restored 1022 forward to its last archived moment. Do it on a scratch VM first and inspect before touching the real one.

**1. A scratch Postgres 18 with the same layout.** Restore 1022's newest image to a spare ID (**A** — `1122`, IP `.122`), start it, and inside it:

```bash
systemctl stop postgresql
rm -f /etc/postgresql/18/main/conf.d/20-archive.conf      # the scratch must not archive into anything
mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.image
install -d -o postgres -g postgres -m 700 /var/lib/postgresql/18/main /var/lib/postgresql/wal-replay
```

**2. The base and the WAL.** Pick the newest base that **starts before** the target time. On the node running 1022 both are in `/var/lib/vz/postgres/`; otherwise take them from Digi into a directory on a node first (`rclone copy digi-crypt:postgres/base/<stamp> ./base`, `rclone copy digi-crypt:postgres/wal ./wal`). Then push them to the scratch VM:

```bash
# on the node holding them
rsync -a --rsync-path='sudo rsync' /var/lib/vz/postgres/base/<stamp>/ devops@192.168.0.122:/var/lib/postgresql/base/
rsync -a --rsync-path='sudo rsync' /var/lib/vz/postgres/wal/ devops@192.168.0.122:/var/lib/postgresql/wal-replay/
```

**3. Unpack and arm recovery**, inside the scratch VM:

```bash
cd /var/lib/postgresql/18/main
tar --zstd -xf /var/lib/postgresql/base/base.tar.zst
tar --zstd -xf /var/lib/postgresql/base/pg_wal.tar.zst -C pg_wal
chown -R postgres:postgres /var/lib/postgresql
cat >> /etc/postgresql/18/main/conf.d/90-recovery.conf << 'EOF'
restore_command = 'zstd -dcq /var/lib/postgresql/wal-replay/%f.zst > %p'
recovery_target_time = '2026-10-14 14:31:50+03'
recovery_target_action = 'pause'
EOF
touch recovery.signal
systemctl start postgresql
tail -f /var/log/postgresql/postgresql-18-main.log    # "recovery stopping before commit …", then paused
```

Leave out `recovery_target_time` to replay everything the archive holds. With `pause`, inspect the data (`psql`), and when it is the moment you wanted run `select pg_wal_replay_resume();` — or move the target and restart.

**4. Then pick the path:**

- **Take rows back**: extract what the mistake destroyed (`pg_dump -t` from 1122) and merge it into the live database. Inserts are mechanical; updated rows need a decision about which version wins. Destroy 1122.
- **Replace the database**: stop the app slots, promote the scratch copy's data (restore 1122's disk over 1022 per **B**, or re-IP 1122 as 1022), remove `90-recovery.conf`, and re-run the Ansible `postgres` role so archiving is configured again. New WAL then starts a new timeline, which the archive keeps apart by name.

## 17.8 Post-restore checklist

A restored VM comes back as a plain VM — the cluster machinery around it does not follow automatically:

```bash
# 1. Replication — the old job points at a disk that no longer exists
pvesr status
# if the job errors, delete and recreate it (a full resync follows):
pvesr delete <jobid>
# then re-add from the UI: VM → Replication → Add

# 2. HA — re-add if you removed it in B.1
#    both flags default to 1; pass them or the guest comes back movable (15.5)
ha-manager add vm:1021 --state started --failback 0 --auto-rebalance 0
ha-manager status

# 3. Guest agent reporting (confirms the VM booted properly)
qm agent 1021 ping
```

Also check inside the VM:
- The IP is what you expect (`ip a`) — a `--unique` restore changes the MAC, which matters if anything upstream keys off it
- `cloudflared` is running, if this is 1021
- For 1022: Postgres recovered cleanly (`systemctl status postgresql`, the log tail), `pg_stat_archiver` shows WAL being archived again, and the spool drains (17.4). A 1022 restored from an older image re-archives WAL names already on Digi — expect `*.diverged-*` files in its spool and treat them as in 17.4

## 17.9 Restore drills

A backup you have never restored is a hypothesis. Nothing schedules these — [`install-scripts.sh`](../scripts/README.md) leaves procedures that create and destroy VMs to a human — so they live in your calendar or nowhere. Copy every result into the [23.5](../operations/23-drill-book.md#235-the-drill-log) table: that table in git survives the failure the drill rehearses.

- **Quarterly, after the job runs:** scenario **A** on one VM with [`restore-drill`](../scripts/README.md) — restore to a spare ID, NIC down, boot, guest-agent proof, destroy; it logs the measured RTO to `/var/log/restore-drill.log` and rotates through the VMs.
- **Quarterly:** scenario **G** from Digi's copies — one base and its WAL into a scratch VM, to a chosen second, and a row count checked against what you expect. This proves the base, the WAL chain and the crypt passwords together.
- **Quarterly:** pull the newest inventory copy from `digi-crypt:inventory/` to a scratch directory and open `vault.yml`.
- **After any change** to storage layout, the Proxmox major version, the backup job, the rclone configuration or the Postgres role.

Write down how long each takes. Those numbers are your real RTO, as opposed to the one you assume you have.
