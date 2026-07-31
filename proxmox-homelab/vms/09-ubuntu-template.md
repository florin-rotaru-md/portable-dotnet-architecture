# Stage 9 — Ubuntu template with cloud-init (on pve1)

*Part of the [Proxmox homelab guide](../README.md).*

The goal: one golden image, cloned three times. Every VM then differs only in CPU/RAM/IP, which cloud-init injects at first boot. Build it **once, on pve1** — clones can target either node.

## 9.1 Get the ISO

**Datacenter → pve1 → local → ISO Images → Download from URL** (faster than uploading from your PC). Grab the current Ubuntu Server LTS from https://ubuntu.com/download/server — copy the download link from that page and paste it into the dialog. If you already have the ISO locally, the **Upload** button next to it does the same thing, just slower.

Confirm the exact filename — you need it verbatim in the next step:
```bash
ls /var/lib/vz/template/iso
```

## 9.2 Create the VM shell

Proxmox Shell on pve1:
```bash
qm create 9000 \
  --name ubuntu-template \
  --ostype l26 \
  --memory 4096 \
  --sockets 1 \
  --cores 4 \
  --net0 virtio,bridge=vmbr0

qm set 9000 --machine q35 && \
qm set 9000 --bios seabios && \
qm set 9000 --scsihw virtio-scsi-single && \
qm set 9000 --scsi0 apps:32,discard=on,ssd=1,iothread=1 && \
qm set 9000 --cpu x86-64-v3 && \
qm set 9000 --agent enabled=1 && \
qm set 9000 --cdrom local:iso/ubuntu-26.04-live-server-amd64.iso && \
qm set 9000 --boot order="scsi0;ide2" && \
qm set 9000 --bootdisk scsi0
```

What each choice buys you:

| Flag | Why |
|---|---|
| `--cpu x86-64-v3` | **The migration-critical one.** Both CPUs support it; `host` would expose Raptor Lake / Arrow Lake differences and crash a migrated VM |
| `--scsihw virtio-scsi-single` + `iothread=1` | Each disk gets its own I/O thread — matters for the Postgres clone |
| `discard=on,ssd=1` | TRIM passthrough so deleted blocks are returned to the ZFS pool; `ssd=1` tells the guest it's flash. Requires the thin provisioning from [6.1](../cluster/06-zfs-pools.md#61-thin-provisioning--set-it-before-any-vm-disk-exists) — on a thick zvol it's a no-op |
| `--agent enabled=1` | Lets Proxmox do graceful shutdowns, report the guest IP, and freeze the filesystem during snapshot backups |
| `--machine q35` | Modern chipset; Proxmox pins the machine *version* on first start, which is exactly what keeps live migration safe across host upgrades |
| `apps:32` | Deliberately the smallest disk any VM needs. Clones can only ever grow, so the template is the floor — each VM is then grown to its own size in [Stage 10](../vms/10-vms.md#grow-the-disk--per-vm) |

## 9.3 Install Ubuntu

**pve1 → 9000 → Console.** The disk is empty, so boot falls through to the CD: press **ESC** at the boot prompt and pick the DVD/CD entry.

Installer answers:

| Screen | Answer |
|---|---|
| Language / Keyboard | English → Done |
| Type of install | Ubuntu Server (not minimized) → Done |
| Network | Leave DHCP → Done |
| Proxy / Mirror | Done → Done |
| Guided storage | Keep **Use an entire disk** + **Set up this disk as an LVM group** → Done |
| Storage configuration | **Don't just accept it** — see the note below → Done → **Continue** on the destructive-action warning |
| Profile | name `devops`, server `devops`, user `devops`, password `devops` |
| Ubuntu Pro | Skip for now |
| SSH | ✔ **Install OpenSSH server** |
| Snaps | Done |

> **Keep the LVM layout** — [Stage 10's per-VM disk growth](10-vms.md#grow-the-disk--per-vm) depends on it, as does the Ansible role that enforces it.

> **Claim the whole volume group.** By default the installer gives the root logical volume only about *half* the VG and leaves the rest idle inside it — on a 32GB disk, a 30GB partition carrying a **15GB** root, which is the layout `native/example` documents. On the **Storage configuration** screen, select `ubuntu-lv` → **Edit**. Exactly one field changes:
>
> - **Size** → retype it as the figure from the `(max …)` label, **including the `G` suffix**. A bare number is read as *bytes*, so `320` doesn't mean 320G — the installer clamps it and the label still reads the maximum, which looks like the edit worked.
> - **Format** → leave **`ext4`**. Not a preference: Stage 10 grows the postgres filesystem with `resize2fs`, which handles ext2/3/4 only. Choose xfs here and that step fails, on a filesystem that also can't be shrunk back.
> - **Name** / **Mount** → untouched: `ubuntu-lv`, `/`.
>
> Do it here and the floor every clone starts from is 30GB instead of 15GB. That's what turns a forgotten resize into a non-event rather than a full root filesystem.

**On the 32GB size — it's a floor, not an estimate.** Clones can only ever *grow*, never shrink, so the template has to be the smallest disk any VM will need. `control-ubuntu` runs on exactly this and is never resized; everything else is grown to its own target in [Stage 10](10-vms.md#grow-the-disk--per-vm).

Sizing the template generously *looks* free — thin provisioning ([6.1](../cluster/06-zfs-pools.md#61-thin-provisioning--set-it-before-any-vm-disk-exists)) means unwritten space costs nothing on the pool — but it hands every future VM a ceiling it never asked for, and the figure can only ever ratchet upward. A logging VM that wants 320GB and a control VM that wants 32GB cannot both be served by one inherited number. Per-VM growth costs one command at the hypervisor and none inside the guest ([the playbook handles that](10-vms.md#grow-the-disk--per-vm)); a too-large template costs you the choice permanently.

Going *below* 32GB is where it gets uncomfortable: at 16GB you're left with roughly 7GB of root after partitioning, which apt caches and journals fill faster than you'd like.

> **The trap, if you ever do resize the template:** change the *disk*, not the LV, and do it before the install writes partitions. The chain is `LV ≤ VG ≤ partition ≤ virtual disk`, so typing a bigger number into the installer accomplishes nothing — the `(max …)` label doesn't move until the disk underneath it does (`qm stop 9000 && qm resize 9000 scsi0 <size>`, absolute, grow-only).

Reboot when it finishes, log in at the console, and find the DHCP address:
```bash
ip a
```

## 9.4 Prepare the guest

SSH in (`ssh devops@<dhcp-ip>`), then `sudo -i`.

**a) Packages and guest agent:**
```bash
apt update && apt upgrade -y
apt install -y qemu-guest-agent cloud-init cloud-guest-utils sudo curl wget bash-completion
systemctl start qemu-guest-agent
```

> `start`, not `enable --now`. `qemu-guest-agent.service` is a **static** unit — it has no `[Install]` section, so there is nothing to enable: a udev rule starts it at every boot as soon as the virtio serial port appears, which is exactly the condition under which it can work at all. `systemctl enable` on it fails with *"The unit files have no installation config"*, and because `--now` runs the enable first, the service doesn't get started either. The same shape applies to any static unit — `systemctl is-enabled <unit>` printing `static` is the tell.

`cloud-guest-utils` is what provides `growpart`. Every clone is grown to its own size in Stage 10, so putting it in the template means the growth step never has to `apt install` anything first — including on a VM whose disk filled up, which is exactly when apt is least likely to cooperate.

**b) Undo the installer's cloud-init lockdown — do not skip this.**

The Ubuntu ISO installer deliberately disables cloud-init's network handling after install. Leave it in place and every clone will ignore the IP you set in the Cloud-Init tab and silently come up on DHCP:

```bash
rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg
rm -f /etc/netplan/00-installer-config.yaml
rm -f /etc/cloud/cloud-init.disabled
```

(The installer's netplan file goes too — otherwise it competes with the `50-cloud-init.yaml` that cloud-init generates.)

**c) Enable the serial console** so Proxmox's xterm.js console works:
```bash
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200"/' /etc/default/grub
sed -i 's/^#\?GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' /etc/default/grub
update-grub
```

**d) Generalize — strip everything that must be unique per clone:**
```bash
apt clean && \
journalctl --rotate && \
journalctl --vacuum-time=1s && \
cloud-init clean --logs && \
rm -f /etc/ssh/ssh_host_* && \
truncate -s 0 /etc/machine-id && \
rm -f /var/lib/dbus/machine-id && \
ln -s /etc/machine-id /var/lib/dbus/machine-id && \
rm -rf /tmp/* /var/tmp/* && \
history -c && \
sync
```

> Why each removal matters: a shared `machine-id` makes clones request the *same* DHCP lease and confuses systemd journals; shared SSH host keys mean every VM presents the same fingerprint (both a security problem and a source of constant "host key changed" warnings). Both are regenerated automatically at first boot.

Shut it down **from the Proxmox shell** (don't reboot the guest after cleaning, or it regenerates what you just stripped):
```bash
qm shutdown 9000
```

## 9.5 Attach the cloud-init drive and set defaults

Proxmox Shell:
```bash
qm set 9000 --delete ide2 && \
qm set 9000 --ide2 apps:cloudinit && \
qm set 9000 --serial0 socket && \
qm set 9000 --ipconfig0 ip=dhcp && \
qm set 9000 --ciuser devops && \
qm set 9000 --nameserver 192.168.0.1 && \
qm set 9000 --searchdomain lan && \
qm set 9000 --boot order='scsi0'
```

**SSH key instead of passwords** — do this now and every clone comes up key-only:
```bash
# on pve1, if you don't already have a key:
test -f /root/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519
qm set 9000 --sshkeys /root/.ssh/id_ed25519.pub
```

You can add the control VM's key later too — `--sshkeys` takes a file, so append additional public keys to it and re-run the command.

**And a console password** — key-only SSH still needs a last-resort login path that doesn't depend on SSH at all. If every key is ever lost, the Proxmox console is how you get back in, and it only helps if a password exists:

```bash
qm set 9000 --cipassword '<strong password — store it in your password manager NOW>'
```

Every clone inherits it. This does **not** weaken SSH: the Ansible `common` role pins `PasswordAuthentication no` in sshd, so the password works at the console and nowhere else. The full reasoning and the recovery paths it unlocks are in [Stage 21](../operations/21-credentials.md#stage-21--credentials--key-management).

> A trap worth naming: guides often add `--vga serial0` here, which blanks the graphical console on an ISO-installed Ubuntu (the installer doesn't configure a serial console). We keep the default VGA *and* add `serial0`, plus the grub change in 9.4c — so both consoles work.

## 9.6 Convert to template

```bash
qm template 9000
```

Irreversible: 9000 can no longer be started or edited as a VM. Everything from here is clones.

Optional but cheap insurance — back the template up once, so a future rebuild is a restore instead of redoing all of Stage 9:
```bash
vzdump 9000 --storage usb-backup --compress zstd     # after Stage 17.2 sets up the drive
```

## 9.7 Verify before you build on it

```bash
qm config 9000 | egrep 'cpu|scsi0|ide2|agent|template|ciuser'
```

Expected: `cpu: x86-64-v3`, `scsi0: apps:...`, `ide2: apps:...cloudinit,media=cdrom`, `agent: 1`, `template: 1`, `ciuser: devops`.

Then a throwaway smoke test, because catching a broken template now saves rebuilding three VMs later:
```bash
qm clone 9000 999 --name smoke-test --full --storage apps
qm set 999 --ipconfig0 ip=192.168.0.99/24,gw=192.168.0.1
qm start 999
```
Check that it boots, takes **192.168.0.99** (not a DHCP address — that's the 9.4b check), accepts your SSH key, and reports its IP in the Proxmox summary page (that's the guest-agent check). Then:
```bash
qm stop 999 && qm destroy 999
```

## 9.8 Cluster note

The template lives on pve1's local `apps` pool, so it exists only on pve1 — that's fine. In the clone dialog, **Mode: Full Clone** lets you pick either node as target; Proxmox streams the disk across for you. Linked clones can't leave the node, which is one more reason Stage 10 uses full clones throughout.

If you'd rather have the template available locally on both nodes, just clone it to pve2 once and run `qm template` on the copy — but there's little to gain.

## 9.9 Faster alternative: the Ubuntu cloud image

If you ever rebuild the template, this route skips the 15-minute interactive install entirely — the image ships cloud-init ready, with none of the 9.4b cleanup needed:

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

qm create 9001 --name ubuntu-cloud-template --ostype l26 --memory 4096 \
  --sockets 1 --cores 4 --net0 virtio,bridge=vmbr0 --machine q35 \
  --scsihw virtio-scsi-single --cpu x86-64-v3 --agent enabled=1 \
  --serial0 socket --vga serial0

qm set 9001 --scsi0 apps:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img,discard=on,ssd=1,iothread=1
qm set 9001 --ide2 apps:cloudinit --boot order='scsi0'
qm set 9001 --ciuser devops --sshkeys /root/.ssh/id_ed25519.pub \
  --nameserver 192.168.0.1 --searchdomain lan --ipconfig0 ip=dhcp
qm set 9001 --cipassword '<strong password>'   # console safety net — Stage 21.4
qm disk resize 9001 scsi0 32G
qm template 9001
```

Here `--vga serial0` **is** correct: cloud images have the serial console configured. Trade-off: no `qemu-guest-agent` preinstalled, so add it via a cloud-init custom snippet or on first boot per clone.
