# Stage 10 — The VMs

*Part of the [Proxmox homelab guide](../README.md).*

All via cloning. **The short way:** [`create-vms`](../scripts/README.md) (run on pve1) does this entire stage's hypervisor side in one attended run — clone, CPU/RAM, static IP, disk growth, start-at-boot, in the right order, from the same table below. It skips VM IDs that already exist, so it also finishes an interrupted run or recreates missing VMs after a disaster.

```bash
# installed by Stage 2.4, so it works from anywhere:
create-vms

# or straight from the repo clone, if the helper scripts aren't installed yet:
cd /root/src/portable-dotnet-architecture/proxmox-homelab/scripts
./create-vms.sh
```

Read on anyway: the table is the specification (script and table are kept in sync — change one, change the other), and the manual path is what you fall back to when you want to deviate from it.

**The manual way** — for each VM: right-click on **9000** → **Clone**, and in the dialog:

| Field | Value |
|---|---|
| Target node | `pve1` (rebalance later if you want) |
| VM ID / Name | from the table below |
| Mode | **Full Clone** — linked clones can't migrate off the node |
| Target Storage | from the table below |

Then adjust each clone **before its first boot** — the IP especially, because a clone that boots once on DHCP tends to stay there ([First boot](#first-boot--confirm-each-vm-took-its-static-ip)):
- **Hardware → Memory / Processors** → values below (CPU **Type stays `x86-64-v3`**, inherited)
- **Cloud-Init → IP Config (net0) → Edit** → static IP + gateway below
- **Options → Start at boot / Start/Shutdown order** → last column below ([why](#start-at-boot--what-comes-back-after-a-node-reboot))
- Start the VM, then log in **from pve1**: `ssh devops@<its-IP>`. It won't work from your workstation yet, and that's expected — [SSH access](#ssh-access--key-only-from-the-first-boot) explains why and fixes it

| VM ID | Name | Storage | CPU | RAM | Disk | IP (Cloud-init) | Start at boot |
|---|---|---|---|---|---|---|---|
| 1020 | control-ubuntu | `apps` | 2 | 4 GiB | 32G — as cloned | 192.168.0.20/24, gw .1 | no |
| 1021 | app-ubuntu | `apps` | 8 | 8 GiB | **128G** | 192.168.0.21/24, gw .1 | `order=2` |
| 1022 | postgres-ubuntu | **`db`** | 8 | 32 GiB | **640G** | 192.168.0.22/24, gw .1 | `order=1,up=60` |
| 1023 | monitoring-ubuntu | `apps` | 2 | 4 GiB | **320G** | 192.168.0.23/24, gw .1 | `order=3` |

1023 is the fourth, last VM: Loki + Grafana, wired up in [Stage 11](11-bootstrap.md#117-the-monitoring-vm-1023--loki--grafana). Its 320G looks generous next to 1020's 32G for the same CPU/RAM — but the `apps` pool is thin-provisioned ([Stage 6.1](../cluster/06-zfs-pools.md#61-thin-provisioning--set-it-before-any-vm-disk-exists)), so a big declared ceiling costs nothing until logs actually fill it. Cheap headroom now beats a `qm resize` interruption later.

> ⚠️ Under Hardware → Processors, the type stays **x86-64-v3** (inherited from the template). Do NOT change it to `host` — the VM would no longer migrate safely between the two nodes.

## Grow the disk — per VM

Every clone arrives with the template's 32GB floor. Each VM is then grown to the size *it* needs, which is why the template stays small: clones grow, never shrink, so a generous template would be a ceiling imposed on every VM you ever create ([9.3](09-ubuntu-template.md#93-create-the-vm-shell-around-it)).

One command per VM, from the Proxmox Shell — **before the first start** (`create-vms` has already done these if you took the short way):

| VM | Target | Command |
|---|---|---|
| 1020 control | 32G | — nothing to do, the clone is already right |
| 1021 app | 128G | `qm resize 1021 scsi0 128G` |
| 1022 postgres | 640G | `qm resize 1022 scsi0 640G` |
| 1023 monitoring | 320G | `qm resize 1023 scsi0 320G` |

Absolute sizes, not `+N`: the target is what it is regardless of what the template happens to be, so these lines stay correct if the template is ever rebuilt at a different size. Grow-only — ZFS-backed disks cannot be shrunk, in Proxmox or anywhere else. (`qm` sizes are binary: `640G` is 640 × 1024³.)

**The guest side happens by itself.** The cloud image's root sits on a plain partition, and cloud-init's `growpart` module runs at **every** boot — the first boot finds the bigger disk and grows the partition and filesystem into it. Nothing to run inside the guest, nothing to remember on VM number four; `df -h /` after boot is the proof, and the smoke test in [9.6](09-ubuntu-template.md#96-verify-before-you-build-on-it) already validated the mechanism. (Resized a disk while the VM was running? It's picked up on the next reboot.) This is also why [Stage 11](11-bootstrap.md#114-vaultyml-and-mainyml) sets `grow_root_filesystem: false`: the `common` role's growth chain exists for LVM layouts, and there's no LVM here to grow.

**ISO-alternative layouts only** ([9.8](09-ubuntu-template.md#98-the-alternative-interactive-iso-install)): there the root *is* on LVM, cloud-init can't grow it, and the `common` role does it on every playbook run — keep `grow_root_filesystem: true` and see [9.8g](09-ubuntu-template.md#98-the-alternative-interactive-iso-install) for the manual chain.

## Start at boot — what comes back after a node reboot

Proxmox's default for every new VM is `onboot: 0`. Shut a node down with its VMs running, power it back on, and they stay stopped — the node comes up, the guests don't, and nothing in the cluster contradicts that default. HA ([Stage 15](../ha/15-ha.md)) is the only other thing that starts a guest on its own, and it deliberately covers 1021 and 1022 only, so without this step a planned reboot leaves monitoring off until you happen to notice.

One command per VM. Unlike the resize above these can be run at any time, on a running VM too — they take effect at the next boot (`create-vms` sets them at creation):

```bash
qm set 1022 --onboot 1 --startup order=1,up=60   # postgres first…
qm set 1021 --onboot 1 --startup order=2         # …then the app that depends on it
qm set 1023 --onboot 1 --startup order=3
qm set 1020 --onboot 0                           # control stays manual — the default, stated explicitly

qm config 1022 | egrep 'onboot|startup'          # the proof, per VM
```

`order` is the sequence within one node; `up=60` is the pause *after* 1022 before the next one is started — enough for Postgres to finish crash recovery and start listening, so the app doesn't spend its first minute retrying a closed port. (There's a matching `down=` for shutdown; the default is fine.)

**1020 stays out, deliberately** — the same reasoning as [15.1](../ha/15-ha.md#151-which-vms-get-ha): the control VM serves no users, and it's the one you start when you need Ansible. That's this guide's choice, not a constraint; `--onboot 1` if you'd rather always have it.

**On 1021 and 1022 the flag is a safety net, not the mechanism.** The boot-time `startall` skips HA-managed guests on purpose — the HA stack owns them and starts them as soon as the node is quorate, whatever `onboot` says. Setting it anyway costs nothing and covers the two windows HA doesn't: before Stage 15 exists (which is most of this build), and after a VM is ever taken back out of HA.

**Quorum comes first, for both mechanisms.** A node that boots alone — other node down *and* QDevice down — holds 1 of 3 votes, `/etc/pve` stays read-only, and it starts nothing at all, `onboot` or HA. A node that reboots back empty is either this or the missing flag; [`pvecm status`](../ha/18-failover.md#185-emergency-forcing-quorum) tells you which within seconds.

The two mechanisms then differ in how they handle *arriving early*, which matters after a whole-lab power return ([4.4](../setup/04-ups.md#44-the-long-outage-timeline-end-to-end)) when all three machines race to boot: the HA stack keeps reconciling, so it starts its VMs the moment quorum forms, while `startall` runs **once** — a node quorate ten seconds too late leaves 1023 stopped for good. If you ever see that, give the vote time to arrive:

```bash
pvesh set /cluster/options --startall-onboot-delay 60     # datacenter-wide, seconds
```

**It cannot start a stale copy.** A node only autostarts the guests it owns, and after a migration the config lives under the *other* node's `/etc/pve/nodes/<node>/qemu-server/` — so the returning-node rule in [16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) still holds: nothing here can bring up a two-week-old replica behind your back.

## First boot — confirm each VM took its static IP

The address in the **Cloud-Init** tab is what the hypervisor *offers*. It is never a reading from the guest, so it keeps showing `192.168.0.20/24` whether or not the VM ever accepted it — which is exactly what makes the common failure here so quiet: the VM boots, your router hands it a DHCP lease, you reach it on that address, and the UI looks perfectly correct the whole time.

Ask the guest instead. From pve1:

```bash
qm agent 1020 network-get-interfaces      # the guest's own addresses, via the agent from 9.2
qm cloudinit dump 1020 network            # what the guest is actually being told at boot
qm config 1020 | egrep 'ide2|ipconfig0'   # the two settings that make the above possible
```

`qm config` should show both `ide2: <storage>:vm-1020-cloudinit,media=cdrom` and `ipconfig0: ip=192.168.0.20/24,gw=192.168.0.1`. The Summary page's IP row is the same guest-agent reading as the first command, if you'd rather click than type. No agent answer at all (`QEMU guest agent is not running`) usually means the VM is still booting — give it a minute before concluding anything.

**Symptom A — the guest reports a DHCP address.** Something in `192.168.0.100+`, or whatever your router's pool is, instead of the table's address. The guest never applied its network config, for one of three reasons:

- **It booted at least once before the IP was set.** The big one, and the reason both paths above insist on *before the first start*. Cloud-init applies network configuration for a **new instance**, not on every boot: the first boot renders `/etc/netplan/50-cloud-init.yaml`, and later boots simply reuse it. Proxmox derives the NoCloud `instance-id` from a digest of the cloud-init data it generates, so editing `ipconfig0` usually *does* make the next boot look like a new instance and re-render — usually, not always, which is why the fix below clears the guest's state rather than trusting a reboot.
- **The cloud-init drive is missing.** A hand-made clone with `ide2` absent has no datasource at all; cloud-init then falls back to its built-in default, which is DHCP on the first NIC. `create-vms` can't produce this, the clone dialog can.
- **Cloud-init never ran to completion.** `cloud-init status --long` inside the guest says `error` or `running`; `sudo cloud-init analyze show` and `/var/log/cloud-init.log` say why.

**Symptom B — the guest reports the right address, but you can't reach it.** The config worked; the network doesn't:

- **Your LAN isn't `192.168.0.0/24`.** The guide hard-codes that range everywhere — vmbr0 in [5.1](../setup/05-network.md#51-management-network--vmbr0-on-the-onboard-nic), the gateway, this table, and the `GATEWAY` + IP column in [`create-vms`](../scripts/README.md). If your router serves `192.168.1.0/24`, a VM sitting on `192.168.0.21` is on a subnet nobody routes. Check with `ip -br a` on pve1 and adapt *all* of them together — the script warns about this mismatch before it creates anything.
- **`.20–.23` overlap the router's DHCP pool.** Two machines end up claiming one address, and which one answers depends on the ARP race. Reserve or exclude `.11`, `.12` and `.20–.23` in the router's DHCP settings — worth doing even when nothing is broken yet.

**Fixing it.** At this stage the VMs are empty, so the honest answer is usually the fastest one — destroy and recreate, with the IP set before the first boot this time:

```bash
qm stop 1020 && qm destroy 1020 && create-vms      # recreates only what's missing
```

For a VM that already has work in it, force the guest to treat the next boot as a first boot. Fix the hypervisor side, then clear the guest's rendered state — over the DHCP address it currently answers on, or through `qm terminal 1020` (serial console, `Ctrl+O` to exit) if you can't reach it at all:

```bash
# on pve1
qm set 1020 --ipconfig0 ip=192.168.0.20/24,gw=192.168.0.1
qm cloudinit update 1020

# in the guest
sudo cloud-init clean --logs
sudo rm -f /etc/netplan/50-cloud-init.yaml
sudo reboot
```

`cloud-init clean` wipes `/var/lib/cloud`, so the next boot re-runs every per-instance module — user, SSH keys, growpart, networking. That's the point, and it's harmless on a machine that hasn't been customised by hand. Your SSH session dies with the old address; come back on the new one.

## SSH access — key-only from the first boot

Canonical's cloud image ships `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` containing `PasswordAuthentication no`. That's a property of the image, not something this guide configures, and it applies from the first second the VM is up — well before Ansible's `common` role pins the same setting in [21.4](../operations/21-credentials.md#214-the-console-is-the-final-safety-net--give-it-a-password). So:

- **`ssh devops@<ip>` with a password never works.** Not the `--cipassword`, not anything. You get `Permission denied (publickey)`, and no prompt at all.
- **The `--cipassword` is still real** — it's the console login, typed into the Proxmox **Console** tab or `qm terminal <id>`. That's the whole recovery path it exists for ([21.4](../operations/21-credentials.md#214-the-console-is-the-final-safety-net--give-it-a-password)), and it is untouched by any of this.
- **The only key that opens a fresh clone is the one `--sshkeys` put on the template** at [9.4](09-ubuntu-template.md#94-cloud-init-defaults) — in this guide, pve1's root key. Nothing else has been authorized yet, because nothing else existed yet.

Which makes the first login a hypervisor login. From pve1's shell, as root, its own key is already the right one:

```bash
ssh devops@192.168.0.20        # works from pve1, and only from pve1
```

### From your workstation

Three ways, in the order worth trying:

**1. Authorize your own key** — the one that pays off, because it also fixes every future clone. Keep one file on pve1 holding every public key that should reach the VMs:

```bash
# on pve1
cat /root/.ssh/id_ed25519.pub > /root/.ssh/vm_keys.pub
cat >> /root/.ssh/vm_keys.pub          # paste your workstation's id_ed25519.pub, then Ctrl-D
chmod 600 /root/.ssh/vm_keys.pub

qm set 9000 --sshkeys /root/.ssh/vm_keys.pub     # future clones are born with both keys
qm set 1020 --sshkeys /root/.ssh/vm_keys.pub     # an existing VM: applies at the next boot
qm reboot 1020
```

The reboot is doing the same per-instance work as the IP above — the key list is user-data, changing it changes the instance-id, and the next boot re-applies it. If a VM stubbornly refuses to pick the new key up, `sudo cloud-init clean --logs && sudo reboot` from inside forces it. Don't have a key on the workstation yet? `ssh-keygen -t ed25519` — on Windows too, PowerShell ships OpenSSH; the pair lands in `%USERPROFILE%\.ssh\`.

**2. Two hops, no changes.** The Proxmox hosts *do* accept passwords, so `ssh root@192.168.0.11` and then `ssh devops@192.168.0.20` from there works right now. Note that `ssh -J root@192.168.0.11 devops@192.168.0.20` does **not** — ProxyJump tunnels the connection but still authenticates you to the VM with *your* key, which isn't authorized there yet.

**3. Copy pve1's private key to your workstation.** Instant, and the one to think twice about: that key opens every VM in the lab, so moving it around widens the blast radius of a stolen laptop. [21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives) calls it the skeleton key for exactly this reason. If you do it, `ssh -i <path> devops@192.168.0.20`, and on Windows expect OpenSSH to reject a key file whose permissions are too open — `icacls key /inheritance:r /grant:r "$env:USERNAME:R"` fixes it.

## Control node — Ansible

On control-ubuntu (192.168.0.20):
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip jq bash-completion python3 python3-pip python3-venv pipx openssh-client sshpass
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
pipx ensurepath
pipx install --include-deps ansible
ansible --version
```

## SSH keys — control-ubuntu → the other three

Ansible runs from 1020 and logs into 1021/1022/1023 as `devops`, so the control VM needs its own key authorized on the other three. The usual `ssh-copy-id` **cannot do this here**: it authenticates with a password to install the key, and [password authentication is off from the first boot](#ssh-access--key-only-from-the-first-boot). Nothing on 1020 opens 1021 yet, so the key has to be delivered by something that already has access — pve1.

**1. Generate the key on control-ubuntu (1020):**
```bash
test -f ~/.ssh/id_ed25519_devops || ssh-keygen -t ed25519 -C "devops" -f ~/.ssh/id_ed25519_devops
scp ~/.ssh/id_ed25519_devops.pub root@192.168.0.11:/tmp/     # pve1 accepts its root password
```

**2. Install it from pve1**, whose root key already opens all three:
```bash
# on pve1, as root
for ip in 21 22 23; do
  ssh -o StrictHostKeyChecking=accept-new "devops@192.168.0.$ip" \
    'install -d -m 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' \
    < /tmp/id_ed25519_devops.pub
done

cat /tmp/id_ed25519_devops.pub >> /root/.ssh/vm_keys.pub     # so future clones are born with it
qm set 9000 --sshkeys /root/.ssh/vm_keys.pub
```

The last two lines are what turns this into a one-time chore: a clone created after them already trusts the control VM, and this whole section becomes a no-op for VM number five. (Running step 2 twice just appends a duplicate line — harmless, and Stage 11 rewrites the file declaratively anyway.)

**3. Verify from control-ubuntu**, and make the key the default for this subnet so you don't type `-i` forever:
```bash
cat >> ~/.ssh/config << 'EOF'
Host 192.168.0.2?
    User devops
    IdentityFile ~/.ssh/id_ed25519_devops
EOF
chmod 600 ~/.ssh/config

ssh devops@192.168.0.21 hostname
ssh devops@192.168.0.22 hostname
ssh devops@192.168.0.23 hostname
```

Three hostnames, no prompts. Four empty machines, reachable and key-authenticated — [Stage 11](11-bootstrap.md) fills them, and from its first run [Ansible owns `authorized_keys`](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring): add keys to `ansible_ssh_extra_public_keys`, not by hand.
