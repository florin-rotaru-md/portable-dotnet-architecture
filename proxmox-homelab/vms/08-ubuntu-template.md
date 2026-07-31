# Stage 8 — Ubuntu template with cloud-init (on pve1)

*Part of the [waa Proxmox homelab guide](../README.md).*

The goal: one golden image, cloned three times. Every VM then differs only in CPU/RAM/IP, which cloud-init injects at first boot. Build it **once, on pve1** — clones can target either node.

## 8.1 Get the ISO

**Datacenter → pve1 → local → ISO Images → Download from URL** (faster than uploading from your PC). Grab the current Ubuntu Server LTS from https://ubuntu.com/download/server — copy the download link from that page and paste it into the dialog. If you already have the ISO locally, the **Upload** button next to it does the same thing, just slower.

Confirm the exact filename — you need it verbatim in the next step:
```bash
ls /var/lib/vz/template/iso
```

## 8.2 Create the VM shell

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
qm set 9000 --cdrom local:iso/ubuntu-24.04.4-live-server-amd64.iso && \
qm set 9000 --boot order="scsi0;ide2" && \
qm set 9000 --bootdisk scsi0
```

What each choice buys you:

| Flag | Why |
|---|---|
| `--cpu x86-64-v3` | **The migration-critical one.** Both CPUs support it; `host` would expose Raptor Lake / Arrow Lake differences and crash a migrated VM |
| `--scsihw virtio-scsi-single` + `iothread=1` | Each disk gets its own I/O thread — matters for the Postgres clone |
| `discard=on,ssd=1` | TRIM passthrough so deleted blocks are returned to the ZFS pool; `ssd=1` tells the guest it's flash |
| `--agent enabled=1` | Lets Proxmox do graceful shutdowns, report the guest IP, and freeze the filesystem during snapshot backups |
| `--machine q35` | Modern chipset; Proxmox pins the machine *version* on first start, which is exactly what keeps live migration safe across host upgrades |
| `apps:32` | Small base disk on ZFS. Clones expand later (Stage 9) — never oversize the template |

## 8.3 Install Ubuntu

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

> **Keep the LVM layout** — Stage 9's postgres disk resize depends on it.

> **Claim the whole volume group.** By default the installer allocates only about *half* the VG to the root logical volume — on a 32GB disk you end up with a ~15GB root and ~15GB sitting unused inside the VG. On the **Storage configuration** screen, select `ubuntu-lv` → **Edit** → set the size to the maximum offered → Done. Do it once here and every clone inherits a fully-used disk; skip it and you're running `lvextend` + `resize2fs` in all three VMs instead.

**On the 32GB disk size:** it's a deliberate floor, not a guess. ZFS stores it sparsely, so a fresh Ubuntu consumes ~4-5GB regardless of the declared size — the number costs you nothing until it's written. Clones can only ever grow (1030 gets +608G in Stage 9), never shrink, so the template has to be the lowest common denominator. Below 32GB gets uncomfortable: at 16GB you're left with roughly 7GB of root after partitioning, which apt caches and journals fill faster than you'd like.

Reboot when it finishes, log in at the console, and find the DHCP address:
```bash
ip a
```

## 8.4 Prepare the guest

SSH in (`ssh devops@<dhcp-ip>`), then `sudo -i`.

**a) Packages and guest agent:**
```bash
apt update && apt upgrade -y
apt install -y qemu-guest-agent cloud-init sudo curl wget bash-completion
systemctl enable --now qemu-guest-agent
```

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

## 8.5 Attach the cloud-init drive and set defaults

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

Every clone inherits it. This does **not** weaken SSH: the Ansible `common` role pins `PasswordAuthentication no` in sshd, so the password works at the console and nowhere else. The full reasoning and the recovery paths it unlocks are in [Stage 18](../operations/18-credentials.md#stage-18--credentials--key-management).

> A trap worth naming: guides often add `--vga serial0` here, which blanks the graphical console on an ISO-installed Ubuntu (the installer doesn't configure a serial console). We keep the default VGA *and* add `serial0`, plus the grub change in 8.4c — so both consoles work.

## 8.6 Convert to template

```bash
qm template 9000
```

Irreversible: 9000 can no longer be started or edited as a VM. Everything from here is clones.

Optional but cheap insurance — back the template up once, so a future rebuild is a restore instead of redoing all of Stage 8:
```bash
vzdump 9000 --storage usb-backup --compress zstd     # after Stage 14.2 sets up the drive
```

## 8.7 Verify before you build on it

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
Check that it boots, takes **192.168.0.99** (not a DHCP address — that's the 8.4b check), accepts your SSH key, and reports its IP in the Proxmox summary page (that's the guest-agent check). Then:
```bash
qm stop 999 && qm destroy 999
```

## 8.8 Cluster note

The template lives on pve1's local `apps` pool, so it exists only on pve1 — that's fine. In the clone dialog, **Mode: Full Clone** lets you pick either node as target; Proxmox streams the disk across for you. Linked clones can't leave the node, which is one more reason Stage 9 uses full clones throughout.

If you'd rather have the template available locally on both nodes, just clone it to pve2 once and run `qm template` on the copy — but there's little to gain.

## 8.9 Faster alternative: the Ubuntu cloud image

If you ever rebuild the template, this route skips the 15-minute interactive install entirely — the image ships cloud-init ready, with none of the 8.4b cleanup needed:

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
qm set 9001 --cipassword '<strong password>'   # console safety net — Stage 18.4
qm disk resize 9001 scsi0 32G
qm template 9001
```

Here `--vga serial0` **is** correct: cloud images have the serial console configured. Trade-off: no `qemu-guest-agent` preinstalled, so add it via a cloud-init custom snippet or on first boot per clone.
