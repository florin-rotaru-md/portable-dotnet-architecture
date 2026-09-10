# Stage 19 — Replacing a node with new hardware

*Part of the [Proxmox lab guide](../README.md).*

Different from Stage 16: there you power a node down and bring the *same* machine back. Here the machine is gone for good and a new one takes its place. The VMs never have to stop — but the cluster membership does change, and that part has an order you have to respect.

## 19.1 Pick the approach

| | Approach | When it fits | Downtime | Resync needed |
|---|---|---|---|---|
| **A** | **Clean swap** — evacuate, remove old node, install fresh, rejoin | The default. New machine, different disks | **0** | Yes, full |
| **B** | **Disk transplant** — move the NVMe drives into the new chassis | Same drives moving to a new box | Minutes | No |
| **C** | **Temporary third node** — join new, migrate, remove old | You have a 10G switch | **0** | Yes, full |

Approach **A** is what to use unless you have a specific reason not to. Approach **C** is smoother in theory, and the obstacle is not the LAN: ring 0, migration and replication all ride the 1G switch every machine here already plugs into (`datacenter.cfg` pins both transfers to `192.168.0.0/24`, [5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)). The obstacle is ring 1. This cluster declares two corosync links and the join demands an address for **every** link the cluster has (step 6), and link 1 is a point-to-point cable with exactly two ends — there is no third port to hand a joining node. Without a 10G switch the only way in is to take link 1 out of `corosync.conf` first, a `config_version` bump on a live cluster with the watchdog armed, which is precisely the edit [Stage 7](../cluster/07-cluster.md) tells you not to make casually. Skip C.

Assume below you're replacing **pve2**. Replacing pve1 is symmetric.

## 19.2 Approach A — clean swap, step by step

### Before you touch anything

```bash
# On-demand backup of everything — you have replication, and this is still worth 10 minutes.
# Find out where it can land first: `usb-backup` (17.2) is the intended target, but it does
# not exist on this build — the drive was never attached, so a --storage usb-backup run aborts.
pvesm status                  # is usb-backup listed? if not, fall back to `local`
df -h /var/lib/vz             # `local` is a dir storage with content=backup; ~16G of zvols
                              # across the four VMs (1022 is 1T provisioned, 2G used) — zstd
                              # makes that a few GB against ~78G free

# vzdump only backs up guests on the node it runs on — all four live on pve1 today, so run it there
vzdump 1020 1021 1022 1023 --storage local --mode snapshot --compress zstd
ls -lh /var/lib/vz/dump       # prove it actually wrote something

# `local` is the root filesystem of the node you are about to lean on — get the archives off it.
# Exactly one off-node destination exists on this build: the QDevice at 192.168.0.10 (x86_64
# Debian, 1.7T free, root SSH working from both nodes, checked 2026-09-10). pve2 is the machine
# you are removing, so it is not one. /srv there shares its filesystem with /var/lib/wal-archive
# (Stage 13) — `ssh root@192.168.0.10 df -h /srv` before you push tens of GB into it.
scp /var/lib/vz/dump/vzdump-qemu-*.zst root@192.168.0.10:/srv/

# Write down the config you'll need to recreate
cat /etc/pve/corosync.conf | grep -A4 "node {"
pvesr status
cat /etc/pve/replication.cfg  # the schedules themselves — pvesr status shows state, never schedule
ha-manager status
ip -br a                      # on pve2, note both IPs
```

⚠️ **On this build that dump is the only VM-level copy that has ever existed.** Nothing has ever been written to `/var/lib/vz/dump` on either node and the USB drive of [17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive) was never attached, so read the first comment accordingly: this is not the belt-and-braces extra on top of replication, it is the whole of it. Every pool on both machines is a **single-device vdev** with no redundancy, so from the moment step 4 removes pve2 until step 7 finishes resyncing, pve1 holds the only copy of everything you own — and an archive parked on pve1's own root filesystem dies with pve1. Copy it off the node before you run `delnode`, not after.

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
pvesr delete 1021-0 --force   # repeat for each job
```

HA config keys off node names too. If you pinned resources to specific nodes, edit that now — **Datacenter → HA → Rules**, where the departing node has to come out of the node affinity rule's `nodes` list. Plain HA resources with an empty Rules panel, which is what [15.5](../ha/15-ha.md#155-rules-and-the-two-flags-that-default-to-on) leaves you with, need no change.

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
- **Stage 0.1** BIOS — VT-x, VT-d, VMD/RST disabled. New hardware is also the one moment a firmware update costs nothing: flash it *now*, while the machine holds no data and is in no cluster ([16.3](16-maintenance.md#163-firmware--detect-always-flash-rarely))
- **Stage 1** install, hostname `pve2` (or `pve3` if you'd rather not reuse it), IP `192.168.0.12`
- **Stage 2** repos + upgrade, and **2.5** — *restore* this node's key pair from the password manager ([0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now)) rather than generating a new one. The old public half is already in `authorized_keys` on every existing VM; a fresh pair would open none of them until Ansible re-seeded it
- **Stage 3** only if the replacement is a laptop
- **Stage 5** both interfaces: `vmbr0` on 192.168.0.12, the 10G interface on 10.10.10.2
- **Stage 6** ZFS pools — **`apps` and `db`, spelled exactly the same.** This is the single most important detail in the whole procedure; replication matches on pool name. The node is still standalone here, so *Add Storage* writes a local storage entry that the join in step 6 discards — harmless, as long as the cluster-wide `apps`/`db` entries carry no node restriction ([Stage 6](../cluster/06-zfs-pools.md))

Check CPU compatibility before going further:
```bash
lscpu | grep -o 'avx2\|bmi2\|fma' | sort -u    # x86-64-v3 needs these
```
Any workstation CPU from the last decade passes. If the new machine were *older* than the surviving node, you'd have to drop the VMs to `x86-64-v2` — check before, not after.

### 6. Rejoin the cluster

On the new node: **Datacenter → Cluster → Join Cluster**, paste pve1's join information:
- Link 0 = `192.168.0.12`
- Link 1 = `10.10.10.2`

> **Link numbers are cluster-wide — they are not a property of the node you are joining, and not yours to pick.** Run `grep ring /etc/pve/corosync.conf` on pve1 before you type anything into the dialog: this cluster has pve1 on `ring0_addr: 192.168.0.11` and `ring1_addr: 10.10.10.1`, so the replacement has to be numbered the same way round — ring 0 on the LAN, ring 1 on the 10G cable. Nothing stops you getting it backwards. The join API checks only that every link the cluster has is supplied and that the address isn't already used by another node; it never checks that the address is on the same network as the rest of that link. Swap the two and the join is *accepted*, `corosync.conf` is rewritten, and both rings are then crossed — pve1's link 0 (`192.168.0.11`) pointed at `10.10.10.2`, its link 1 (`10.10.10.1`) at `192.168.0.12`. Neither pair shares a network, so no ring forms, the new node never goes quorate, and you find that out in the step 4-6 window, on one node with no failover. It matters long after the join too: [`cluster-health`](../scripts/README.md) locates the peer by reading `ring0_addr` out of `corosync.conf` and SSHing to it — and the 10G cable is unplugged as its normal state ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), so ring 0 on the point-to-point link would leave its peer checks unreachable-by-design almost all of the time. [`node-return`](../scripts/README.md) survives that one — it collects every `ring*_addr` from the peer's stanza and walks them, ring 0 first — but that fallback exists for the day a ring is genuinely down, not to make a crossed join livable.

Then restore the third vote:
```bash
# on pve1
pvecm qdevice setup 192.168.0.10
pvecm status                  # Total votes: 3, Quorate: Yes
corosync-cfgtool -s           # LINK ID 0 → 192.168.0.x, LINK ID 1 → 10.10.10.x, both
                              # connected — with the 10G cable plugged in for the swap (5.2)
```

### 7. Recreate replication

VM → **Replication → Add** → target: the new node → **the schedules you captured from `replication.cfg` before step 2**, not the ones you remember. Step 2's `pvesr delete` takes the only authoritative copy with it, and a schedule retyped from memory diverges silently — nothing in the cluster ever compares what you rebuilt against what you had. [Stage 12](../ha/12-replication.md)'s table — `*/1` for 1022, `*:0` for 1020, 1021 and 1023 — is what the cluster is actually running today, so capture and table should agree; if they don't, the capture is what you were running and the table is what was intended, and reconciling them is a deliberate commit rather than something a rebuild settles in whichever direction the operator happened to type.

The first run is a **full transfer**, not a delta — every VM disk crosses the wire, and it crosses the **1G LAN**: `datacenter.cfg` pins replication to `192.168.0.0/24` ([5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration)), and unlike a migration there is no per-job override to point it at the 10G cable. Budget hours, not minutes, for a few hundred GB; the Postgres disk dominates. VMs keep running throughout.

```bash
pvesr status                  # watch until all jobs report OK
```

### 8. Re-add HA and rebalance

```bash
# both flags default to 1 — pass them, or the rebuilt pair comes back movable (15.5)
ha-manager add vm:1021 --state started --failback 0 --auto-rebalance 0
ha-manager add vm:1022 --state started --failback 0 --auto-rebalance 0
ha-manager status
```

Then migrate whatever you want back onto the new node — live, no downtime.

## 19.3 Approach B — transplanting the disks

If the same three NVMe drives are moving into a new chassis, the ZFS pools come along untouched and you skip the full resync entirely. It's faster, but it has a specific trap.

1. Shut down the node cleanly (VMs migrate off automatically if `shutdown_policy=migrate` is set).
2. Move all three drives into the new machine, keeping the same roles.
3. Configure BIOS as in Stage 0.1 and boot. If the new chassis is also due a firmware update, this is the trip to do it on — the node is already down and empty ([16.3](16-maintenance.md#163-firmware--detect-always-flash-rarely)).
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

## 19.4 Verification after either approach

```bash
pvecm status                  # 2 nodes + QDevice = 3 votes, Quorate: Yes
corosync-cfgtool -s           # read the per-nodeid lines, not the exit code: every peer
                              # `connected` under LINK ID 0 *and* under LINK ID 1
zpool status                  # apps and db ONLINE on both nodes, no errors
pvesh get /nodes/pve2/storage # apps and db listed and active — the pool existing is not enough
pvesr status                  # all jobs OK, recent timestamps
ha-manager status             # services started
ip -br link                   # the 10G interface is PRESENT — a dropped Thunderbolt
                              # adapter vanishes, it does not go DOWN
ethtool <10g-if> | grep -i speed        # 10000Mb/s
```

⚠️ **Run this part with the 10G cable plugged in, and treat it as the one moment the new machine's 10G side ever gets proven.** That link is on demand ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)): unplugged is its normal state, ring 1 is normally disconnected, and `cluster-health` lists link 1 in `ON_DEMAND_LINKS` so it stays quiet about it. That silence is correct for a cable you pulled on purpose and useless for a replacement whose 10G hardware never worked at all — you would find out on the next migration, or during the switch failure where ring 1 is the reason the cluster survives at 2 votes of 3 instead of both nodes self-fencing (the table in 5.2). Do not expect the older copy still installed on the nodes to be louder about it: it has no `ON_DEMAND_LINKS` at all, and under cron's `PATH` it never found `corosync-cfgtool`, so it reported `all links healthy` through six days of a genuinely dead ring 1 ([Stage 7](../cluster/07-cluster.md)).

Both checks lie if you let them. On pve2's side the 10G is a Thunderbolt dock, and when it drops it does not appear as a DOWN interface — it leaves `ip link` entirely, and `ethtool` then prints `No data available` on stdout and a run of `netlink error: No such device` on *stderr*, exit 75 (checked on pve2, 2026-09-10). Pipe that through `grep -i speed` and stdout goes empty while the errors stay on the terminal — loud if you are watching the screen, gone the moment you tee the block into a file, and in either case a line that prints nothing on stdout looks exactly like a check that had nothing to complain about; hence `ip -br link` first, and hence the `<10g-if>` placeholder, since the replacement machine's interface name is guaranteed to differ ([19.3](#193-approach-b--transplanting-the-disks) step 4). `corosync-cfgtool -s` has the mirror-image problem: it exits 0 with a ring down, and the only thing that says otherwise is the per-peer line under the header — `LINK ID 1 … nodeid: 2: disconnected`. Nothing else on the list would catch either: `pvecm status` is quorate on link 0 alone, and `pvesr status` is OK because `datacenter.cfg` pins both migration and replication to `192.168.0.0/24`.

Then run the real test — the one that proves the replacement actually restored your redundancy rather than just looking like it did:

```bash
# Live-migrate a VM to the new node and back
qm migrate 1021 pve2 --online
qm migrate 1021 pve1 --online

# plain ssh, one line on each node pointed at the other — nothing above tests this
ssh -o BatchMode=yes root@192.168.0.12 pveversion     # run on pve1
ssh -o BatchMode=yes root@192.168.0.11 pveversion     # run on the new node
```

⚠️ **Every test above passes while ordinary node-to-node SSH is broken, and after a swap it is broken in both directions.** PVE never uses ordinary SSH: `qm migrate`, replication and `pvecm` go through `PVE::SSHInfo`, which passes `-o UserKnownHostsFile=/etc/pve/nodes/<node>/ssh_known_hosts -o HostKeyAlias=<node>` on every call — a file keyed by *node name* and distributed by pmxcfs, which is why the migration test above proves exactly nothing about `ssh root@192.168.0.11`. Two separate things break, for two different reasons:

- **From the new node.** A fresh install has no entry for the peer in `/root/.ssh/known_hosts`, and the join creates none — the state pve2 is in today ([21.7](21-credentials.md#217-the-fourth-kind-the-pins-nobody-inventories)). At a console that surfaces as the *authenticity of host … can't be established* prompt, `StrictHostKeyChecking` being at its default `ask`, and typing `yes` there pins whatever answered sight unseen; anything without a terminal — a script, a cron job, `BatchMode=yes` — gets a flat `Host key verification failed` instead. What that costs is your own hands, not the tooling: [`node-return`](../scripts/README.md) reaches the peer the way PVE itself does — `HostKeyAlias=<node>` against `/etc/pve/nodes/<node>/ssh_known_hosts`, tried over every `ring*_addr` in the peer's stanza — so the [16.2](16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) procedure runs from either direction on a node nobody keyed. That is the script **in this repo**. `/usr/local/sbin` on both existing nodes still holds the 2026-09-04 build, which shells out to a plain `ssh` and aborts at its first gate; step 5 installs the current one on the replacement as part of Stage 2 ([2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes)), and the surviving node needs the same command run there after a `git pull` or 16.2 stays broken on the half of the pair you did not rebuild.
- **From the surviving node.** Its `known_hosts` still holds the **old** machine's key for that same address. New chassis, same IP, different key, so you get `REMOTE HOST IDENTIFICATION HAS CHANGED` — a warning that reads like an attack and is only a hardware swap. Appending the new key does not silence it; the stale line has to go first.

Key both nodes by hand as part of the swap, verifying the fingerprint out of band the way [8.4](../cluster/08-qdevice.md#84-ssh--key-only-from-your-pc-and-from-both-nodes) does it for the QDevice — a host key accepted blind is one you cannot later claim you checked:

```bash
# on the peer's physical console: the fingerprint you are about to trust
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

# on the surviving node only — evict the dead machine's key first
ssh-keygen -R 192.168.0.12 && ssh-keygen -R pve2

# then on each node, pointed at the other (peer address shown from the new node)
install -d -m 700 /root/.ssh
ssh-keyscan -t ed25519 192.168.0.11 > /tmp/peer.pub
ssh-keygen -lf /tmp/peer.pub          # must equal what the console printed — else stop
cat /tmp/peer.pub >> /root/.ssh/known_hosts && rm /tmp/peer.pub
```

Use the address that ends up as `ring0_addr` in `/etc/pve/corosync.conf`: that is where `cluster-health` looks for its peer, and a key trusted for the wrong address of a two-address node buys you nothing. Neither helper depends on the pin any more — in the repo copies both borrow PVE's own per-node known-hosts file for their peer calls — which is exactly why `cluster-health`'s version line stays green through all of this and its separate `ssh:` line is the only thing that reports the breakage. A green version line is not evidence that plain SSH works.

And when you have a maintenance window, repeat test 3 from Stage 18.6 (hard kill) against the new node.

## 19.5 Things that bite

- **Pool names.** `apps` and `db`, character for character. A pool called `apps1` on the new node means replication silently has nowhere to go.
- **Removing the QDevice before `delnode`.** Skip it and you get quorum errors that look far more alarming than the actual problem.
- **Never re-power the removed node** on the same network with its old cluster config.
- **CPU generation going backwards.** Replacing with older hardware can invalidate `x86-64-v3`. Check with `lscpu` before you migrate anything onto it.
- **The window in step 4-6 is worse than "no failover".** Between `delnode` and the new node joining you are on one node whose two pools are both **single-device vdevs** — no mirror, no raidz on either machine, since [Stage 6](../cluster/06-zfs-pools.md) creates them as *Single Disk* — and the replication you deleted in step 2 was the second copy of every VM. One disk dying in that window costs everything back to the last `vzdump`, and it takes the in-VM Postgres dump on 1022 (`/opt/postgres/backups`) with it, because that lives on the same disk. That is why the step-0 archive is not the optional ten minutes its comment makes it sound like — and it only counts once you have seen the file and moved it off the node. Keep the window short and do the swap when you can afford it, not on a Friday evening during a peak-traffic window. If the new machine brings its own disks, leave the old node's drives untouched on a shelf until [19.4](#194-verification-after-either-approach) passes: a stale pool you could still transplant beats a wiped one.
- **Interface names in approach B.** Guaranteed to change. Have a keyboard and monitor ready before you start rather than discovering the need mid-swap.
