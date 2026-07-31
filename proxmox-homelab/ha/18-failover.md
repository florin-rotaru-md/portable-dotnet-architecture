# Stage 18 — Failover: how it works, scenarios & FAQ

*Part of the [Proxmox homelab guide](../README.md).*

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
2. **Fencing (~60-120s).** Before restarting anything, the cluster must be *certain* pve2 is dead rather than merely network-isolated — otherwise two copies of Postgres write in parallel (split-brain, the worst possible outcome). Proxmox solves this with **self-fencing**: a node that loses quorum resets itself via hardware watchdog within ~60 seconds. The wait isn't hesitation — it's the guarantee.
3. **Recovery.** The HA manager on pve1 takes ownership of the HA VMs and boots them from the latest local ZFS replica. Postgres performs crash recovery on startup (exactly as after a power loss) and comes back on its own.

**Result: RTO ~2-3 minutes, RPO = the replication interval.** Symmetric in both directions — there is no "primary" node.

## 18.3 Scenario table

| Scenario | What happens | Downtime | Data loss | Your action |
|---|---|---|---|---|
| **Planned maintenance** (Stage 15) | You live-migrate, then shut the node down | **0** | **0** | Migrate → shutdown → work → power on |
| **Clean shutdown** with `shutdown_policy=migrate` | VMs live-migrate automatically | **0** | **0** | None |
| **Laptop battery hits 10%** | battery-check → clean shutdown → auto live-migration | **0** | **0** | None; plug power back in later |
| **Node dies suddenly** | Fencing → HA restart on the healthy node | ~2-3 min | ≤ replication interval — recoverable to **seconds** via WAL replay ([17.7 G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice)) | None; verify afterward, replay the lost window if it held writes |
| **Node stays down for weeks, then returns** | Rejoins as a normal member; replication catches up with one large incremental | 0 (you've been running on one node) | 0 | Rejoin → `apt dist-upgrade` → let replication finish → *then* migrate back ([16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks)) |
| **10G direct cable pulled** | corosync fails over to Link 1 (1G); migration and replication fall back to 1G, slower but working | 0 | 0 | Replace the cable; check `corosync-cfgtool -s` |
| **Thunderbolt adapter drops off** (pve2) | Same as above — the 10G link disappears, the 1G ring carries the cluster | 0 | 0 | Reseat the adapter; if it recurs, check `dmesg` and the interface name (see troubleshooting) |
| **Home router / 1G switch dies** | corosync survives on Link 0 (direct 10G), cluster stays quorate and VMs keep running; no client access | Service down until replaced | 0 | Replace the router; nodes never stop |
| **QDevice down, both nodes up** | Cluster runs on 2/2 votes, everything normal | 0 | 0 | Restore the QDevice — you have no margin until then |
| **QDevice down AND a node dies** | Surviving node has 1/3 votes → **no quorum, no automatic failover** | Until you intervene | ≤ replication interval | `pvecm expected 1` on the survivor (see 18.5) |
| **Internet outage** | 5G router failover | ~30s | 0 | None |
| **Power outage** | UPS ~5h; pve2's battery script and pve1's NUT ([4](../setup/04-ups.md)) each shut their node down cleanly; everything powers back on and HA restarts the VMs when mains return | 0 while power lasts | 0 | None |
| **A data disk fails** | That pool is lost on that node; VMs fail | Minutes | ≤ replication interval | Migrate/restart VMs on the other node, replace the disk, recreate the pool, re-enable replication |
| **The OS disk fails** | That node is down; HA takes over | ~2-3 min | ≤ replication interval | Reinstall Proxmox on a new OS disk and rejoin — this is a node replacement, follow [19.2](../operations/19-node-replacement.md#192-approach-a--clean-swap-step-by-step) (delnode first, then rejoin; the data pools survive and re-import) |
| **Ransomware / accidental deletion** | Replication faithfully replicates the damage | — | — | **Restore from backup** (Stage 17) — this is why replication isn't backup |
| **Fire, theft, flood** | Both nodes gone | — | — | **Offsite restore** from Digi Storage (Stage 17.2) |

## 18.4 What failover does NOT cover

Worth being explicit, so expectations match reality:

- **It is not a backup.** Replication copies corruption, deletions and encryption just as faithfully as it copies good data. The USB + offsite chain in Stage 17 is the answer to those.
- **It does not protect a single node's split second.** An unplanned failover always costs the last N minutes of writes — *automatically*. With [Stage 13](13-wal-stream.md) those writes survive on the QDevice and come back via a short manual replay ([17.7 G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice)); true zero-RPO-with-zero-action would require shared/synchronous storage — a different, considerably more expensive architecture.
- **It does not cover the frontend.** Which is fine by design here: the frontend lives on Cloudflare, so a backend failover degrades writes/edits for a couple of minutes, while the frontend itself stays up throughout.

## 18.5 Emergency: forcing quorum

If the QDevice is unreachable *and* a node is down, the survivor refuses to start VMs. On the surviving node:

```bash
pvecm expected 1
```

⚠️ Use this **only** when you are physically certain the other node is powered off. Running it while the other node is alive but unreachable is exactly how you get split-brain and a corrupted database. Never run it "just to make things work". Restore normal quorum as soon as the QDevice or the second node is back.

## 18.6 Pre-launch test plan

A failover you haven't tested is a hope, not a solution. Run all three before the app goes live, and write down the timings:

1. **Planned live migration.** `ping -t` the app VM, migrate, confirm ≤1 lost packet. Migrate back.
2. **Clean shutdown with `shutdown_policy=migrate`.** Shut down pve2 from the UI; confirm the VMs migrate on their own rather than restarting. This also validates the battery-script path.
3. **Hard kill.** Cut power to pve2 (pull the plug, UPS bypassed). Time how long until the app answers again. Then check Postgres: did crash recovery complete cleanly? How much data was lost versus the replication interval? Power pve2 back on and confirm it rejoins and replication reverses on its own.

Repeat test 3 once after any significant infrastructure change.

## 18.7 Health checks worth running periodically

All of these (plus pool capacity, pinned snapshots, version skew, NVMe wear and power state) are wrapped in one command — [`cluster-health`](../scripts/README.md), installed in Stage 2.4 and run daily by cron. The underlying commands, for when you want to look at one of them directly:

```bash
pvecm status                  # Quorate: Yes, Total votes: 3
corosync-cfgtool -s           # both LINK 0 and LINK 1 status = OK
zpool status                  # no errors, no DEGRADED
pvesr status                  # replication jobs OK, no stale entries
ha-manager status             # HA services started, on which node
qm list                       # VMs running where you expect
```

Monthly scrubs catch silent disk corruption early — and Proxmox already ships them: `zfsutils-linux` installs a cron (`/etc/cron.d/zfsutils-linux`) that scrubs every healthy pool on the second Sunday of the month. Verify it's there rather than adding a second one; `zpool status` shows the last scrub date per pool.
