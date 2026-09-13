# Stage 16 — Hardware maintenance procedure (zero downtime)

*Part of the [Proxmox lab guide](../README.md).*

## 16.1 Planned maintenance, same day

1. Put the node into **HA maintenance mode**. This migrates its HA guests away for you and — the part a manual migrate cannot give you — takes the node out of the recovery pool, so if the *other* node fails while you are elbow-deep in this one, HA will not pick the half-disassembled machine as its target:

   ```bash
   ha-manager crm-command node-maintenance enable pve2
   ha-manager status                 # the pair now runs on the other node
   ```

2. Migrate the non-HA guests by hand — 1020 and 1023 are not the HA manager's business ([15.1](../ha/15-ha.md#151-which-vms-get-ha)), so maintenance mode does not touch them. Bulk Migrate does both in one go; leaving 1023 down for a short window is also a legitimate choice.
3. `pvecm status` — quorum OK (the QDevice holds the third vote) — **and `pvesr status`: every job `FailCount` 0, with a recent successful run.** Both are two seconds and neither changes anything, so run them *before* step 1 if the day allows; they are numbered here because this is also the last gate before the shutdown. Quorum tells you the cluster survives the shutdown; only this tells you the data does. Replication is the second copy of every running guest ([Stage 12](../ha/12-replication.md)), and the tier that is supposed to sit underneath it — the daily vzdump of [17.3](../backup/17-backup-restore.md#173-the-scheduled-job) — has never run on this build (the evidence is at the end of [16.2](#162-returning-a-node-after-a-long-outage-days-to-weeks)), so replication is not a second copy on top of a backup: it is the only copy there is. Two things this catches that quorum cannot:

   - **The guests you chose not to migrate.** Step 2 lets you leave 1023 down rather than move it, which leaves its disks on the machine you are about to open; the only other copy is whatever its hourly job last put on the peer. If that job has been failing since yesterday, you are about to put a screwdriver inside the enclosure holding the only current copy.
   - **A job that has been failing quietly** turns step 1's automatic migration into a full disk transfer rather than a delta. Find that out before maintenance mode starts it for you, not while the HA pair is half-moved.

   Two readings not to misinterpret: the jobs *will* start failing once the node is down — it is the replication target, so `cluster-health` goes red for the length of the window, and that is the shutdown, not a defect; and a job that has just reversed direction after step 1 can legitimately show `SYNCING` with `FailCount` 0, which is a run in flight, not a failure. Wait it out.

4. Shut down the empty node.
5. Work on the hardware; the cluster runs on one node.
6. Power the node back on — it rejoins automatically, replication resumes.
7. Leave maintenance mode — but only once the node is fit to *receive* workload again:

   ```bash
   ha-manager crm-command node-maintenance disable pve2
   ```

⚠️ **Disabling maintenance mode moves the HA guests back on its own.** The stack recorded where each one was when you enabled it, and returns them there. That is exactly what you want after an afternoon of work, and exactly what you don't want after a long one: [16.2](#162-returning-a-node-after-a-long-outage-days-to-weeks) exists because a returning node needs its packages aligned and its replication caught up *before* it takes workload, and this command asks neither question — it just moves them. For anything beyond same-day work, don't use maintenance mode as the return path: leave the node out of it, follow 16.2, migrate by hand.

> That auto-return is the whole difference between the two routes. For a short window you can skip maintenance mode entirely — `shutdown_policy=migrate` ([15.2](../ha/15-ha.md#152-shutdown-policy--important)) already live-migrates the HA guests when you shut the node down, and brings nothing back afterwards ([15.5](../ha/15-ha.md#155-rules-and-the-two-flags-that-default-to-on): no rules, no failback). Maintenance mode earns its place when the work doesn't start with a shutdown: a firmware sweep, a long diagnostic, anything where the node stays up and untrustworthy for a while and you want HA to stop considering it.

## 16.2 Returning a node after a long outage (days to weeks)

Step 6 above assumes the node was gone for an hour. If it was gone for two weeks — a dead PSU waiting on a part, a laptop you took on a trip, an RMA — the cluster mechanics are identical but three things have drifted underneath you. Nothing here is dangerous *if* you take it in order; the failure mode is doing it in the wrong order and discovering the problem mid-migration.

**What has *not* changed, and needs no action:**

corosync has no membership expiry. The node authenticates with the cluster key it already has, pmxcfs syncs `/etc/pve` down from the quorate side, and votes go from 2 back to 3. Two hours or two months makes no difference. There is also no split-brain risk from the absence itself: while it was without quorum its `/etc/pve` was mounted **read-only**, so it could not have produced conflicting cluster state. This is a different situation from the removed node in [19.2 step 4](19-node-replacement.md#4-power-off-pve2-permanently-then-remove-it) — that one is no longer a member and must never be powered back on; this one is still a legitimate member.

**What has changed:**

| Drifted | What actually happened | Why it matters |
|---|---|---|
| **Replication baseline** | The job reversed at failover, so pve1 is now the source. It retried and failed for two weeks with backoff (up to ~30 min between attempts), keeping its last successful replication snapshot the whole time | The return sync is one large incremental, not a delta. It also means the source pool has been growing (see below) |
| **Package versions** | pve1 took two weeks of updates; the returning node is on whatever shipped before it died | Live migration from a newer QEMU onto an older one can fail on machine type. **This is the one that bites** |
| **The clock** | RTC drift on a machine that sat powered off | Skew shows up as confusing log timestamps and, at extremes, pmxcfs and certificate complaints |

> **Watch the surviving node's pools *during* a long outage, not after.** The retained replication snapshot (`__replicate_1022-0_<timestamp>__`) pins every block that Postgres has since overwritten or deleted. At this scale that's noise, but the mechanism is real and unbounded: a write-heavy workload can fill the pool on the node that's still up, turning a redundancy problem into an outage. `zfs list -t snapshot -o name,used` and `zpool list` weekly while a node is away.

### The return procedure

Order matters: **rejoin → align versions → replicate → only then migrate.**

> The whole sequence below is wrapped in [`node-return`](../scripts/README.md) (installed in Stage 2.4), which checks each gate and refuses to continue until it passes — run that, and keep reading so you know what it's gating. `node-return --check` reports the gates without changing anything.

⚠️ **The copy on the nodes is not that script yet.** `/usr/local/sbin/node-return` on both machines is still the 2026-09-04 build (verified 2026-09-10); it becomes the one described here only when [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run after a `git pull`, and the same is true of every helper this stage names. Until that has been done on the returning node the wrapper is worse than useless in precisely this situation: its Gate 1 greps the whole of `corosync-cfgtool -s` for `faulty|disconnected` and exits 2 on link 1's *resting* state — sending you off to fix a cable [5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected) says not to fix — and it reaches the peer with a plain `ssh root@<ring0_addr>`, which from pve2 dies on `Host key verification failed` before Gate 1 runs at all. Re-running 2.4 is a `git pull` and one script, moves no workload, and is the first thing to do on a node that has just come back; the alternative is working the steps below by hand.

> Every gate the rewritten wrapper runs reaches the peer the way PVE itself does — `HostKeyAlias=<node>` against `/etc/pve/nodes/<node>/ssh_known_hosts` — so it works from either direction. Your own hands do not: pve2 holds no `known_hosts` entry for pve1 and no `/etc/ssh/ssh_known_hosts`, so a plain `ssh root@192.168.0.11` from there stops to ask you to accept a fingerprint you have no way to check at that moment — and from anything without a terminal, a script or a cron job, the same call is a flat `Host key verification failed`. It matters at step 2, the moment you go to read `pveversion -v` on the peer yourself. That is a pin, not a cluster fault, and [21.7](21-credentials.md#217-the-fourth-kind-the-pins-nobody-inventories) has the repair.

```bash
# 1. Power it on. On the returning node:
pvecm status                      # Quorate: Yes, Total votes: 3
corosync-cfgtool -s               # LINK 0 = 192.168.0.x, must be connected; LINK 1 = the 10.10.10 cable (5.2)
timedatectl                       # "System clock synchronized: yes"
zpool status                      # apps and db ONLINE, imported cleanly

# 2. Align versions BEFORE moving any workload onto it
apt update && apt dist-upgrade
reboot                            # if a new kernel landed
pveversion -v                     # compare against pve1 — they should match

# 3. Now let replication catch up
pvesr status
pvesr run --id 1022-0             # force each job rather than waiting out the backoff
                                  # this is the big transfer; watch it to OK

# 4. Confirm the space comes back on the surviving node once the old snapshot is released
zpool list

# 5. Only now move workload back — live, no downtime
qm migrate 1021 pve2 --online

# 6. The node sat idle for two weeks; this is the right moment
zpool scrub apps && zpool scrub db
```

**On link 1, and why this is the one window where the cable is worth plugging in.** `corosync-cfgtool -s` reports link 1 disconnected as its resting state — the 10G cable is on demand ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), and the rewritten `node-return` and `cluster-health` judge the links one at a time and call this one expected rather than faulty (the copies on the nodes still call it a fault, until 2.4 is re-run there — above). Step 1 is still asking a real question, because link 0 carries membership and it being down *is* the incident. But consider connecting the 10G cable for the length of the return ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)): with it out, ring 0 is the sole path to both the peer *and* the QDevice, so a switch reboot mid-procedure drops each node to 1 vote of 3, `/etc/pve` goes read-only on both, and the watchdog fences the pair ([5.2's table](../setup/05-network.md#what-an-unplugged-ring-1-actually-costs-you), [15.4](../ha/15-ha.md#154-the-watchdog--what-fencing-actually-rests-on)) — a whole-cluster outage, during the hours you are least able to absorb one. Note what the cable does *not* buy: no byte of this procedure travels over it. Replication stays pinned to `192.168.0.0/24` in `datacenter.cfg`, so step 3's big transfer runs on the 1G LAN; and step 5 moves 1021, which is an HA resource, so `qm migrate` does not migrate at all — it forks `ha-manager migrate vm:1021 pve2`, which takes a resource and a target and silently drops `--migration_network`, putting that move on the LAN too, with nothing in the task log saying so ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)). Only the non-HA guests, 1020 and 1023, can be handed the cable per invocation ([Stage 14](../ha/14-live-migration.md)). Plug it in here for the second corosync path, not for throughput.

> **That scrub detects; it cannot repair.** Every vdev on both nodes is a single bare device — one disk under `apps`, one under `db`, `copies=1` on every dataset — so ZFS can prove a block is bad but has nothing to rebuild it from; only metadata carries a second, ditto copy. `repaired 0B … 0 errors` is the only clean answer, and anything else is a decision rather than a resilver. Which decision depends on where it rotted: a damaged *replicated* volume on the returning node costs you nothing — destroy it and let the job send a full transfer (next paragraph), because the authoritative copy is still the running one on pve1 — while errors on the node that stayed up mean the live copy is the damaged one and you are into [17.7](../backup/17-backup-restore.md#177-restore--pick-your-scenario). Nothing stops you running it at step 4 instead: these pools scrub in minutes, and finding a bad disk before you migrate workload onto it is strictly better than finding it after.

**If replication refuses with `no common base to restore the job state`,** the incremental path is gone (snapshots pruned, pool recreated, job edited). Delete the job, remove the stale volumes on the returning node, recreate the job per Stage 12 — you get a full transfer, which is slower but not a problem. Nothing is lost either way; the authoritative copy is the running one.

⚠️ **Do not start the VM on the returning node "just to check that it works."** Its disks hold a two-week-old copy. The VM's config lives under `/etc/pve/nodes/pve1/`, so the cluster won't do this on its own — but a manual `qm start` on the wrong node would bring up Postgres on stale data. Wait for `pvesr status` to report OK, then migrate.

> **HA does not fail back, by design.** [15.1](../ha/15-ha.md#151-which-vms-get-ha) adds 1021 and 1022 as plain HA resources with nothing in Rules, so they stay on pve1 until you migrate them yourself. That's the behavior you want — automatic failback toward a node whose replica is two weeks stale is strictly worse than doing it by hand after step 3. But it holds *only* while the Rules panel stays empty and the two per-resource flags stay cleared: `failback` and `auto-rebalance` both default to on, so a node affinity rule, or CRS rebalancing switched on at the datacenter, each turn this paragraph false on their own ([15.5](../ha/15-ha.md#155-rules-and-the-two-flags-that-default-to-on)).

⚠️ **Do not assume the backup tiers are covering you while a node is away — in this build they are not there at all.** Verified on both nodes 2026-09-10: `/etc/pve/jobs.cfg` does not exist, `/etc/pve/vzdump.cron` carries nothing but its generated header, `/var/log/pve/tasks/index` holds zero `vzdump` entries — no hypervisor backup has ever run — and `/mnt/usb-backup` is absent on **both** machines, with no `usb-backup` entry in `/etc/pve/storage.cfg`. The drive [17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive) tells you to attach to pve1 is not attached anywhere, and every tier standing on it goes with it ([17.1](../backup/17-backup-restore.md#171-the-tiers): vzdump, the host-config archives, the offsite copy, the R2 mirror). The WAL stream to the QDevice is not a fourth tier standing in for them either: it is a stream of changes with no base to replay onto, and the base it is documented to have is that same missing vzdump ([13.4](../ha/13-wal-stream.md#134-what-this-buys-beyond-the-failover-minute)). What still runs is the in-VM Postgres dump ([17.5](../backup/17-backup-restore.md#175-a-fourth-tier-for-the-database)) — on the same pool as the database it dumps, so it answers a dropped table, not a dead node. That rewrites the arithmetic of this whole section: for the full length of the outage the surviving node holds the only *current* copy of the data — the returning node's replica is as old as the outage and the WAL stream has nothing to replay onto — on the single-device vdevs described above, so a second failure inside the window is not a degraded cluster, it is the data. That is an argument for finishing the return procedure sooner, not for delaying it: bringing the node back is what recreates the second copy, and none of it waits on a USB drive. Rebuilding 17.2 is the first thing to do once the window closes.

⚠️ **And the net that was supposed to catch a job dying quietly is gone as well.** A backup failing for two weeks announces itself by mail to root — which is bounced at the far end every single day on both nodes (`550 5.7.1 … blocked using Spamhaus`) and then dropped by postfix, mail queue empty, `/var/mail/root` not even present, so nothing is retained to read later. It takes PVE's own `vzdump`, `replication` and `fencing` notifications with it, since they leave through the same target: the proof [15.3](../ha/15-ha.md#153-notifications) asks you to run on both nodes is exactly the one that fails today. Until that target is rebuilt, the only channel that reaches you is the [`infra-report`](../scripts/README.md) POST to the app — and only once the repaired `backup-verify` and `cluster-health` are installed on both nodes: the copies running there now still take the "the peer must be covering it" branch and post a green pass for a cluster with no backups at all.

## 16.3 Firmware — detect always, flash rarely

Firmware is the layer the rest of this guide leaves implicit, and it divides along the line that actually matters: who carries the risk.

**Runtime blobs** — `pve-firmware`, `intel-microcode` — are apt packages the kernel pushes into the device at every boot. They're undone by reinstalling the old package, re-applied automatically on any rebuild, and cost nothing beyond a reboot you were taking anyway. Take them automatically; [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) sets that up on all three machines.

**Flashed firmware** — the system BIOS and everything else with a writable chip — is written once and stays written. It survives a reinstall, it is in no backup ([`pve-config-backup`](../scripts/README.md) archives the config, not the chip), and a bad flash hands you a node that doesn't POST. Take it deliberately, on a reason, one machine at a time.

| Layer | Where | Updated by |
|---|---|---|
| CPU microcode | all three | **apt** — `intel-microcode`, early-loaded at boot |
| Driver blobs | all three | **apt** — `pve-firmware` on the nodes, `firmware-*` on the QDevice |
| System BIOS + ME/CSME | all three | flashed |
| NVMe firmware | pve1 **1** (Kingston SFYR2S2T0 = `db`) + pve2 3 + QDevice 1 | flashed — `nvme-cli`, occasionally LVFS |
| SATA SSD firmware | pve1 only — Samsung MZ7KM1T9 (= the `apps` pool) + the Intel SSDSC2BA400G4 it boots from | flashed — `fwupdmgr get-devices` reports both revisions (`GXM1003Q`, `G2010140`) and flags both *Updatable*, but LVFS has no image for either today, so the vendor's own utility is the only route that exists |
| X550-T2 NVM | pve1 | flashed — Intel's NVM Update Utility; needs a power cycle, not a reboot |
| TB4 controller + 10G adapter | pve2 | flashed — the controller via LVFS, the adapter via the vendor's own tool |
| EC / battery | pve2 + QDevice | flashed, inside the BIOS capsule — [Stage 3](../setup/03-laptop-node.md)'s battery shutdown rides on it, on both laptops |

> **On pve1, two of the three drives are SATA.** The per-node disk table is in [Stage 6](../cluster/06-zfs-pools.md) and the count is in [2.3](../setup/02-post-install.md#23-hardware-check); what it means *here* is that pool `apps` sits on a SATA SSD (`/dev/sdb`, the Samsung MZ7KM1T9) — a single-device vdev with no mirror, so a firmware fault on it is a pool loss rather than a degraded pool, and `nvme list` would never have named the drive it happened to. On pve1 read disk revisions from `fwupdmgr get-devices` or `smartctl -i /dev/sdX`, never from `nvme list`.

### Detection

`fwupd` is the radar, on all three machines ([2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) installs it). It refreshes LVFS metadata on its own timer; you only read the result:

```bash
fwupdmgr get-devices          # every part it can see, with the version running now
fwupdmgr refresh --force
fwupdmgr get-updates          # what LVFS has that this box doesn't
```

> **Nothing reported is not the same as up to date.** Lenovo, HP and Dell publish much of their business hardware to LVFS — which, in this build, is all three machines — while generic mini PCs and consumer boards almost never do. `fwupdmgr get-devices` settles it per box in seconds — one that lists a *System Firmware* device with a version is covered and will keep telling you the truth on its own; one that shows only its NVMe and TPM is not, and the vendor's support page is the only feed it has.

What fwupd can't answer, or can't see at all:

```bash
dmidecode -s bios-version; dmidecode -s bios-release-date
dmidecode -s system-product-name      # the machine type the vendor's download page asks for
nvme list                             # FW Rev column, per drive
ethtool -i nic1 | grep firmware       # the X550's NVM version — pve1's NICs are udev-renamed nic0/nic1/nic2 (5.5)
boltctl list                          # the Thunderbolt controller and what's hanging off it (pve2)
grep -m1 microcode /proc/cpuinfo      # the microcode revision actually loaded
```

> **`nvme-cli` is on neither node.** Verified 2026-09-10: `command -v nvme` returns nothing on pve1 or pve2, and no such package is installed — [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) brings in `fwupd`, [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) brings in `smartmontools`, and nothing in the build ever brought in this one. So `nvme list` above, and route C's `nvme fw-download` / `nvme fw-commit` below, are commands that do not exist — which route C hands you on a node you have already evacuated, workload moved, window running. `apt install -y nvme-cli` on both while nothing is on fire. For *reading* a revision there is a substitute meanwhile: `smartctl -i /dev/nvme0n1` prints the same `Firmware Version`, and `smartctl -i /dev/sda` reaches pve1's two SATA SSDs, which `nvme list` would never have listed at all. For flashing there is none.

[`cluster-health`](../scripts/README.md) carries one line for this, but read what it actually delivers: the nightly entry runs `--quiet`, which prints problems and nothing else ([scripts](../scripts/README.md)), while the BIOS version rides on the *nothing-pending* branch — so a covered machine tells you daily when LVFS has something for it — as an *advisory* warning, which the app records without turning the node yellow, because of the policy in *When to flash* below — and never tells you which BIOS it is running. The ESP fault in route A below does not take that daily warning away as well: detection is intact on both nodes despite it — pve2's BIOS release (`0x010c0100` → `0x010d0200`) was listed by `get-updates` and warned on nightly from 2026-09-10 until route B flashed it on 2026-09-13; what refuses is the flash itself, at the moment you go to apply it. The `--quiet` contract is the right one for an alert and the wrong one for a baseline, and the baseline is the half this section needs: run `cluster-health` by hand — or the `dmidecode` line above — before a flash, so you have a version to hold the vendor's page against, and after one, so you can prove the capsule actually took rather than assuming it. An uncovered one is a calendar item: check the vendor's page **quarterly**, in the same sweep as [18.7](../ha/18-failover.md#187-health-checks-worth-running-periodically). Checking quarterly is not the same as flashing quarterly, which is the next part.

### When to flash

| Trigger | Flash? |
|---|---|
| Microcode or a driver blob lands in apt | **Always**, unattended — it rides the normal `apt full-upgrade` |
| A published vulnerability you're actually exposed to — CSME, TPM, a microcode erratum | Yes, in a scheduled window |
| A bug you are hitting — the 10G link dropping, an NVMe not enumerating, the laptop not waking on AC | Yes; in practice this is the common one |
| New or replacement hardware, before it joins ([Stage 19](19-node-replacement.md)) | Yes — the one moment it's free |
| "There's a newer version out" | **No** |

That last row is the whole policy, and it deliberately contradicts the instinct that keeps `apt full-upgrade` on a weekly rhythm. The asymmetry is the reason: this cluster is built to survive a node dying at random ([Stage 18](../ha/18-failover.md)), but a flash takes a node down at a moment *you* chose, for a benefit you couldn't name, and occasionally doesn't give it back. Update the software aggressively and the chips only when something asks you to.

### Three routes to a flash

**A — `fwupdmgr update`, in-band.** The cleanest when the machine is on LVFS: one command everywhere, versions recorded, no stick to write. Two things to check first on a Proxmox node, both about the ESP:

```bash
findmnt /boot/efi          # mounted — necessary, and on these nodes not sufficient (below)
proxmox-boot-tool status   # if this lists ESPs, they are deliberately NOT mounted
```

This build installs on ext4/LVM ([Stage 1](../setup/01-installation.md)), so the first is what you'll see: `/boot/efi` mounted, on `/dev/sda2` on pve1 and `/dev/nvme0n1p2` on pve2, both proper EFI System partitions, both the one the node actually booted from. On a ZFS-root install the second applies instead: mount the ESP yourself and run `proxmox-boot-tool refresh` afterwards.

⚠️ **Route A cannot flash either node's BIOS today, and a mounted ESP is what hides it.** Verified on both nodes 2026-09-10: `fwupdmgr get-devices` opens with `WARNING: UEFI ESP partition not detected or configured` and every capsule device under it — *System Firmware*, the dbx revocation list, the ESRT entries — reads `Update Error: Not updatable as UEFI ESP partition not detected`. fwupd 2.0 locates the ESP through UDisks and `udisks2` is installed on neither node, so it never looks at the mount `findmnt` just showed you. The repair is either `apt install -y udisks2` or one line in `/etc/fwupd/fwupd.conf`:

```ini
[fwupd]
EspLocation=/boot/efi
```

then `systemctl restart fwupd` and re-read `get-devices` until the warning is gone. `EspLocation` is the 2.0 key and exists for exactly this case (`man 5 fwupd.conf`: "typically used if UDisks was not able to automatically identify the location"); the `OverrideESPMountPoint` in `/etc/fwupd/uefi_capsule.conf` that older write-ups give belongs to fwupd 1.x, and that file does not exist on these machines. Do it before you need it, because nothing tells you it is broken until you try to flash. Detection is unaffected: with the ESP undetected the *System Firmware* device is still listed by `get-updates`, still carries its release in `get-updates --json`, and `cluster-health`'s firmware line — which counts those releases — still warns. Verified on pve2 2026-09-10: the pending `ZBook Fury G10 … V96` release (`0x010c0100` → `0x010d0200`) shows in both, next to the `Not updatable as UEFI ESP partition not detected` error on the same device. So the failure lands in the one place you least want it — after the node is evacuated and the window is running, `fwupdmgr update` refuses, and route B is your only remaining route.

Separately, with Secure Boot left on (pve1, [0.1](../setup/00-preparation.md#01-bios)), fwupd's EFI helper has to be signed — `apt install fwupd-amd64-signed` if it didn't come in with the rest.

> **Take dbx updates last.** fwupd also offers the UEFI revocation list, which is worth keeping current — but it revokes old signed bootloaders, so applying it to a host whose own bootloader is behind is a way to make a node unbootable. `apt full-upgrade` and reboot first, then dbx. With Secure Boot **off** — pve2, as found 2026-09-13 — the firmware never consults dbx, so a pending dbx release protects nothing there, and `cluster-health` names it in its firmware line instead of counting it. The day Secure Boot is turned on it counts again, and this ordering comes back with it.

**B — the vendor's own media.** The route each vendor actually tests, and the one to prefer for the *system BIOS* on a machine you can't afford to lose:

- **pve1** — Lenovo ships a bootable BIOS image; write it with Rufus in DD mode exactly like the install stick in [0.2](../setup/00-preparation.md#02-usb-stick), boot it, flash, remove it.
- **pve2** — HP's SoftPaq, applied from the UEFI firmware-update screen. It refuses to run without AC connected *and* the battery above a threshold, which on a node that lives plugged in means charging it first. **Done this way on 2026-09-13.** The SoftPaq stages its capsules on the ESP (`/boot/efi/EFI/HP/DEVFW`) and logs to `/boot/efi/EFI/HP/FWUPDLOG/`, where all seven read *attempt status is Success*: System BIOS `0x010c0100` → `0x010d0200` (`V96 Ver. 01.13.02`), CSME, the USB-C controller and the camera; Thunderbolt, ClickPad and sensor calibration were already current. fwupd took no part (`fwupdmgr get-history` is empty), so that log and this line are the only record of the flash. The walk in *After every flash* then found VMD still disabled, VT-x on, the boot entry intact, interface names unchanged and link 0 connected — and **Power On When AC Detected at `Disable`**, which [0.1](../setup/00-preparation.md#01-bios) wants enabled. Nothing archives BIOS settings, so whether the flash reset it or it was never set cannot be told.
- **QDevice** — a Dell Pro, so it's on LVFS and route A is the normal answer ([8.7](../cluster/08-qdevice.md#87-firmware-baseline)). The fallback is Dell's own BIOS executable copied to a FAT32 stick and launched from the F12 one-time-boot menu's *BIOS Flash Update* entry — no Windows needed.

**C — per component, only when that component is the problem.** `nvme fw-download` + `nvme fw-commit` for an SSD (with the node evacuated), Intel's `nvmupdate64e` for the X550 — that one needs a full **power cycle** or the new NVM doesn't take. The TB4 10G adapter usually has a Windows-only updater; treat it as a device you replace rather than one you maintain.

> **On pve1 the X550 is not only the 10G link.** `nic1` carries `10.10.10.1` and `nic2` is the bridge port under `vmbr0` ([5.5](../setup/05-network.md#55-for-reference--the-resulting-config)) — two ports of one dual-port card, one NVM image, reset together. `nvmupdate64e` runs in-band, so it drops the management address you are running it over: the SSH session or Shell tab dies mid-flash, and corosync link 0 goes with it. Link 1 is normally unplugged by design ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), so that leaves pve1 with no ring at all and inquorate — and if its HA guests are still on it, that is precisely the self-fencing case in [15.4](../ha/15-ha.md#154-the-watchdog--what-fencing-actually-rests-on): `softdog` resets the box about 60 seconds in, on top of a NIC that is being written. Evacuate pve1 and enable maintenance mode per [16.1](#161-planned-maintenance-same-day) first, drive the flash from the physical console, and power cycle from there.

**The short version:** fwupd everywhere as the radar, the vendor's own media as the tool for the system BIOS.

### The window, and the order

A flash is two to four reboots and at least one stretch where the machine looks dead, so it's [16.1](#161-planned-maintenance-same-day) — not something you slip between two commands. The order is what makes it safe:

1. **QDevice first.** With both nodes up you keep 2 of 3 votes and stay quorate, so the cluster doesn't notice. What pauses is the WAL stream ([Stage 13](../ha/13-wal-stream.md)): the slot retains WAL on 1022 while it's away and `pg-receivewal` resumes at boot. Fine for minutes, and the WAL-slot line in [`backup-verify`](../scripts/README.md) is what's meant to catch it becoming hours. It cannot today, on either node: the copies installed there are still the pre-2026-09-10 ones, whose USB-drive block `exit`s the script on any node without the drive — and neither node has one ([17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive)) — so the slot is watched nowhere; `cluster-health` never looked at it. Until the repaired script is installed and the drive is back, prove the slot by hand before you take the QDevice down and again once it has rejoined — `ssh devops@192.168.0.22 "sudo -u postgres psql -tAc \"select slot_name, active from pg_replication_slots\""` on 1022, `systemctl status pg-receivewal` on the QDevice ([13.3](../ha/13-wal-stream.md#133-verify--both-ends-then-end-to-end)). A window that runs long with nobody watching ends at the `max_slot_wal_keep_size` cap, which invalidates the slot: the stream then has to be dropped and recreated by hand ([13.5](../ha/13-wal-stream.md#135-failure-modes-stated-plainly)).
2. **pve2 next** — evacuate it (Bulk Migrate → pve1), flash, reboot, let it rejoin.
3. **Then wait.** Give the new firmware a week of real running before pve1 gets it. Firmware bugs surface as intermittent, hard-to-attribute misbehaviour — a link that drops once a day, a drive that vanishes under load — and you want a known-good node underneath while you work out which it is.
4. **pve1 last**, the same way.

⚠️ **Never both machines in one window, and never while the peer is down.** Same rule as [20.3 step 3](20-upgrades.md#step-3-preconditions-before-you-start), for the same reason: it removes the safety net at the moment you're most likely to need it.

### After every flash — five minutes that save an evening

A flash routinely resets the firmware settings to defaults, and this build depends on four of them. Walk [0.1](../setup/00-preparation.md#01-bios) again before letting the machine back into service — all of it, not just the setting you happen to remember:

| Re-check | Why it bites here |
|---|---|
| **VMD/RST still disabled** | Re-enabled by a settings reset, Linux stops seeing the NVMe drives individually — the node won't boot, or boots without `apps` and `db`. The [2.3](../setup/02-post-install.md#23-hardware-check) symptom, except months later and with a cluster attached |
| **VT-x / VT-d on** | Without them, no VM starts at all |
| **Restore on AC / Wake on AC** | Lost silently, and you find out at the *next* power cut, when the machine doesn't come back by itself — the tail of the [4.4](../setup/04-ups.md#44-the-long-outage-timeline-end-to-end) timeline, QDevice included |
| **A boot entry exists** | A flash can wipe the UEFI boot entries. Keep the Proxmox stick nearby; `efibootmgr` puts the entry back, and the ESP's fallback path boots the node in the meantime |

On pve2 the settings read back from Linux, no console needed: HP's `hp-bioscfg` driver exposes them under `/sys/class/firmware-attributes`. HP's names for the VMD and AC rows are *Configure Storage Controller for VMD* (must read `Disable`) and *Power On When AC Detected* (must read `Enable`):

```bash
cd /sys/class/firmware-attributes/hp-bioscfg/attributes
grep -H . "Configure Storage Controller for VMD/current_value" "Power On When AC Detected/current_value" "Secure Boot/current_value"
```

The same `current_value` file accepts a write while no BIOS setup password is set (none is, on pve2). Read `pending_reboot` afterwards, and re-read the value after the next boot before trusting it.

Then, before moving any workload back:

```bash
ip -br link           # interface names unchanged?
corosync-cfgtool -s   # LINK 0 connected; LINK 1, the 10.10.10 cable, is normally disconnected (5.2)
cluster-health
```

⚠️ **The one to be genuinely afraid of is interface renaming.** A BIOS update that changes ACPI slot naming renames the NICs, `/etc/network/interfaces` then configures nothing, and the node comes back with **both corosync rings down and no management address** — unreachable over the network, from a change you made on purpose. Save `ip -br link` and `/etc/network/interfaces` *before* the flash ([`pve-config-backup`](../scripts/README.md) already archives the second one nightly), and don't start one without physical console access to that machine. The way back is the one from [19.3 step 5](19-node-replacement.md#193-approach-b--transplanting-the-disks) — new names into `/etc/network/interfaces` at the console, `ifreload -a` — which is worth reading once *before* you're sitting in front of a silent node.
