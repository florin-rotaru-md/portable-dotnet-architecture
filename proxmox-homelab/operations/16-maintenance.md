# Stage 16 — Hardware maintenance procedure (zero downtime)

*Part of the [Proxmox homelab guide](../README.md).*

## 16.1 Planned maintenance, same day

1. Live-migrate all VMs off the target node (one by one or Bulk Migrate).
2. `pvecm status` — quorum OK (the QDevice holds the third vote).
3. Shut down the empty node.
4. Work on the hardware; the cluster runs on one node.
5. Power the node back on — it rejoins automatically, replication resumes.
6. Rebalance the VMs if you want.

## 16.2 Returning a node after a long outage (days to weeks)

Step 5 above assumes the node was gone for an hour. If it was gone for two weeks — a dead PSU waiting on a part, a laptop you took on a trip, an RMA — the cluster mechanics are identical but three things have drifted underneath you. Nothing here is dangerous *if* you take it in order; the failure mode is doing it in the wrong order and discovering the problem mid-migration.

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

```bash
# 1. Power it on. On the returning node:
pvecm status                      # Quorate: Yes, Total votes: 3
corosync-cfgtool -s               # LINK 0 and LINK 1 both OK
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

**If replication refuses with `no common base to restore the job state`,** the incremental path is gone (snapshots pruned, pool recreated, job edited). Delete the job, remove the stale volumes on the returning node, recreate the job per Stage 12 — you get a full transfer, which is slower but not a problem. Nothing is lost either way; the authoritative copy is the running one.

⚠️ **Do not start the VM on the returning node "just to check that it works."** Its disks hold a two-week-old copy. The VM's config lives under `/etc/pve/nodes/pve1/`, so the cluster won't do this on its own — but a manual `qm start` on the wrong node would bring up Postgres on stale data. Wait for `pvesr status` to report OK, then migrate.

> **HA does not fail back, by design.** [15.1](../ha/15-ha.md#151-which-vms-get-ha) adds 1021 and 1022 as plain HA resources with no groups, so they stay on pve1 until you migrate them yourself. That's the behavior you want — automatic failback toward a node whose replica is two weeks stale is strictly worse than doing it by hand after step 3. If you ever add HA groups with node priorities, set `nofailback=1` for this reason.

One thing that went right by accident and shouldn't be relied on: backups kept working through the outage because the USB drive lives on pve1 ([17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive)) and every VM was already there. Had you added the optional second drive on pve2, that job would have been failing silently for two weeks — which is what the notification target in [15.3](../ha/15-ha.md#153-notifications) is for.
