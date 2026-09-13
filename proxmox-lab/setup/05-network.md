# Stage 5 — Network interfaces

*Part of the [Proxmox lab guide](../README.md).*

All of this is done from the Proxmox UI: select the node → **System → Network**.

<a id="51-management-network--vmbr0-on-the-onboard-nic"></a>

## 5.1 Management network — `vmbr0` on the port that holds the LAN cable

The installer already built this. Verify (and fix if needed):

1. Select the row **`vmbr0`** → **Edit**:
   - **IPv4/CIDR**: `192.168.0.11/24` (pve1) / `192.168.0.12/24` (pve2)
   - **Gateway (IPv4)**: `192.168.0.1`
   - **Bridge ports**: the port that actually has the LAN cable in it — **not necessarily the onboard NIC**. The installer pins every built-in port to a `nicN` name (5.5), and only pve2 matches the plan: its `nic0` *is* the onboard I219 (`e1000e`), cable ② of [0.4](00-preparation.md#04-physical-cabling--what-goes-where). **pve1 does not.** There the onboard `nic0` sits unplugged as `iface nic0 inet manual`, and `vmbr0` rides `nic2` — the X550's **port 2**, which is where cable ① of [0.4](00-preparation.md#04-physical-cabling--what-goes-where) lands on this node and what the 1G row of [0.3](00-preparation.md#03-network-plan) means by *on pve1 X550 port 2, not the onboard one*. The port left spare on pve1 is therefore the onboard 1G, not an X550 one. Pick by carrier, never by name and never by driver: `ip -br link` shows `UP`/`LOWER_UP` on the one port with a live cable, and `ethtool -i` cannot separate pve1's two X550 ports because both answer `ixgbe` — trusting the driver picks `nic1`, the 10G link, and hands you a node with no management network and a drive to wherever it lives.
   - **Autostart**: checked · **VLAN aware**: unchecked
2. **System → DNS** → Edit → DNS server 1: `192.168.0.1` (or `1.1.1.1`).

## 5.2 The 10G direct link — plugged in on demand, not left connected

**This cable is not part of the running cluster.** It is plugged in when a migration is about to move real data, and unplugged afterwards. Decided 2026-09-10; before that it was treated as permanent infrastructure, and the gap between that assumption and the truth is what this section now exists to close.

The hardware, on this build:

| Node | Interface | What it is |
|---|---|---|
| pve1 | `nic1` | Intel X550 port 1, onboard PCIe — always present, simply without carrier when the cable is out |
| pve2 | `enp62s0` | ACASIS NT0201A Thunderbolt dock (`atlantic` driver) — **the interface does not exist at all** while the dock is unplugged |

That asymmetry is the thing to internalise. On pve1 an absent cable looks like a NIC with `Link detected: no`; on pve2 it looks like a NIC that has vanished from `ip link` entirely, taking its address with it. Anything that greps for the interface by name will therefore behave differently on the two nodes, and a check that assumes "configured means present" will be wrong on exactly one of them.

Set it up once, with the cable connected:

1. Connect pve1's X550 **port 1** to pve2's Thunderbolt dock with a Cat6a cable. No switch.
2. On each node: **System → Network** → find the 10G interface — **pve1: `nic1`** (X550 port 1), **pve2: `enp62s0`** (the dock) — and confirm which is which with `ethtool -i <iface>` rather than by name: `ixgbe` is the X550, `atlantic` is the Thunderbolt adapter. The two nodes name this interface under two different schemes and only one of the names is stable (5.5). Then **Edit**:
   - **IPv4/CIDR**: `10.10.10.1/24` (pve1) / `10.10.10.2/24` (pve2)
   - **Gateway (IPv4)**: **leave empty** — a node must have exactly one default gateway, and `vmbr0` already has it
   - **Autostart**: checked on pve1. On pve2 prefer `allow-hotplug` over `auto` in `/etc/network/interfaces` (5.5): `auto` asks `ifup -a` at boot to configure an interface that is usually not there, and there is no reason to make every boot step over a predictable failure.
3. Press **Apply Configuration** (the yellow banner at the top). No reboot needed — Proxmox applies live via ifupdown2.

Then unplug it. The addresses stay in the config on both sides, so re-connecting is a cable and one command (5.4) rather than a reconfiguration.

### Why corosync still lists a link on this cable

`/etc/pve/corosync.conf` declares `ring1_addr` on `10.10.10.x` for both nodes, and that stays. It is deliberately **not** removed, for two reasons:

- **It is quiet when absent.** corosync logs the transition once, loudly — `[KNET] link: host: 2 link: 1 is down` — and then says nothing further; over the six days that followed 2026-09-04 there were zero further lines in `journalctl -u corosync`. Membership rides on ring 0, quorum stays 3/3 with the QDevice, and knet simply has one fewer path to consider. Note what that pair of facts means together: **the event is logged exactly once, and nothing reports the state.** That is the argument for `cluster-health` naming the link explicitly rather than for ignoring it.
- **Removing it is not free.** Changing the number of links in `corosync.conf` on a live cluster means a config reload with HA armed and the watchdog live. A mistake there costs a fenced node and rebooted guests; the gain is tidiness. Not a trade worth taking.

### What an unplugged ring 1 actually costs you

Write this down, because it is the part that is easy to wave away and it is not small.

**The QDevice at `192.168.0.10` sits on the same LAN as ring 0.** So with the 10G cable out, ring 0 is the sole path to *both* the peer *and* the tiebreaker. Quorum is `Expected votes: 3`, `Quorum: 2`.

| | Switch (or the LAN) dies |
|---|---|
| **Ring 1 down** (today) | Each node sees only itself: 1 vote of 3. Neither is quorate, `/etc/pve` goes read-only on both, and HA can restart a guest nowhere. Every node holding an open watchdog then stops petting `softdog` and resets itself ~60 s later — that is any node whose LRM is running HA guests, **and** whichever node holds the CRM master lock ([15.4](../ha/15-ha.md#154-the-watchdog--what-fencing-actually-rests-on)). Today both roles sit on pve1 (`ha-manager status`: `master pve1`, `lrm pve1 (active, watchdog active)`, `lrm pve2 (idle, watchdog standby)`), so pve1 resets and pve2 is left up, read-only and unable to start anything. Move an HA service to pve2, or let the master lock land there, and it fences too. The cluster is down either way — the only thing at stake is how many machines you find rebooted. |
| **Ring 1 up** | The nodes still see each other over `10.10.10.0/24`: 2 votes of 3, which meets quorum. The QDevice is lost, the cluster survives. |

That is the redundancy being traded away, and it is a real one: a single switch is a single point of failure for the entire cluster while this cable is out. It is an acceptable trade for a homelab whose switch is not expected to die, and it is *not* acceptable silently — which is why it is written here rather than left to be rediscovered during the outage.

If that cost ever stops being acceptable, the fix is not a corosync edit: it is a cable that stays in, and at that point ring 1 should come out of `ON_DEMAND_LINKS` in `cluster-health` so its absence warns again.

The day-to-day consequence is that `corosync-cfgtool -s` shows **link 1 disconnected as its normal state**. `cluster-health` knows this — `ON_DEMAND_LINKS` at the top of the script lists which links are allowed to be down — and classifies it per link, reporting link 1 as expected rather than as a warning. Link 0 is deliberately not in that list: it carries membership, and it being down is an incident. The check also needs `corosync-cfgtool`, which lives in `/usr/sbin`, outside cron's default `/usr/bin:/bin`: a grep for `faulty|disconnected` run against `command not found` matches nothing and reads as `[ OK ] corosync: all links healthy` — **a missing tool reads exactly like a healthy ring** — which is why both the script and its cron file set `PATH`, and why a tool the script cannot find is reported as a check that did not run.

> Do not "fix" a disconnected link 1 by editing corosync. If you want the throughput, plug in the cable (5.4). If you want the switch-failure redundancy, that is the table above, and it requires a cable that stays in.

## 5.3 Verify

Node → **Shell**:
```bash
ip -br a                      # each interface with the expected address
ip route | grep default       # exactly ONE line, via vmbr0
ping -c3 8.8.8.8              # the default route
corosync-cfgtool -s           # link 0 connected; link 1 disconnected is NORMAL (5.2)
```

Two default routes is the classic mistake here, and it produces a cluster that misbehaves for no obvious reason. If `ip route` shows more than one, remove the gateway from the 10G interface.

With the 10G cable **connected**, these should also pass — they are meaningless, and expected to fail, when it is not:

```bash
ping -c3 10.10.10.2                        # the direct link (from pve1)
ethtool nic1 | grep -i speed               # pve1: expect 10000Mb/s
ethtool enp62s0 | grep -i speed            # pve2: same
```

Note *how* they fail when it is out, because the same missing link gives two different negatives: on pve1 `ethtool nic1` answers `Link detected: no` / `Speed: Unknown!`, since the X550 stays on the PCI bus; on pve2 `ethtool enp62s0` answers `netlink error: No such device` (and `ip link show enp62s0` its own `Device "enp62s0" does not exist.`), since the dock takes the whole PCI device with it. Neither is a fault (5.2) — but do not go hunting for a *down* interface on pve2: there the device is gone rather than down, so anything that scans for down interfaces finds nothing at all on that end.

And do not read `systemctl status networking` as evidence in either direction. To ifupdown2 a stanza naming a device that never appeared is not an error: pve2's unit sits at `active (exited)`, `status=0/SUCCESS`, with no address from `10.10.10.0/24` anywhere on the machine. Ring state is asked for per link — `corosync-cfgtool -s`, above — and never inferred from a green unit.

## 5.4 Using the 10G link for a migration

The whole reason the cable exists. Migration and replication are pinned to the LAN in `/etc/pve/datacenter.cfg`:

```
migration: secure,network=192.168.0.0/24
replication: network=192.168.0.0/24,type=secure
```

That pinning is deliberate and must stay: it is what makes an ordinary migration work on an ordinary day, with no cable and no ceremony. The 10G path is then requested **per migration**, as an override, which is exactly the shape an on-demand link should have — nothing silently depends on a cable being in.

1. Plug the Cat6a cable into pve1's X550 port 1 and pve2's Thunderbolt dock.
2. On **pve2**, bring the interface up — it did not exist a moment ago, so nothing has configured it:
   ```bash
   ifup enp62s0 && ip -br a show enp62s0
   ```
   (pve1 needs nothing: `nic1` is always present and already carries `10.10.10.1`; it simply gains carrier.)
3. Prove the path before trusting it with data:
   ```bash
   ping -c3 10.10.10.1        # from pve2
   ```
4. Migrate from the node the guest is on — all four guests live on pve1 today — naming the network explicitly:
   ```bash
   qm migrate 1023 pve2 --online --migration_network 10.10.10.0/24 --migration_type insecure
   ```
   **Both flags are silently dropped for an HA guest.** 1021 and 1022 are HA-managed ([15.1](../ha/15-ha.md#151-which-vms-get-ha)), and for those `qm migrate` does not migrate at all: it forks `ha-manager migrate vm:<id> <node>`, which takes a resource and a target and nothing else. The move then runs over `datacenter.cfg`'s LAN pinning at 1G, with nothing in the task log mentioning the override you passed. So this cable is usable by hand for the non-HA guests (1020, 1023); putting the app or the database across it means editing `datacenter.cfg` for the duration and putting it back — a live change to a fencing cluster, to make one move faster.

   `--migration_type insecure` drops the SSH tunnel. On a direct cable between two machines in the same room, with no switch and nothing else attached, the tunnel buys nothing and costs most of the throughput you plugged the cable in for. Do **not** carry that flag over to a migration on the LAN.
5. Unplug the cable when the migration is done. On pve2, `ifdown enp62s0` first if you want the config to match reality; leaving it is harmless, since the interface disappears with the dock either way.

> The dock is not a stable member of anything. On this build it has disconnected on its own more than once — on 2026-09-08 it enumerated and vanished again 47 seconds later. That is survivable for a migration you are watching, and it is the second reason nothing permanent is allowed to depend on this link.

## 5.5 For reference — the resulting config

`/etc/network/interfaces`, as the two nodes actually read today — the comments are this guide's, not in the files, which open with PVE's autogenerated *do NOT modify this file directly* header and end by sourcing `interfaces.d`. Useful for verification, and editable directly if you prefer (apply with `ifreload -a`).

**pve1** — the interfaces are renamed `nic0`/`nic1`/`nic2` by udev, so the names are stable across kernel and slot changes. Note that the bridge port is `nic2`, not `nic0`; the onboard I219-LM (`nic0`) is unused:

```
auto lo
iface lo inet loopback

auto nic2
iface nic2 inet manual              # X550 port 2 — bridge port, no IP of its own

iface nic0 inet manual              # onboard I219-LM — not used

auto nic1
iface nic1 inet static
    address 10.10.10.1/24           # 10G direct link — no gateway (5.2)

auto vmbr0
iface vmbr0 inet static
    address 192.168.0.11/24
    gateway 192.168.0.1
    bridge-ports nic2
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
```

**pve2** — only `nic0` exists as a usable renamed interface; the 10G side is the Thunderbolt dock under its kernel name, and it is present only while the dock is:

```
auto lo
iface lo inet loopback

iface nic0 inet manual              # onboard — bridge port

iface nic1 inet manual              # pinned to the Wi-Fi MAC — never materialises (below)

auto enp62s0                        # still `auto` on the machine; 5.2 step 2 asks for
iface enp62s0 inet static           #   allow-hotplug here, and this is the line to change
    address 10.10.10.2/24           # 10G dock — on demand (5.2), no gateway

iface wlp0s20f3 inet manual         # the Wi-Fi card, under its kernel name

auto vmbr0
iface vmbr0 inet static
    address 192.168.0.12/24
    gateway 192.168.0.1
    bridge-ports nic0
    bridge-stp off
    bridge-fd 0

source /etc/network/interfaces.d/*
```

Three things worth having written down, because all three have already caused confusion:

- **The naming is not symmetric.** pve1 renames everything to `nicN`; pve2 renames only its onboard NIC and leaves the dock as `enp62s0`. Any command you copy from one node's shell to the other's will name the wrong interface.
- **`enp62s0` is a PCI-path name** (`0000:3e:00.0` → bus 62). It is stable as long as the dock goes into the same Thunderbolt port. Move it to the other port and the interface name changes, at which point the stanza above configures nothing and `ifup` reports an interface that does not exist.
- **`iface nic1 inet manual` on pve2 can never come up.** Its `.link` file matches the Wi-Fi card's MAC (`6c:2f:80:a4:ae:f2`) with `Type=ether`, which a wlan device never satisfies, so that card stays `wlp0s20f3` and `nic1` simply does not exist on pve2. A harmless installer leftover — do not go looking for the NIC it names, and do not assume `nic1` means the same thing it means on pve1, where it is the 10G port.

**Where `nic0`/`nic1`/`nic2` come from — and why they are not in your backup.** They are not kernel names, and nothing under `/etc` produces them. The Proxmox installer pins them by MAC in `/usr/local/lib/systemd/network/50-pmx-nicN.link`; `udevadm info /sys/class/net/nic2` names the file that won:

```
# setup by the Proxmox installer.
[Match]
MACAddress=b4:96:91:67:47:8e
Type=ether

[Link]
Name=nic2
```

That directory is not in [`pve-config-backup`](../scripts/README.md)'s tar list — it archives `etc/pve`, `etc/network/interfaces`, `etc/fstab`, `etc/hosts`, `etc/nut`, `etc/apt/sources.list.d`, `etc/cron.d`, `etc/crontab`, `etc/systemd/system`, `usr/local/bin`, `usr/local/sbin`, and stops there. `/etc/systemd/network/` is empty on both nodes, so the archive contains no copy of these rules by any other route. Restore a node from it onto a fresh install and you get an `/etc/network/interfaces` naming devices nothing creates: `vmbr0` comes up with no bridge port, the node has no management network, and you find that out at a physical keyboard with the cluster already down a member. Copy `/usr/local/lib/systemd/network/` off alongside the archive, or add the path to the script's tar list and stop thinking about it.

The same MAC pinning is what breaks the network when the X550 or the mainboard is replaced: no `[Match]` fires, so the pinned name never appears and the card comes up under its kernel name — [19.3](../operations/19-node-replacement.md#193-approach-b--transplanting-the-disks) walks that through, calling it a name *change*, which is the same symptom by a different mechanism. The fix is at the console either way: read `ip -br a`, put the names you actually see into `/etc/network/interfaces`, `ifreload -a`. Rewriting the `.link` files with the new MACs is optional and cannot be done in advance — you do not know them until the new hardware boots. Do it only if you want the `nicN` names back so the rest of these docs keep matching the machine.

Note also where `vmbr0` actually sits on pve1: on X550 port 2, not on the onboard NIC — as [0.3](00-preparation.md#03-network-plan)'s 1G row and cable ① of [0.4](00-preparation.md#04-physical-cabling--what-goes-where) both say. Bridge the onboard port instead, because a two-node plan of this shape usually means the onboard one, and you take the web UI down with the change.

> If you lose the web UI after Apply Configuration, you changed the wrong bridge port. Go to the machine's physical console, fix `/etc/network/interfaces` with `nano`, then `ifreload -a`.
