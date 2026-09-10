# Stage 17 — Backup & restore

*Part of the [Proxmox lab guide](../README.md).*

## 17.1 The tiers

Each one answers a different disaster. None substitutes for another:

| Tier | Interval | Protects against | Recovery time |
|---|---|---|---|
| **ZFS replication** (Stage 12) | 1-15 min | A node dying | ~2-3 min, automatic |
| **WAL stream → QDevice** ([Stage 13](../ha/13-wal-stream.md)) | Continuous (~seconds) | The last minute a failover would otherwise lose; also unlocks any-second PITR | Minutes ([scenario G](#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice)) — but only onto a vzdump base, which this cluster does not have |
| **Local backup** (USB) | Daily | Deletion, corruption, a bad deploy, ransomware | Minutes to an hour |
| **Offsite copy** (Digi Storage) | Daily | Fire, theft, flood, both nodes gone | Hours (download-bound) |
| **R2 media mirror** ([17.10](#1710-a-fifth-tier-for-the-r2-media-bucket)) | Daily | The one data set that lives only in Cloudflare — a deleted bucket, a retention-sweep bug, a leaked write-capable key | Minutes (copy back from the drive) |

> Replication is **not** backup. It copies a `DROP TABLE` to the other node just as faithfully as it copies good data.

### Prove the chain is on — a green checker is not the proof

The table above describes tiers that exist only once you build them, and this is the one stage whose absence was invisible. Until 2026-09-10, **both nightly checkers reported green when *no* node had the USB drive.** `backup-verify` began by testing `/mnt/usb-backup`; when it was neither a mountpoint nor a directory it `exit 0`ed with no output at all — a branch written for the node that does not hold the drive, which reads identically when *no* node holds it. `cluster-health`'s backup block ended the same way, printing `[ OK ] backup: no USB storage on this node (it lives on the peer)`. Both nodes then reported a clean run, the infra monitor recorded `pass — exit 0, no output` for both (`platform/docs/adr/0015-infrastructure-verification.md`), and every check in `backup-verify` was skipped unverified — including the WAL slot and the in-VM Postgres dump, neither of which touches the drive at all.

That was the live state of this cluster on 2026-09-10: no `/etc/pve/jobs.cfg`, no `usb-backup` in `pvesm status`, no rclone binary, no root crontab, `/mnt` empty, and `grep -c vzdump /var/log/pve/tasks/index` = 0 on both nodes. Not one hypervisor backup had ever run since the lab was built — and the checkers meant to catch that had reported clean on both nodes every day since they were installed. The only copies of the data were the pve1→pve2 replication this very blockquote says is not a backup, and the in-VM Postgres dump ([17.5](#175-a-fourth-tier-for-the-database)) — which lives inside 1022's own disk, on a single-disk vdev, so it dies with the pool it is insuring.

Both scripts now ask the question cluster-wide instead — they read `jobs.cfg` / `vzdump.cron` out of pmxcfs, so "no drive on this node" is an `[ OK ]` only while some node does have a vzdump job scheduled, and is a `[FAIL]` naming the whole cluster otherwise ([the rule these checks obey](../scripts/README.md#the-rule-these-checks-obey)). That closes the specific hole. It does not turn a green line into evidence.

> **In the repo — read every "the script now …" in this stage that way.** The copies in `/usr/local/sbin` on both nodes are still the 2026-09-04 ones, and they become the rewritten ones only when [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run after a `git pull`. Until that happens on a node, its 07:30 run is still the silent `exit 0` and the app still records `pass — exit 0, no output` for it. This caveat is stated once, here, and applies to every helper named below.

Run these on pve1 when you finish this stage, after any storage change, and before believing a green dashboard — none of them can report a tier that isn't there:

```bash
pvesm status | grep usb-backup              # the storage is defined at all
mountpoint /mnt/usb-backup                  # …and the drive is actually under it
cat /etc/pve/jobs.cfg                       # the nightly job (no such file = no job;
cat /etc/pve/vzdump.cron                    #  older PVE kept it here — header only = no job)
grep -c vzdump /var/log/pve/tasks/index*    # vzdumps in the retained task history; 0 = never ran
cat /etc/cron.d/rclone-offsite; crontab -l  # the 04:00 offsite sync — 17.6 installs it in cron.d;
                                            #  crontab -l only catches an older hand-typed one
command -v rclone                           # …and the binary both forms of it need
backup-verify                               # no --quiet: line 1 must be [ OK ] usb: drive mounted
```

Line 1 of `backup-verify` is the one that settles this stage, and `[ OK ] usb: drive mounted` is the only wording that settles it in your favour. A short run — and certainly no output at all, the pre-2026-09-10 behaviour — is not the "exits clean" the drill gate in [23.1](../operations/23-drill-book.md#231-the-gate--before-any-drill) means: it means the script stopped before it looked at a single tier.

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

**The drive is a hard prerequisite, not a placement preference.** Three of the five tiers in [17.1](#171-the-tiers) — the nightly vzdump, the offsite sync and the R2 mirror — plus the host-config archives from [`pve-config-backup`](../scripts/README.md) all land on this one drive. With no drive on *either* node, both nightly checkers reported that as green on both — [17.1](#prove-the-chain-is-on--a-green-checker-is-not-the-proof) has the story and the fix. A loud checker still does not make a copy of anything, so what follows is what to do meanwhile. `pve-config-backup` is the one exception to the drive dependency, and not a reassuring one: it keeps its archive in `/var/backups/pve-config` on the node itself, so the config archive dies with the node it describes. It now says exactly that — a `FAIL` line and exit 1, carried to the app by the `infra-report` wrapper around its cron entry — but saying so is not the same as having a second copy.

What is left without the drive is the ZFS replication to pve2, which reproduces a `DROP TABLE` exactly, and the in-VM Postgres dump ([17.5](#175-a-fourth-tier-for-the-database)), which lives inside 1022's own disk — and every pool here is a single-disk vdev, no mirror, no raidz, so one NVMe takes its pool and that dump with it. The WAL stream does not close the gap either: it is a copy of the last seconds, and [scenario G](#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) replays it onto last night's vzdump. With no vzdump there is nothing to replay onto.

If the drive is not attached yet, do these two the same day rather than waiting for hardware:

```bash
# 1. a vzdump onto `local` — that is /var/lib/vz on the 94G PVE root, so: no retention,
#    no offsite copy, and it dies with the node. It buys one thing — a copy off the
#    guest's own pool — and it proves the job itself works.
df -h /; pvesm status          # check the room first: `local` showed 78G free on pve1
vzdump 1022 --storage local --mode snapshot --compress zstd
df -h /                        # and again after
#    1022 is a 1T sparse zvol referring ~2G, so zstd lands in the low GB — but an
#    ad-hoc vzdump prunes nothing, so delete the archive by hand once the drive
#    arrives. A full `/` on a PVE node takes pmxcfs, the API and every guest config
#    down with it, which is a worse day than the one you are insuring against.
# 2. the in-VM dumps, off the cluster entirely, weekly by hand until 17.6 exists
#    (plain devops cannot read the dump dir — it is 0750 postgres:postgres)
rsync -a --rsync-path='sudo -u postgres rsync' \
      devops@192.168.0.22:/opt/postgres/backups/ <a machine that is not this cluster>/
```

Neither is a tier, and neither survives losing the node. Record in [23.5](../operations/23-drill-book.md#235-the-drill-log) the day you started doing this and the day the drive replaced it: an interim measure nobody wrote down becomes a permanent one nobody knows about.

## 17.3 The scheduled job

**Datacenter → Backup → Add:**

| Field | Value | Why |
|---|---|---|
| Node | pve1 (where the USB drive is) | |
| Storage | `usb-backup` | |
| Schedule | `03:00` daily | Quiet hours, and well clear of the 04:00 offsite sync. It does **not** catch a fresh in-VM Postgres dump: on this estate that fires at 05:15 UTC, 08:15 on the hosts' clock ([17.5](#175-a-fourth-tier-for-the-database)), so a 03:00 archive carries a dump ~19h old. Move one of the two before you rely on what is inside the image |
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

What it does each night — as the `postgres` user, at whatever `postgres_backup_hour` / `postgres_backup_minute` say in group_vars, because the schedule is policy and lives next to the other policy rather than hardcoded in the role. The role's own default is 02:15; **this estate overrides it to 05:15**, and 1022 keeps its clock on UTC while the hosts are on Europe/Bucharest, so the cron the guide's arithmetic has to use is **08:15 host-local** (07:15 in winter — the VM does not shift and the hosts do):

| | |
|---|---|
| `globals_<stamp>.sql.gz` | roles, passwords, tablespaces — the restore prerequisite people forget |
| `<db>_<stamp>.dump` | one custom-format (`-Fc`) dump per database, parallel-restore friendly and portable across major versions |
| Location | `/opt/postgres/backups` (or `{{ postgres_backup_mount }}/postgres` if you attach a dedicated backup disk) |
| Retention | `backup_retention_days`, default 7 |

Because it writes to the VM's own disk, the dumps are swept up by the nightly `vzdump` and the offsite sync automatically — no extra plumbing, once those two exist. Restoring a single table becomes `pg_restore -t` instead of a full VM restore.

> **The ordering contract between the two jobs is currently inverted, and nothing enforces it.** The intent is dump → image → offsite, so that every archive carries a dump hours old instead of a day old. With the dump at 08:15 host-local and [17.3](#173-the-scheduled-job)'s vzdump at 03:00, the image would be taken 19 hours *after* the dump it contains — the full day of drift the contract exists to remove. Nothing detects that: no vzdump job exists yet at all, and no check anywhere compares the two schedules against each other. Close it when you build 17.3, in whichever direction suits the quiet hours — move `postgres_backup_hour` back in group_vars and re-run the playbook, or schedule the vzdump after 08:15 — and if you ever move one side afterwards, move the other with it. This contract is held together by a comment in group_vars and this paragraph, and by nothing that runs.

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

Automatic sync after the nightly backup — the whole drive, not just `dump/`, so the host-config archives from [`pve-config-backup`](../scripts/README.md) and the R2 media mirror ([17.10](#1710-a-fifth-tier-for-the-r2-media-bucket)) ride along. **Write it as a file in `/etc/cron.d`, not into root's personal crontab** — `crontab -e` is the obvious move and it is the wrong one, for the reason below:

```
# /etc/cron.d/rclone-offsite — pve1 only: the source is the USB drive
PATH=/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=root
0 4 * * * root rclone sync /mnt/usb-backup digi-crypt: --transfers 2 --log-file /var/log/rclone-backup.log
```

`MAILTO` is kept because it costs nothing and becomes useful again the day [15.3](../ha/15-ha.md#153-notifications) is repaired, but do not read it as this job's failure channel: root mail is generated correctly and then rejected by the recipient's provider — `550 5.7.1 … blocked using Spamhaus` — and discarded, which is why every helper job is wrapped in `infra-report` instead. This one is not wrapped, so what actually watches it is `backup-verify` at 07:30, through the log file named on that line.

The file location is the part that matters. This is the only schedule in the guide that nothing recreates for you — the helper jobs come back from [`install-scripts.sh`](../scripts/README.md), the nightly dump from the Ansible `postgres` role ([17.5](#175-a-fourth-tier-for-the-database)), the vzdump job from `jobs.cfg` in pmxcfs. Typed into root's crontab this one exists in exactly one place on exactly one node, and `pve-config-backup` archives that place only as a *manifest*: `root-crontab.txt` inside the tarball, text for a human to read, not a file a restore replays. `/etc/cron.d` is tarred as itself. So rebuild pve1 from its own config archive and every helper job comes back scheduled while this one — the tier that answers fire, theft and flood — quietly does not, and the first thing that notices is the first disaster.

It stays out of `install-scripts.sh`'s file deliberately: that one is written identically on both nodes, and unlike [`r2-backup`](../scripts/README.md) this command carries no guard of its own for the node without the drive. A separate file keeps it node-local and still inside the directory the config archive replays.

`backup-verify` does watch this tier once it exists — a missing `rclone` binary is its own `[FAIL]`, and so is a missing or stale `/var/log/rclone-backup.log` — but only from the node where the drive is mounted. That is a check on a job that ran yesterday, not on one a rebuild forgot to schedule; only the file location covers the second case.

Verify it's actually landing:
```bash
rclone ls digi-crypt: | tail
tail -20 /var/log/rclone-backup.log
```

**Verify the passengers, not just the sync.** "The whole drive" is only ever as good as what reached the drive, and the host-config archives are the ones that quietly do not. `pve-config-backup` runs nightly on both nodes and always keeps its 14 local copies in `/var/backups/pve-config`; it puts one on the drive only if `/mnt/usb-backup` is mounted *here*, or — from pve2, which has no drive — by `scp` to the peer at `USB_PEER_IP`. That second route had two independent single points of failure, and [`pve-config-backup.sh`](../scripts/pve-config-backup.sh) in the repo now closes both. One was the address: it shipped with `USB_PEER_IP=10.10.10.1`, on the 10G link, which is unplugged by design between migrations ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)), so the route was offline whenever the cable was — which is most of the time. Nothing scheduled may depend on that cable; the value is now `192.168.0.11`. The other was SSH trust, which would not have fixed itself when the cable went back in: root on pve2 has no `known_hosts` entry for pve1 at all, so the script's own `-o BatchMode=yes` call would have died there with `Host key verification failed` ([17.7 C](#c-restore-onto-the-other-node) hits the same missing pin by hand, where with no `BatchMode` it surfaces as a fingerprint prompt rather than an error). The script no longer depends on root's trust store — it passes `-o HostKeyAlias=pve1 -o UserKnownHostsFile=/etc/pve/nodes/pve1/ssh_known_hosts`, the per-node store pmxcfs distributes to both nodes, which is what PVE's own migration and replication have always done. When neither route works it logs the failure, prints `FAIL: USB drive unreachable — <archive> exists only in /var/backups/pve-config …` and exits 1, which the nightly `infra-report` wrapper carries to the app's infra monitor — the one channel that arrives, root mail being rejected at the recipient ([15.3](../ha/15-ha.md#153-notifications)). The cost it is reporting is precise: the only archive of a hypervisor's hand-managed configuration ends up on the hypervisor it describes — the copy a dead node takes with it, at the moment you need it to rebuild that node.

Check from pve1, the node with the drive:
```bash
ls -l /mnt/usb-backup/config-backup/pve1 /mnt/usb-backup/config-backup/pve2
```
Two directories, both fresh. If pve2's is missing or stale, the installed copy there is almost certainly the one that predates both repairs — check it, and fix it by re-running [`install-scripts.sh`](../scripts/README.md) on that node rather than by editing `/usr/local/sbin/pve-config-backup` in place; edit it in place and the next install run is not the thing that overwrites your fix, it is the thing you forgot to run.
```bash
grep -E 'USB_PEER_IP=|HostKeyAlias' /usr/local/sbin/pve-config-backup  # 192.168.0.11, and the key pinned by node name
journalctl -t pve-config-backup | tail -5                              # must NOT read "USB drive unreachable"
```
A few MB of tarball never needed the 10G link, and the per-node key store is the one place both nodes are guaranteed to hold each other's key.

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

Same command, run from that node's shell, with the archive reachable from it. If the USB drive is only on pve1, copy the archive across first — over the LAN, and with ssh pointed at the cluster's own host keys:

```bash
# on pve2
scp -o HostKeyAlias=pve1 \
    -o UserKnownHostsFile=/etc/pve/nodes/pve1/ssh_known_hosts -o GlobalKnownHostsFile=none \
    root@192.168.0.11:/mnt/usb-backup/dump/vzdump-qemu-1022-2026_07_29-03_00_01.vma.zst /var/lib/vz/dump/
qmrestore /var/lib/vz/dump/vzdump-qemu-1022-2026_07_29-03_00_01.vma.zst 1022 --storage db --force
```

Two traps, and a restore is the worst moment to meet either.

**Don't reach for `10.10.10.1`.** The 10G direct link is unplugged by default on this build — it is an on-demand path you connect for a migration and remove afterwards ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)) — and it is also among the first things missing in the kind of failure that sent you here. Either way that address buys you nothing but a TCP timeout, and the cluster is designed not to care: corosync keeps membership on the LAN ring and stays quorate without it ([runbook](../troubleshooting.md#runbook--the-10g-link-is-down)). What that costs is not nothing, and it is costed out honestly in [5.2](../setup/05-network.md#what-an-unplugged-ring-1-actually-costs-you): with ring 1 out, a switch or LAN failure drops each node to 1 vote of 3 and, with fencing armed, both self-fence. A hand-typed `scp` has no fallback of any kind.

**Plain `ssh`/`scp` from pve2 to pve1 has no host key to check against**, and what that costs depends on who is typing. Root there has no `known_hosts` entry for pve1, PVE never gives it one, and `StrictHostKeyChecking` is at its default `ask` — so a human at a console meets *The authenticity of host '192.168.0.11 (192.168.0.11)' can't be established*, a prompt whose only honest answer needs a fingerprint you are in no position to verify mid-restore, and `yes` pins whatever answered ([21.7](../operations/21-credentials.md#217-the-fourth-kind-the-pins-nobody-inventories)); anything without a terminal — a script, a cron job, `BatchMode=yes` — gets a flat `Host key verification failed` instead. PVE's own migration and replication never notice — they pass exactly the three flags above on every internal call, against the per-node store pmxcfs distributes, and both directions are healthy — which is why nobody finds this until a manual copy is needed, i.e. during a restore. The flags are the improvisation that works with nothing installed and nothing changed. The durable repair belongs on pve2 long before you need it and is described once, in [troubleshooting](../troubleshooting.md): give root the peer's line out of that same cluster file, keyed under both the name and the address you will type. Note which address you are repairing — the cluster's key stores file each node under its **node name** only, so `HostKeyAlias` is not optional above, and `root@10.10.10.1` stays broken whatever you do: nothing has ever been told a host key for the 10G address.

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

> **On this build step 1 has nothing to restore, so this scenario cannot be run.** No vzdump job exists and none has ever run ([17.1](#prove-the-chain-is-on--a-green-checker-is-not-the-proof)), so the archive has no base to replay onto — and the in-VM dump does not stand in for one: a `pg_restore`d logical dump gives recovery neither an LSN to continue from nor a data directory to continue into ([13.4](../ha/13-wal-stream.md#134-what-this-buys-beyond-the-failover-minute)). The stream has been accumulating since 2026-08-16 and every segment of it is unreplayable until [17.3](#173-the-scheduled-job) produces its first archive. Build that job before quoting a seconds-level RPO to anyone, yourself included. What follows is the procedure for the day it can run.

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
# Take the newest `wal-archive.diverged-<timestamp>`. "No diverged directory" means the failover
# clobbered nothing ONLY where wal-archive-guard is installed, since the guard is what creates one —
# and on this build it is not (verified 2026-09-10: no /usr/local/sbin/wal-archive-guard, no
# ExecStartPre in the unit; 13.3). Without it that same emptiness is what a clobbered archive looks
# like, and /var/lib/wal-archive is the overwritten copy rather than the saved one (13.5). So check
# the guard before you trust the listing:
#   ssh root@192.168.0.10 'ls -l /usr/local/sbin/wal-archive-guard; systemctl cat pg-receivewal | grep ExecStartPre'
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

**A missing drill log is the cheapest audit in this guide.** `restore-drill` appends one line — `PASS` or `FAIL` — for every drill that gets as far as `qmrestore`, while its three preconditions (drive not mounted, no archive for that VM, a leftover `19xx` clone from last time) exit loudly and write nothing. So `ls -l /var/log/restore-drill.log` on pve1 answers in a second what a screen of green checker output will not: no file means no drill has ever completed, and nothing has ever proved that an archive of this cluster restores — or, if the drive was never there to refuse from, that an archive was ever written at all. On this build (2026-09-10) the file is absent and the [23.5](../operations/23-drill-book.md#235-the-drill-log) table empty, on a cluster whose daily checks had reported nothing but green. Nothing schedules this drill and nothing reports its absence — [`install-scripts.sh`](../scripts/README.md) leaves it out on purpose, because a procedure that creates and destroys VMs deserves a human — so the monthly reminder lives in your calendar or nowhere. Copy each result into the 23.5 table as you go: the log on pve1 dies with pve1's OS disk, and that table in git is the copy that survives the failure the drill is rehearsing for.

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
   **Object Read only**, scoped to **all three** buckets: `waa-storage` and `educa-storage` (one
   per product, the applications' media) and `app-fiscal` (the company's filed invoices and
   accounting packages, written by FiscalServer alone — it keeps the estate name because the
   ledger belongs to the legal entity, not to a product). They were one bucket, `statics-waa`,
   until the split — platform `docs/adr/0034-platform-rename.md` D3b and D3c. A token that covers
   only some of them fails the remaining passes with `NoSuchBucket`.

   Read-only is the point: the backup host must never hold a key that can delete production media,
   so a compromise of pve1 cannot become a compromise of any bucket. This is also the **only**
   credential in the estate that legitimately spans them — every write token reaches exactly one
   bucket (`waa_r2_*` → `waa-storage`, `educa_r2_*` → `educa-storage`, `fiscal_r2_*` →
   `app-fiscal`) and none of them may be widened.
2. Configure the remote (the S3 endpoint is on the same dashboard page):
   ```bash
   rclone config
   # n (new) → name: r2 → storage: s3 → provider: Cloudflare
   # access_key_id / secret_access_key: from the token you just created
   # endpoint: https://<account-id>.r2.cloudflarestorage.com
   ```
3. `rclone lsd r2:` — it must list **every** bucket named in `BUCKETS`; then
   `rclone ls r2:waa-storage | head`. If
   that lists objects, the tier works; the cron entry from
   [`install-scripts.sh`](../scripts/README.md) (03:30) does the rest, for every bucket named in
   `BUCKETS` in [`r2-backup.sh`](../scripts/r2-backup.sh).

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
lost object is `rclone copy /mnt/usb-backup/r2/waa-storage/<path> r2rw:waa-storage/<dir>`; a
prefix works the same way. The app addresses objects by stable paths (`{root}/events/{uid}/…`),
so copied-back objects are immediately served — no database surgery involved. Restoring into
`app-fiscal` is the same command with `--checksum` and a token scoped to that bucket alone: a
filed record restored as the wrong bytes is worse than one still missing, because nothing
downstream would notice.

`backup-verify` checks this tier the way it checks the offsite one — log fresh, no `ERROR` lines
— but only on the node that has the drive mounted, and its silences are not proof. Every
drive-dependent check sits behind one gate, so on a node without the drive it never reaches the
`r2-mirror:` line at all; on the node whose peer holds the drive that is correct, because the
peer's own run does the checking, but it means *this* node's clean output says nothing whatsoever
about R2. With the drive mounted but no `r2/` directory it prints `[ OK ] r2-mirror: not set up on
this drive — fine if that's intentional` — a statement about intent, not about protection, and it
reads green for a tier that does not exist. `r2-backup` has the same shape: no drive → `exit 0`,
*before* the guard that would tell you the read-only `r2:` remote was never configured, so a node
where this tier was never built is indistinguishable from one where it works. That gap costs more
here than anywhere else in this stage: every other tier's data exists somewhere else too, and this
one's does not. On 2026-09-10 neither node had the drive, neither had `rclone` installed at all,
and `journalctl -t r2-backup` was empty on both — and nothing anywhere said a word about R2. So
prove this tier with a listing, never with a green line:

```bash
ls /mnt/usb-backup/r2/*/ ; tail -3 /var/log/rclone-r2.log ; journalctl -t r2-backup --since -2d
```

Separated by `;` rather than `&&` on purpose — the run where the first command fails is exactly
the one whose journal you need to read. The quarterly drill ([17.9](#179-restore-drills)) opens
one mirrored file — an image that renders proves the whole chain, R2 → USB → eye.

Day-to-day operation — the routine proofs, the incident table (failing sync, mass delete,
deleted bucket, leaked token, faster-than-the-window erasure) and the write-back recipe — lives
in [Stage 22](../operations/22-r2-mirror.md).
