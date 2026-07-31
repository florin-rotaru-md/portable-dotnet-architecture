# Stage 16 — Replacing a node with new hardware

*Part of the [waa Proxmox homelab guide](../README.md).*

Different from Stage 13: there you power a node down and bring the *same* machine back. Here the machine is gone for good and a new one takes its place. The VMs never have to stop — but the cluster membership does change, and that part has an order you have to respect.

## 16.1 Pick the approach

| | Approach | When it fits | Downtime | Resync needed |
|---|---|---|---|---|
| **A** | **Clean swap** — evacuate, remove old node, install fresh, rejoin | The default. New machine, different disks | **0** | Yes, full |
| **B** | **Disk transplant** — move the NVMe drives into the new chassis | Same drives moving to a new box | Minutes | No |
| **C** | **Temporary third node** — join new, migrate, remove old | You have a 10G switch | **0** | Yes, full |

Approach **A** is what to use unless you have a specific reason not to. Approach **C** is smoother in theory but needs a switch, since a third node can't be reached by a point-to-point cable — skip it in the current no-switch topology.

Assume below you're replacing **pve2**. Replacing pve1 is symmetric.

## 16.2 Approach A — clean swap, step by step

### Before you touch anything

```bash
# On-demand backup of everything — you have replication and this is still worth 10 minutes
vzdump 1010 1020 1030 --storage usb-backup --mode snapshot --compress zstd

# Write down the config you'll need to recreate
cat /etc/pve/corosync.conf | grep -A4 "node {"
pvesr status
ha-manager status
ip -br a                      # on pve2, note both IPs
```

### 1. Evacuate the node (zero downtime)

```bash
# From the UI: pve2 → Bulk Actions → Bulk Migrate → target pve1
# Or per VM: right-click → Migrate
qm list                       # on pve2 — should come back empty
```

### 2. Remove HA and replication references

Replication jobs pointing at a node that's about to disappear will error forever if you leave them:

```bash
pvesr status                  # note the job IDs targeting pve2
pvesr delete 1020-0 --force   # repeat for each job
```

HA config keys off node names too. If you used HA groups restricted to specific nodes, edit them now (Datacenter → HA → Groups). Plain HA resources without groups need no change.

### 3. Remove the QDevice — do this before removing the node

This is the step that's easy to miss and produces confusing quorum errors if you skip it:

```bash
pvecm qdevice remove
pvecm status                  # now 2 nodes, 2 votes
```

### 4. Power off pve2 permanently, then remove it

⚠️ The old node must be **off before** you run `delnode`, and it must **never be powered back on while connected to this network** with its cluster config intact. A returning ghost node can corrupt cluster state. If you plan to reuse the machine for anything, wipe its OS disk first.

```bash
# On pve1:
pvecm delnode pve2
pvecm status                  # 1 node, 1 vote — expected, temporarily
```

If you intend to reuse the hostname `pve2` for the new machine, clear the leftover directory:
```bash
ls /etc/pve/nodes/            # if pve2 is still listed:
rm -rf /etc/pve/nodes/pve2
```

> Single node, single vote — the cluster is quorate but has no margin at all right now. This window is why step 1 exists: nothing critical should depend on redundancy until the new node is in.

### 5. Build the new node

Follow the guide from the top on the new machine:
- **Stage 0.1** BIOS — VT-x, VT-d, VMD/RST disabled
- **Stage 1** install, hostname `pve2` (or `pve3` if you'd rather not reuse it), IP `192.168.0.12`
- **Stage 2** repos + upgrade
- **Stage 3** only if the replacement is a laptop
- **Stage 4** both interfaces: `vmbr0` on 192.168.0.12, the 10G interface on 10.10.10.2
- **Stage 5** ZFS pools — **`apps` and `db`, spelled exactly the same.** This is the single most important detail in the whole procedure; replication matches on pool name

Check CPU compatibility before going further:
```bash
lscpu | grep -o 'avx2\|bmi2\|fma' | sort -u    # x86-64-v3 needs these
```
Any workstation CPU from the last decade passes. If the new machine were *older* than the surviving node, you'd have to drop the VMs to `x86-64-v2` — check before, not after.

### 6. Rejoin the cluster

On the new node: **Datacenter → Cluster → Join Cluster**, paste pve1's join information:
- Link 0 = `10.10.10.2`
- Link 1 = `192.168.0.12`

Then restore the third vote:
```bash
# on pve1
pvecm qdevice setup <qdevice-IP>
pvecm status                  # Total votes: 3, Quorate: Yes
corosync-cfgtool -s           # both rings OK
```

### 7. Recreate replication

VM → **Replication → Add** → target: the new node → the schedules from Stage 10 (`*/1` for 1030, `*/5` for 1020, `*/15` for 1010).

The first run is a **full transfer**, not a delta — every VM disk crosses the wire. Over the 10G direct link expect roughly 10-20 minutes for a few hundred GB; the Postgres disk dominates. VMs keep running throughout.

```bash
pvesr status                  # watch until all jobs report OK
```

### 8. Re-add HA and rebalance

```bash
ha-manager add vm:1020 --state started
ha-manager add vm:1030 --state started
ha-manager status
```

Then migrate whatever you want back onto the new node — live, no downtime.

## 16.3 Approach B — transplanting the disks

If the same three NVMe drives are moving into a new chassis, the ZFS pools come along untouched and you skip the full resync entirely. It's faster, but it has a specific trap.

1. Shut down the node cleanly (VMs migrate off automatically if `shutdown_policy=migrate` is set).
2. Move all three drives into the new machine, keeping the same roles.
3. Configure BIOS as in Stage 0.1 and boot.
4. **Expect the network to be broken.** The new machine has different NICs, so interface names change (`eno1` → `enp5s0`, and the Thunderbolt adapter gets a new name if the MAC differs). Proxmox boots fine but is unreachable.
5. At the **physical console**, fix it:
```bash
ip -br a                                  # see the new interface names
nano /etc/network/interfaces              # update bridge-ports and the 10G interface name
ifreload -a
ping 192.168.0.1
```
6. Verify the pools imported and the cluster reformed:
```bash
zpool status                              # apps and db ONLINE
pvecm status                              # quorate
pvesr status                              # replication resumes on its own
```

The cluster identity lives on the OS disk, so the node rejoins as itself — no delnode, no rejoin, no resync. Just be prepared to spend ten minutes at a physical keyboard.

## 16.4 Verification after either approach

```bash
pvecm status                  # 2 nodes + QDevice = 3 votes, Quorate: Yes
corosync-cfgtool -s           # LINK 0 and LINK 1 both OK
zpool status                  # apps and db ONLINE on both nodes, no errors
pvesr status                  # all jobs OK, recent timestamps
ha-manager status             # services started
ethtool <10g-if> | grep -i speed        # 10000Mb/s
```

Then run the real test — the one that proves the replacement actually restored your redundancy rather than just looking like it did:

```bash
# Live-migrate a VM to the new node and back
qm migrate 1020 pve2 --online
qm migrate 1020 pve1 --online
```

And when you have a maintenance window, repeat test 3 from Stage 15.6 (hard kill) against the new node.

## 16.5 Things that bite

- **Pool names.** `apps` and `db`, character for character. A pool called `apps1` on the new node means replication silently has nowhere to go.
- **Removing the QDevice before `delnode`.** Skip it and you get quorum errors that look far more alarming than the actual problem.
- **Never re-power the removed node** on the same network with its old cluster config.
- **CPU generation going backwards.** Replacing with older hardware can invalidate `x86-64-v3`. Check with `lscpu` before you migrate anything onto it.
- **The window in step 4-6.** Between `delnode` and the new node joining, you are running on one node with no failover. Do the swap when you can afford that, not on a Friday evening during an event weekend.
- **Interface names in approach B.** Guaranteed to change. Have a keyboard and monitor ready before you start rather than discovering the need mid-swap.
