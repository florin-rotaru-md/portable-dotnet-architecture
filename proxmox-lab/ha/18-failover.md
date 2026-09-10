# Stage 18 — Failover: how it works, scenarios & FAQ

*Part of the [Proxmox lab guide](../README.md).*

## 18.1 The three mechanisms

Failover in a 2-node Proxmox cluster is the collaboration of three parts:

| Mechanism | Answers | Component |
|---|---|---|
| **Replication** | Is the data there? | ZFS send/receive, per schedule |
| **HA manager** | Should I act, and on what? | `pve-ha-manager`, VMs added to HA |
| **Quorum** | Am I allowed to act? | corosync + QDevice (3 votes) |

All three must be healthy. Replication without quorum = no automatic action. Quorum without replication = the VM starts on the other node with stale or missing data.

## 18.2 Anatomy of an unplanned failover

pve2 dies suddenly (power cut, hardware fault, kernel panic):

1. **Detection (seconds).** corosync sees pve2 stop responding. pve1 + QDevice hold 2 of 3 votes → the cluster stays quorate and has the authority to act.
2. **Fencing (~60-120s).** Before restarting anything, the cluster must be *certain* pve2 is dead rather than merely network-isolated — otherwise two copies of Postgres write in parallel (split-brain, the worst possible outcome). Proxmox solves this with **self-fencing**: a node that loses quorum stops keeping its watchdog alive, and the watchdog resets it within ~60 seconds. On this hardware that watchdog is the kernel's `softdog` — [15.4](15-ha.md#154-the-watchdog--what-fencing-actually-rests-on) covers what it does and doesn't cover, and how to confirm it is armed at all. The wait isn't hesitation — it's the guarantee.
3. **Recovery.** The HA manager on pve1 takes ownership of the HA VMs and boots them from the latest local ZFS replica. Postgres performs crash recovery on startup (exactly as after a power loss) and comes back on its own.

**Result: RTO ~2-3 minutes, RPO = the replication interval.** Symmetric in both directions — there is no "primary" node.

## 18.3 Scenario table

| Scenario | What happens | Downtime | Data loss | Your action |
|---|---|---|---|---|
| **Planned maintenance** (Stage 15) | You live-migrate, then shut the node down | **0** | **0** | Migrate → shutdown → work → power on |
| **Clean shutdown** with `shutdown_policy=migrate` | VMs live-migrate automatically | **0** | **0** | None |
| **Laptop battery hits 10%** | battery-check → clean shutdown → auto live-migration | **0** | **0** | None; plug power back in later |
| **Node dies suddenly** | Fencing → HA restart on the healthy node | ~2-3 min | ≤ replication interval. [Stage 13](13-wal-stream.md) keeps those seconds on the QDevice, but holding them is not recovering them: [17.7 G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) replays WAL onto a *physical* base — its first step is a `qmrestore` of last night's 1022 archive — and no vzdump has ever run ([13.4](13-wal-stream.md#134-what-this-buys-beyond-the-failover-minute)) | None; verify afterward. The lost window becomes replayable only once [17.3](../backup/17-backup-restore.md#173-the-scheduled-job) exists to be its base; until then it is held and unreadable |
| **Node stays down for weeks, then returns** | Rejoins as a normal member; replication catches up with one large incremental | 0 (you've been running on one node) | 0 | Rejoin → `apt dist-upgrade` → let replication finish → *then* migrate back ([16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks)) |
| **10G cable out** (the normal state) **or its NIC dies** | Nothing stops. corosync loses **Link 1** — the direct ring — and carries membership on **Link 0**, the LAN. Read that numbering off the cluster rather than off a diagram: `corosync-cfgtool -s` here shows LINK 0 = `192.168.0.x` and LINK 1 = `10.10.10.x`, the opposite of what the cable's importance suggests. Migration and replication never touched the 10G subnet — `/etc/pve/datacenter.cfg` pins both to `192.168.0.0/24`, and the 10G path is an explicit per-migration override ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)) | 0 | 0 | For migration, nothing: this is the designed state ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)). Do **not** "repoint migration at the LAN" in the middle of an incident — it has been there all along, and the detour costs you the minutes you needed. Read `datacenter.cfg` before believing any instruction that says otherwise; there are **two** keys, `migration:` and `replication:`, and they can disagree. The real consequence is the switch row below: you are down to one ring |
| **Thunderbolt dock drops off** (pve2) | Only bites while the cable is in for a migration. The ACASIS dock (`enp62s0`, `atlantic` driver) does not merely lose carrier — it **vanishes from `ip link`** with its address, so an in-flight `--migration_network 10.10.10.0/24` transfer dies rather than degrading. The cluster is untouched: ring 1 returns to the disconnected state it lives in anyway | 0 | 0 | Re-run the migration without the override, on the LAN. The dock flaps — on 2026-09-08 it enumerated and vanished again 47 s later — so treat a reconnect as unproven until `ping 10.10.10.1` has held for as long as the transfer will take ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)). A link that is normally unplugged, and unreliable while it is in, is a link nothing scheduled may depend on |
| **Home router / 1G switch dies** | Depends entirely on whether the 10G cable is in. Link 0 *is* the LAN, and so is the QDevice (`192.168.0.10`), so on an ordinary day the switch is the only path to **both** the peer and the tiebreaker. **Cable out:** each node drops to 1 vote of 3, `/etc/pve` goes read-only on both, and every armed HA component stops petting `softdog` and resets its node ~60 s later ([15.4](15-ha.md#154-the-watchdog--what-fencing-actually-rests-on)) — the LRM that holds services, and the CRM master, which arms a watchdog of its own wherever the manager lock happens to sit, services or none. Plan on **both** nodes going down; that is how [5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected) and [Stage 7](../cluster/07-cluster.md) cost this decision out. Today both roles are pve1's — `ha-manager status` reads `fencing armed (CRM watchdog active)` and `lrm pve2 (idle, watchdog standby)` — so pve2 would survive read-only, which is a fact about where the lock sits this morning, not a rule to plan around. **Cable in:** the nodes still see each other over `10.10.10.0/24` and hold 2 of 3, which meets quorum — the QDevice is lost, the cluster survives, only client access is gone | Cable out: everything stops, and a fenced node reboots straight back into an inquorate cluster, so HA restarts 1021 + 1022 **nowhere** until the LAN is back or you force quorum. Cable in: service down until the switch is replaced, nodes never stop | 0 — a fence is an unclean stop, not a lossy one; Postgres crash-recovers on the way back | Replace the switch. If the nodes came back inquorate and you need the app before the network, [18.5](#185-emergency-forcing-quorum). This row is the entire cost of the on-demand-cable decision, written out — [5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected) is where that trade is argued, and it is the one row of this table that changes shape depending on a cable nobody is watching |
| **QDevice down, both nodes up** | Cluster runs on 2/2 votes, everything normal | 0 | 0 | Restore the QDevice — you have no margin until then |
| **QDevice down AND a node dies** | Surviving node has 1/3 votes → **no quorum, no automatic failover** | Until you intervene | ≤ replication interval | `pvecm expected 1` on the survivor (see 18.5) |
| **Internet outage** | 5G router failover | ~30s | 0 | None |
| **Power outage** | UPS ~5h; pve2's battery script shuts that node down cleanly, then **pve1 is cut off hard** when the UPS runs dry — NUT is disabled on this build, the UPS has no data port ([4.6](../setup/04-ups.md#46-disabled-on-this-build)). Everything powers back on when mains return — HA restarts 1021 + 1022, `onboot` restarts 1023 ([Stage 10](../vms/10-vms.md#start-at-boot--what-comes-back-after-a-node-reboot)) | 0 while power lasts, plus Postgres crash recovery on the way back | 0 — the cut is unclean, not lossy: committed transactions are fsynced | None; 1020 by hand if you need it. Confirm Postgres logged a completed crash recovery |
| **A data disk fails** | That pool is lost on that node; VMs fail | Minutes | ≤ replication interval | Migrate/restart VMs on the other node, replace the disk, recreate the pool, re-enable replication |
| **The OS disk fails** | That node is down; HA takes over | ~2-3 min | ≤ replication interval | Reinstall Proxmox on a new OS disk and rejoin — this is a node replacement, follow [19.2](../operations/19-node-replacement.md#192-approach-a--clean-swap-step-by-step) (delnode first, then rejoin; the data pools survive and re-import) |
| **Ransomware / accidental deletion** | Replication faithfully replicates the damage | — | — | **Restore from backup** (Stage 17) — this is why replication isn't backup. ⚠️ **Nothing to restore from on this build**: no vzdump has ever run ([18.4](#184-what-failover-does-not-cover)) |
| **Fire, theft, flood** | Both nodes gone | — | — | **Offsite restore** from Digi Storage ([17.6](../backup/17-backup-restore.md#176-offsite--digi-storage-via-rclone)) — with both nodes gone the order matters, so follow [17.7 F](../backup/17-backup-restore.md#f-full-disaster-recovery-both-nodes-gone), whose third step needs the rclone crypt passwords kept off the cluster ([21.3](../operations/21-credentials.md#213-the-rule-recovery-credentials-must-live-outside-the-thing-they-recover)). ⚠️ **Nothing has been shipped offsite yet**, so today this row is total loss ([18.4](#184-what-failover-does-not-cover)) |

## 18.4 What failover does NOT cover

Worth being explicit, so expectations match reality:

- **It is not a backup.** Replication copies corruption, deletions and encryption just as faithfully as it copies good data. The USB + offsite chain in Stage 17 is the answer to those — **and on this build (checked 2026-09-10) that chain does not exist yet.** No vzdump has ever run: `/etc/pve/jobs.cfg` is absent, `/etc/pve/vzdump.cron` carries its generated header and no job, and `/var/log/pve/tasks/index` holds not one vzdump entry on either node. No USB drive is attached anywhere — `/mnt/usb-backup` exists on neither node — so the USB, offsite and R2 tiers have never had a target, and `rclone` is not installed on any machine to write one. The pools are single-disk by design ([Stage 6](../cluster/06-zfs-pools.md)), which is defensible only while the peer replica is a real second copy: it means the *only* copies of a VM today are the two ZFS replicas, and this bullet is precisely about the damage those replicate. The one thing standing behind Postgres is the nightly in-VM dump ([17.5](../backup/17-backup-restore.md#175-a-fourth-tier-for-the-database)) — which lives inside the VM it protects, so it survives a bad migration but not an encrypted or deleted 1022. Until [17.3](../backup/17-backup-restore.md#173-the-scheduled-job) has run once and [`backup-verify`](../scripts/README.md) has reported on it, read Stage 17 as the to-do list it currently is, and treat the last two rows of [18.3](#183-scenario-table) as rows with no action available.
- **It does not protect a single node's split second.** An unplanned failover always costs the last N minutes of writes — *automatically*. With [Stage 13](13-wal-stream.md) those writes at least *survive*, on the QDevice — but surviving is not recovering, and the half that recovers them is missing: [17.7 G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) replays that WAL onto a physical base restored from a vzdump, and per the bullet above no vzdump has ever run, so G stops at its own first step ([13.4](13-wal-stream.md#134-what-this-buys-beyond-the-failover-minute)). Until [17.3](../backup/17-backup-restore.md#173-the-scheduled-job) exists to be that base, the honest number for this row is Stage 12's replication interval, not seconds. True zero-RPO-with-zero-action would require shared/synchronous storage — a different, considerably more expensive architecture.
- **It does not cover the frontend.** Which is fine by design here: the frontend lives on Cloudflare, so a backend failover degrades writes/edits for a couple of minutes, while the frontend itself stays up throughout.

## 18.5 Emergency: forcing quorum

If the QDevice is unreachable *and* a node is down, the survivor refuses to start VMs. On the surviving node:

```bash
pvecm expected 1
```

⚠️ Use this **only** when you are physically certain the other node is powered off. Running it while the other node is alive but unreachable is exactly how you get split-brain and a corrupted database. Never run it "just to make things work". Restore normal quorum as soon as the QDevice or the second node is back.

## 18.6 Pre-launch test plan

A failover you haven't tested is a hope, not a solution. Run all four before the app goes live, and write down the timings:

1. **Planned live migration.** `ping -t` the app VM, migrate, confirm ≤1 lost packet. Migrate back.
2. **Clean shutdown with `shutdown_policy=migrate`.** Shut down pve2 from the UI; confirm the VMs migrate on their own rather than restarting. This also validates the battery-script path. Then power pve2 back on and check what returns: whatever non-HA VM lives there comes back by itself ([start-at-boot](../vms/10-vms.md#start-at-boot--what-comes-back-after-a-node-reboot)), while the HA pair stays on pve1 — no failback, by design ([16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks)).
3. **Hard kill.** Cut power to pve2 (pull the plug, UPS bypassed). Time how long until the app answers again. Then check Postgres: did crash recovery complete cleanly? How much data was lost versus the replication interval? Power pve2 back on and confirm it rejoins and replication reverses on its own.
4. **Isolation — the only test that exercises fencing.** The hard kill proves *recovery*; it proves nothing about self-fencing, because a node with no power needs no watchdog to stop. This one does.

   **First decide which drill you are running, because the 10G cable is normally out.** `corosync-cfgtool -s` on both nodes says what you have: link 0 (`192.168.0.x`) must read `connected`, while link 1 (`10.10.10.x`) reads `disconnected` on an ordinary day *by design* ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)). On one ring there is a single cable to pull: pve2 still goes inquorate and still fences, so the watchdog half of the test holds — but you prove nothing about ring failover. Run the two-ring version at least once: plug the cable in and bring `enp62s0` up on pve2 ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)) so both links read `connected` before you start. The "home router / 1G switch dies" row in [18.3](#183-scenario-table) is survivable *only* on two rings, and this drill is that same event manufactured on purpose — it is the only place you will ever find out whether the surviving ring actually carries membership.

   Migrate 1021 and 1022 onto pve2 first — you want the isolated node to be the one holding the workload, and the node you watch from to keep its network — then disconnect **every** corosync link on pve2 at once: the LAN cable, plus the direct 10G cable if you plugged it in for the two-ring version. pve2 is now alive, running the VMs, and inquorate: exactly the shape of the situation [15.4](15-ha.md#154-the-watchdog--what-fencing-actually-rests-on) exists for.

   Expected, in order: pve2's `/etc/pve` goes read-only immediately, pve2 resets itself ~60 s later, and by the time it is back pve1 has already started the HA pair. Watch `ha-manager status` from pve1 and watch pve2 on its own physical console — you have just cut the path you would have used to SSH into it. Time both events into the [drill log](../operations/23-drill-book.md#235-the-drill-log).

   **If pve2 does not reset itself, stop and fix the watchdog before going live.** Every row in [18.3](#183-scenario-table) that resolves through fencing is resting on this. Afterwards reconnect whatever you pulled — the 10G link first if it was in, then the LAN — and confirm `corosync-cfgtool -s` shows link 0 connected on both nodes, plus link 1 if you ran the two-ring version, before moving any workload back. Then unplug the 10G cable again ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration) step 5): leaving it in after a drill is how a link nobody maintains quietly becomes load-bearing.

Repeat test 3 after any significant infrastructure change, and test 4 after anything that touches the network, the kernel or the watchdog configuration.

## 18.7 Health checks worth running periodically

All of these (plus pool capacity, pinned snapshots, version skew, SMART and wear on every physical disk, and power state) are wrapped in one command — [`cluster-health`](../scripts/README.md), installed in Stage 2.4 and run daily by cron. That is the script as it stands in the repo: both nodes still run the 2026-09-04 copies, which glob `/dev/nvme?n1` for SMART and — with no `PATH` in their cron file — read a dead ring as healthy, until [2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run there. The underlying commands, for when you want to look at one of them directly:

```bash
pvecm status                  # Quorate: Yes, Total votes: 3
corosync-cfgtool -s           # LINK 0 (the LAN) connected; LINK 1 (10G) disconnected is normal (5.2)
zpool status                  # no errors, no DEGRADED
pvesr status                  # replication jobs OK, no stale entries
ha-manager status             # HA services started, on which node
ha-manager config             # failback 0 + auto-rebalance 0 still on both (15.5)
systemctl is-active watchdog-mux  # active — fencing has something to fence with (15.4)
qm list                       # VMs running where you expect
```

One item on this list is quarterly rather than daily, and it's the only one `cluster-health` can't fully answer: **firmware**. It reports what LVFS knows, and in this build all three machines are LVFS-covered vendors ([16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely)) — but coverage is per *device*, not per box, and anything LVFS doesn't see stays silent whatever its state. So once a quarter open the vendor's page for each machine and compare against `dmidecode -s bios-version`. What to do with the answer, which is usually *nothing*, is [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely).

Monthly scrubs catch silent disk corruption early — and Proxmox already ships them: `zfsutils-linux` installs a cron (`/etc/cron.d/zfsutils-linux`) that scrubs every healthy pool on the second Sunday of the month. Verify it's there rather than adding a second one; `zpool status` shows the last scrub date per pool.
