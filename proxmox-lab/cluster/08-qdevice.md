# Stage 8 — QDevice (mandatory for maintenance with one node down)

*Part of the [Proxmox lab guide](../README.md).*

The QDevice earns its keep twice: besides the third vote, it later receives the continuous Postgres WAL stream ([Stage 13](../ha/13-wal-stream.md)). It is hand-managed like the Proxmox hosts — this stage and [13.2](../ha/13-wal-stream.md#132-the-receiver-on-the-qdevice) *are* its documentation. Nothing in `native/infra/ansible` touches this machine, so anything not written here does not exist anywhere.

## 8.1 The box and its OS

This build's QDevice is a **Dell Pro 14 (PC14250)** — Core Ultra 5 225U, 16GB DDR5, 2TB NVMe — with the preinstalled Windows replaced by **Debian 13 (trixie)**, netinst, *standard system utilities* + *SSH server*, no desktop. It has headroom for both jobs without noticing them.

**Match the nodes' Debian suite rather than taking the newest:** trixie on PVE 9, bookworm on PVE 8. Both halves of the qnetd/qdevice pair then come from the same corosync line, `intel-microcode` + `fwupd` install from stock repos exactly as [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) describes, and [13.2](../ha/13-wal-stream.md#132-the-receiver-on-the-qdevice)'s PGDG line — built from `$VERSION_CODENAME` — resolves without editing. Ubuntu Server works too and the packages all exist; it just adds snapd and a second update rhythm to the one machine whose entire job is being predictably up. What is *not* an option is anything that keeps Windows underneath: a WSL2 or Hyper-V guest gets NAT'd networking, doesn't start before login, and reboots on a schedule Windows Update chooses — which is the third vote and the WAL receiver disappearing at random. Dual-boot is the same problem made deliberate.

Three things that aren't the OS but decide whether the install works at all:

- **BIOS → SATA/NVMe operation: AHCI/NVMe, not "RAID On".** Dell ships business laptops with Intel RST enabled and the Debian installer then finds no disk whatsoever. Same trap as VMD on the nodes ([0.1](../setup/00-preparation.md#01-bios)), different menu.
- **Wired Ethernet and a static IP — `192.168.0.10`** ([0.3](../setup/00-preparation.md#03-network-plan)), configured on the machine and outside the router's DHCP pool. Both nodes must always reach this address, and it gets baked into two places that fail *quietly* when it moves: `corosync.conf` ([8.5](#85-install-and-join)) and 1022's `pg_hba.conf` + UFW as a `/32` ([13.1](../ha/13-wal-stream.md)). A changed address costs you the third vote on **both** nodes at once — the cluster keeps running on 2/2 and looks perfectly healthy until the next time you take a node down ([18.3](../ha/18-failover.md#183-scenario-table)) — and stops the WAL stream, which surfaces only in the next morning's [`backup-verify`](../scripts/README.md). If the chassis has no RJ45, a USB-C/Thunderbolt adapter; don't put quorum on Wi-Fi, where every roam or dropout flaps the third vote and interrupts the WAL stream.
- **Write a Dell OS Recovery Tool USB before wiping the disk.** It's the only cheap way back to a factory Windows for an RMA or a vendor diagnostic, and it stops existing the moment you partition.

## 8.2 Install Debian 13

### Download and write the stick

Debian's netinst image, amd64, from the current release directory:

**https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/**

Take `debian-13.<x>.0-amd64-netinst.iso` (~700MB — `<x>` is the current point release; always take the newest one there). Since Debian 12 the **official** images already carry non-free firmware, so this is the right file even on hardware whose NIC needs a blob — there is no separate "unofficial firmware" image to hunt for any more.

Verify it before writing. The `SHA256SUMS` file sits in the same directory:

```powershell
# Windows, from wherever the ISO landed
Get-FileHash .\debian-13.1.0-amd64-netinst.iso -Algorithm SHA256 | Format-List
```
```bash
# Linux / macOS
sha256sum debian-13.1.0-amd64-netinst.iso
```

Compare with the matching line in `SHA256SUMS`. Then write it with **Rufus in DD Image mode**, exactly as [0.2](../setup/00-preparation.md#02-usb-stick) does for the Proxmox ISO — Rufus will ask ISO or DD when it detects the isohybrid image; DD is the answer that always boots.

### Boot the installer

**F12** at the Dell logo for the one-time boot menu (F2 is the BIOS itself — [0.1](../setup/00-preparation.md#01-bios)), then the **UEFI:** entry for the stick. Secure Boot can stay enabled; Debian ships a signed shim and installs under it without complaint. *Graphical install* and *Install* ask the same questions in the same order — pick either.

### The answers that matter

Most prompts are locale trivia. These are not:

| Prompt | Answer | Why it matters |
|---|---|---|
| Hostname | `qdevice` | What you'll see in every journal line and SSH prompt on this box |
| Domain name | leave **empty** | The lab has no DNS domain; a stray one only shows up later in confusing hostnames |
| Root password | **set one**, into the password manager | This is your way back in after [8.4](#84-ssh--key-only-from-your-pc-and-from-both-nodes) closes password login over the network. The console still accepts it |
| Normal user | create it — `devops` keeps one name across the lab | Debian insists on one. On this box it is a console/sudo fallback, **not** Ansible's `devops` identity from [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now) — nothing here is Ansible-managed |
| Network | **Configure network manually** → `192.168.0.10`, `255.255.255.0`, gateway `192.168.0.1`, DNS `192.168.0.1` | [8.3](#83-the-static-address). Doing it here costs one screen; doing it later costs a console trip |
| Partitioning | **Guided – use entire disk**, then **All files in one partition** | The WAL archive lives in `/var/lib/wal-archive` ([13.2](../ha/13-wal-stream.md#132-the-receiver-on-the-qdevice)). A separate, politely-sized `/var` is precisely the thing that fills up at 3AM while `df` on `/` still reads 4% |
| Mirror | your country's | — |
| popularity-contest | No | — |
| **Software selection** | **uncheck everything**, then tick only **SSH server** and **standard system utilities** | No desktop is the entire point. A GNOME here brings NetworkManager, an auto-suspend policy and a login screen the third vote does not need |
| GRUB | to the internal NVMe | Not the USB stick — read the device path, don't accept it by reflex |

> **Setting a root password means your normal user does *not* get sudo.** That's Debian's rule, not an oversight: leave the root password empty and the installer locks root and grants the first user sudo; set one, and it doesn't. This build sets a root password (the console fallback above), so if you want sudo as well, it's one command after first boot: `apt install -y sudo && usermod -aG sudo devops` — then log out and back in for the group to take effect.

### First boot

```bash
# the installer may leave the USB in the apt sources; it will ask you to insert media forever
sed -i '/^deb cdrom:/s/^/#/' /etc/apt/sources.list

apt update && apt full-upgrade -y
```

Then keep it patched without letting it decide when to disappear:

```bash
apt install -y unattended-upgrades
```

Debian's default configuration takes security updates and **never reboots on its own**, which is exactly right here — leave `Unattended-Upgrade::Automatic-Reboot` alone. A QDevice that reboots itself at 06:00 is the third vote vanishing with no warning and no incident to explain it; reboots on this machine are a thing you schedule, in the order from [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely).

## 8.3 The static address

If you answered *Configure network manually* above, this is already done — skip to the verification at the end.

If the box is already installed on DHCP, it's one file: a Debian netinst without a desktop runs plain `ifupdown`, no NetworkManager. **Do this at the physical console, not over SSH** — changing the address drops the session mid-edit either way.

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

Confirm from **both** nodes before going on — [8.5](#85-install-and-join) fails if either can't reach it, and a QDevice reachable from only one node is worse than none:

```bash
ping -c2 192.168.0.10
```

## 8.4 SSH — key-only, from your PC and from both nodes

Two different things need to come in over SSH, and it is worth being explicit about both, because the second one is what silently breaks [8.5](#85-install-and-join):

1. **You, from your workstation** — the same `workstation` key that opens every VM ([0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now)). One key, one identity, every machine in the lab.
2. **pve1, as root, non-interactively.** `pvecm qdevice setup` in 8.5 does not talk to some API — it opens an **SSH session to the QDevice as root** to exchange the qnetd certificates.

That second one is the trap. Debian ships `PermitRootLogin prohibit-password`, so root over SSH is never offered a password prompt at all, and `pvecm qdevice setup` fails with a permission error that says nothing about sshd. Most walkthroughs answer this by temporarily flipping `PermitRootLogin yes` and typing the root password. Don't: [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now) already generated the key that makes it unnecessary, and password login on the machine holding your third vote and your WAL archive is not a door worth opening even briefly.

### Which public halves go on this box

Four of the five, into **root's** `authorized_keys`:

| Key | Why it's here |
|---|---|
| `workstation.pub` | you, from your PC — the request that started this section |
| `pve1_root.pub` | `pvecm qdevice setup` runs from pve1 as root ([8.5](#85-install-and-join)) |
| `pve2_root.pub` | so administration isn't pinned to one node, and a rebuild driven from pve2 works ([19.2](../operations/19-node-replacement.md)) |
| `breakglass.pub` | the day nothing else opens — same rule as every VM |

**`devops.pub` deliberately does not go here.** It is Ansible's identity, and Ansible owns nothing on this machine ([8.1](#81-the-box-and-its-os)); giving it root on the one box outside the playbooks' remit would be the only place in the build where that boundary leaks.

### Install them

Root can't be reached with a password yet — that's the point — so go in as the normal user, whose password login *is* still enabled at this stage, and `su -` from there.

**Windows (PowerShell):**
```powershell
$k = "$env:USERPROFILE\lab-keys"
scp "$k\workstation.pub" "$k\pve1_root.pub" "$k\pve2_root.pub" "$k\breakglass.pub" devops@192.168.0.10:/tmp/
ssh devops@192.168.0.10
```

**Linux / macOS / Git Bash:**
```bash
scp ~/lab-keys/{workstation,pve1_root,pve2_root,breakglass}.pub devops@192.168.0.10:/tmp/
ssh devops@192.168.0.10
```

Then, on the QDevice:
```bash
su -
install -d -m 700 /root/.ssh
cat /tmp/workstation.pub /tmp/pve1_root.pub /tmp/pve2_root.pub /tmp/breakglass.pub \
    > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
rm -f /tmp/*.pub
wc -l < /root/.ssh/authorized_keys      # 4
```

`>` rather than `>>` on purpose: re-running the block after a half-finished attempt gives you the same four lines instead of eight.

### Verify — before you close the door, not after

Keep your current session open and use a **second** terminal. From your workstation:

```bash
ssh root@192.168.0.10 'hostname; wc -l < /root/.ssh/authorized_keys'    # qdevice, 4
```

The first connection asks you to accept the host key. Compare it against what the machine itself reports, at the console:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Then the check that actually predicts whether 8.5 will work — **from both nodes**, as root:

```bash
ssh -o BatchMode=yes root@192.168.0.10 true && echo OK
```

`BatchMode=yes` disables every interactive prompt, so this succeeds only on genuine key authentication. If it prints `OK` from pve1, `pvecm qdevice setup` will go through; if it hangs or errors, fix it here rather than debugging it inside a cluster command. Run it from pve2 as well and accept that host key too, so the node-replacement path in [19.2](../operations/19-node-replacement.md) doesn't stall on a fingerprint prompt at the worst possible moment.

### Close password login

Same file name the VMs use ([21.4](../operations/21-credentials.md)) — one dialect across the lab:

```bash
cat > /etc/ssh/sshd_config.d/99-key-only.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

sshd -t                 # syntax check FIRST — a typo here locks you out of a running box
systemctl restart ssh
```

`sshd -t` is not optional politeness: sshd refuses to start on a malformed config, and the machine you're locking yourself out of is a laptop that may well be in another room. The root password from 8.2 remains valid **at the console**, which is what keeps this recoverable.

> On trixie, sshd is socket-activated. `systemctl is-enabled ssh.socket` tells you; if it says `enabled`, then `Port` and `ListenAddress` come from the socket unit and editing them in `sshd_config` does nothing. Irrelevant for the three settings above — they're read by sshd itself — but it's the reason a port change on this box appears to be ignored.

Re-verify from your workstation in a second terminal before logging out of the first: `ssh root@192.168.0.10 true`.

## 8.5 Install and join

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

If this errors on SSH rather than on corosync, it's [8.4](#84-ssh--key-only-from-your-pc-and-from-both-nodes) — go back and make `ssh -o BatchMode=yes root@192.168.0.10 true` print `OK` from pve1 first.

## 8.6 It's a laptop — Stage 3 applies here too

[Stage 3](../setup/03-laptop-node.md) is written for pve2, but **3.1 (ignore the lid, mask the sleep targets) and 3.2 (clean shutdown at 10% battery) are just as mandatory here** — run them now, on this box. Skip 3.1 and closing the lid suspends the machine: the cluster silently drops to two votes and `pg-receivewal` stops, with nothing on fire to tell you. 3.3 (TLP + the dynamic governor) is optional on a machine this idle; TLP alone is harmless if you want it, the load-driven governor script is aimed at a hypervisor and has no work to do here.

The battery is a real advantage over the mini PC that usually fills this role: a power cut no longer takes the third vote with it, and the QDevice becomes the *last* of the three machines to shut down — see the [4.4](../setup/04-ups.md#44-the-long-outage-timeline-end-to-end) timeline.

## 8.7 Firmware baseline

Give it the same firmware baseline the nodes got in [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) — it's a full third of the cluster's quorum, not an accessory:

```bash
apt install -y intel-microcode fwupd    # stock Debian repos already carry both
fwupdmgr get-devices                    # a Dell should list System Firmware here (16.3)
```

Dell publishes its business hardware to LVFS, so unlike the generic mini PC that usually fills this role, the QDevice reports its own BIOS state daily through [`cluster-health`](../scripts/README.md) and `fwupdmgr update` is the normal route when a flash is actually warranted. All three machines being LVFS-covered is what makes [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely)'s *detect always, flash rarely* policy cheap to run — and the QDevice stays the machine you flash **first** when a firmware round comes: with both nodes up, losing it for a reboot still leaves the cluster quorate.
