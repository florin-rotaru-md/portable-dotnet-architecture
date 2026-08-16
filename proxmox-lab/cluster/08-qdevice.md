# Stage 8 — QDevice (mandatory for maintenance with one node down)

*Part of the [Proxmox lab guide](../README.md).*

The QDevice earns its keep twice: besides the third vote, it later receives the continuous Postgres WAL stream ([Stage 13](../ha/13-wal-stream.md)). It is hand-managed like the Proxmox hosts — this stage and [13.2](../ha/13-wal-stream.md#132-the-receiver-on-the-qdevice) *are* its documentation.

## 8.1 The box and its OS

This build's QDevice is a **Dell Pro 14 (PC14250)** — Core Ultra 5 225U, 16GB DDR5, 2TB NVMe — with the preinstalled Windows replaced by **Debian 13 (trixie)**, netinst, *standard system utilities* + *SSH server*, no desktop. It has headroom for both jobs without noticing them.

**Match the nodes' Debian suite rather than taking the newest:** trixie on PVE 9, bookworm on PVE 8. Both halves of the qnetd/qdevice pair then come from the same corosync line, `intel-microcode` + `fwupd` install from stock repos exactly as [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) describes, and [13.2](../ha/13-wal-stream.md#132-the-receiver-on-the-qdevice)'s PGDG line — built from `$VERSION_CODENAME` — resolves without editing. Ubuntu Server works too and the packages all exist; it just adds snapd and a second update rhythm to the one machine whose entire job is being predictably up. What is *not* an option is anything that keeps Windows underneath: a WSL2 or Hyper-V guest gets NAT'd networking, doesn't start before login, and reboots on a schedule Windows Update chooses — which is the third vote and the WAL receiver disappearing at random. Dual-boot is the same problem made deliberate.

Three things that aren't the OS but decide whether the install works at all:

- **BIOS → SATA/NVMe operation: AHCI/NVMe, not "RAID On".** Dell ships business laptops with Intel RST enabled and the Debian installer then finds no disk whatsoever. Same trap as VMD on the nodes ([0.1](../setup/00-preparation.md#01-bios)), different menu.
- **Wired Ethernet and a static IP — `192.168.0.10`** ([0.3](../setup/00-preparation.md#03-network-plan)), configured on the machine and outside the router's DHCP pool. Both nodes must always reach this address, and it gets baked into two places that fail *quietly* when it moves: `corosync.conf` (8.2 below) and 1022's `pg_hba.conf` + UFW as a `/32` ([13.1](../ha/13-wal-stream.md)). A changed address costs you the third vote on **both** nodes at once — the cluster keeps running on 2/2 and looks perfectly healthy until the next time you take a node down ([18.3](../ha/18-failover.md#183-scenario-table)) — and stops the WAL stream, which surfaces only in the next morning's [`backup-verify`](../scripts/README.md). If the chassis has no RJ45, a USB-C/Thunderbolt adapter; don't put quorum on Wi-Fi, where every roam or dropout flaps the third vote and interrupts the WAL stream.
- **Write a Dell OS Recovery Tool USB before wiping the disk.** It's the only cheap way back to a factory Windows for an RMA or a vendor diagnostic, and it stops existing the moment you partition.

**Setting the address.** Cheapest at install time: at the netinst network step pick **Configure network manually** and enter address `192.168.0.10`, netmask `255.255.255.0`, gateway `192.168.0.1`, DNS `192.168.0.1` (or whatever resolver you use). Nothing to redo afterwards.

If the box is already installed on DHCP, it's one file — a Debian netinst without a desktop runs plain `ifupdown`, no NetworkManager. **Do this at the physical console, not over SSH:** changing the address drops the session mid-edit either way.

```bash
ip -br link                       # find the wired NIC (enp0s31f6, enx0242…, …)
nano /etc/network/interfaces      # replace the "iface <nic> inet dhcp" stanza
```
```
auto enp0s31f6
iface enp0s31f6 inet static
    address 192.168.0.10/24
    gateway 192.168.0.1
    dns-nameservers 192.168.0.1
```
```bash
systemctl restart networking      # or just reboot — it's a laptop doing nothing yet
ip -br a                          # 192.168.0.10/24 on the wired NIC, nothing on wlan
ping -c2 192.168.0.1
```

> `dns-nameservers` is honoured only when the `resolvconf` package is installed — Debian netinst doesn't pull it in by default. Check `cat /etc/resolv.conf` after the restart and write the `nameserver` line by hand if it came back empty. `ifreload -a` doesn't exist here either; that's ifupdown**2**, which ships with Proxmox but not with stock Debian.

Confirm from **both** nodes before going on — 8.2 fails if either can't reach it, and a QDevice reachable from only one node is worse than none:
```bash
ping -c2 192.168.0.10
```

## 8.2 Install and join

On the QDevice:
```bash
apt update && apt install corosync-qnetd
```

On BOTH Proxmox nodes:
```bash
apt install corosync-qdevice
```

On pve1 ONLY:
```bash
pvecm qdevice setup 192.168.0.10
```

Verify:
```bash
pvecm status    # Total votes: 3, Quorate: Yes
```

## 8.3 It's a laptop — Stage 3 applies here too

[Stage 3](../setup/03-laptop-node.md) is written for pve2, but **3.1 (ignore the lid, mask the sleep targets) and 3.2 (clean shutdown at 10% battery) are just as mandatory here** — run them now, on this box. Skip 3.1 and closing the lid suspends the machine: the cluster silently drops to two votes and `pg-receivewal` stops, with nothing on fire to tell you. 3.3 (TLP + the dynamic governor) is optional on a machine this idle; TLP alone is harmless if you want it, the load-driven governor script is aimed at a hypervisor and has no work to do here.

The battery is a real advantage over the mini PC that usually fills this role: a power cut no longer takes the third vote with it, and the QDevice becomes the *last* of the three machines to shut down — see the [4.4](../setup/04-ups.md#44-the-long-outage-timeline-end-to-end) timeline.

## 8.4 Firmware baseline

Give it the same firmware baseline the nodes got in [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) — it's a full third of the cluster's quorum, not an accessory:

```bash
apt install -y intel-microcode fwupd    # stock Debian repos already carry both
fwupdmgr get-devices                    # a Dell should list System Firmware here (16.3)
```

Dell publishes its business hardware to LVFS, so unlike the generic mini PC that usually fills this role, the QDevice reports its own BIOS state daily through [`cluster-health`](../scripts/README.md) and `fwupdmgr update` is the normal route when a flash is actually warranted. All three machines being LVFS-covered is what makes [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely)'s *detect always, flash rarely* policy cheap to run — and the QDevice stays the machine you flash **first** when a firmware round comes: with both nodes up, losing it for a reboot still leaves the cluster quorate.
