# Stage 9 — Ubuntu template with cloud-init (on pve1)

*Part of the [Proxmox homelab guide](../README.md).*

The goal: one golden image, cloned four times. Every VM then differs only in CPU/RAM/disk/IP, which cloud-init injects at first boot. Build it **once, on pve1** — clones can target either node.

The template is built from **Canonical's cloud image**, not the installer ISO. The cloud image is purpose-built for exactly this job: it ships generalized (no machine-id, no SSH host keys), cloud-init is pre-wired, and the root filesystem grows itself into whatever disk each clone gets. The interactive-ISO route achieves the same result by installing normally and then *undoing* what the installer did — every one of those undo steps is listed in [9.8](#98-the-alternative-interactive-iso-install), and their absence here is the reason this is the primary path: fewer manual steps means fewer steps that can silently break on the next Ubuntu release.

## 9.1 Get the image

**Get the ISO.** **Datacenter → pve1 → local → ISO Images → Download from URL**, URL: https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img. Confirm the filename: `ls /var/lib/vz/template/iso`.

On pve1's shell:

```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img
wget https://cloud-images.ubuntu.com/releases/26.04/release/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing    # expect: ubuntu-26.04-server-cloudimg-amd64.img: OK
```

The `releases/<version>/release/` path always holds the current build of that LTS — same image Canonical publishes to the clouds.

## 9.2 Inject the guest agent

The one thing the image lacks is `qemu-guest-agent` — and the guide leans on it everywhere: graceful shutdowns, the guest IP in the UI, filesystem freeze during snapshot backups ([17.3](../backup/17-backup-restore.md#173-the-scheduled-job)), boot-proof in [`restore-drill`](../scripts/README.md). Inject it into the image offline — nothing gets booted:

```bash
apt install -y libguestfs-tools
virt-customize -a /var/lib/vz/template/iso/ubuntu-26.04-server-cloudimg-amd64.img \
  --install qemu-guest-agent \
  --truncate /etc/machine-id
```

The `--truncate /etc/machine-id` comes **last and is not optional**: package installation runs the guest's maintainer scripts inside virt-customize's appliance, and those can leave a *generated* machine-id behind. Baked into the template, one machine-id would be shared by every clone — same DHCP lease, confused journals; the exact trap the ISO route has to clear by hand ([9.8e](#98-the-alternative-interactive-iso-install)). Operations run in the order given on the command line, so the truncate undoes whatever the install left there.

No `systemctl enable` is needed for the agent, in the image or ever: its unit is static, started at each boot by a udev rule the moment the virtio port appears.

## 9.3 Create the VM shell around it

```bash
qm create 9000 \
  --name ubuntu-template \
  --ostype l26 \
  --memory 4096 \
  --sockets 1 \
  --cores 4 \
  --net0 virtio,bridge=vmbr0 \
  --machine q35 \
  --scsihw virtio-scsi-single \
  --cpu x86-64-v3 \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0

qm set 9000 --scsi0 apps:0,import-from=/var/lib/vz/template/iso/ubuntu-26.04-server-cloudimg-amd64.img,discard=on,ssd=1,iothread=1
qm set 9000 --boot order='scsi0'
qm disk resize 9000 scsi0 32G
```

What each choice buys you:

| Flag | Why |
|---|---|
| `--cpu x86-64-v3` | **The migration-critical one.** Both CPUs support it; `host` would expose Raptor Lake / Arrow Lake differences and crash a migrated VM |
| `--scsihw virtio-scsi-single` + `iothread=1` | Each disk gets its own I/O thread — matters for the Postgres clone |
| `discard=on,ssd=1` | TRIM passthrough so deleted blocks are returned to the ZFS pool; `ssd=1` tells the guest it's flash. Requires the thin provisioning from [6.1](../cluster/06-zfs-pools.md#61-thin-provisioning--set-it-before-any-vm-disk-exists) — on a thick zvol it's a no-op |
| `--agent enabled=1` | Lets Proxmox talk to the agent injected in 9.2 |
| `--machine q35` | Modern chipset; Proxmox pins the machine *version* on first start, which is exactly what keeps live migration safe across host upgrades |
| `--serial0 socket --vga serial0` | Cloud images come with the serial console configured, so the xterm.js console works out of the box. (On an ISO-installed Ubuntu this same flag blanks the screen — that trap belongs to [9.8](#98-the-alternative-interactive-iso-install)) |
| `resize … 32G` | Deliberately the smallest disk any VM needs — see below |

**On the 32GB size — it's a floor, not an estimate.** Clones can only ever *grow*, never shrink, so the template has to be the smallest disk any VM will need. `control-ubuntu` runs on exactly this and is never resized; everything else is grown to its own target in [Stage 10](10-vms.md#grow-the-disk--per-vm).

Sizing the template generously *looks* free — thin provisioning means unwritten space costs nothing on the pool — but it hands every future VM a ceiling it never asked for, and the figure can only ever ratchet upward. A monitoring VM that wants 320GB and a control VM that wants 32GB cannot both be served by one inherited number. Per-VM growth costs one command at the hypervisor and nothing inside the guest (the image grows its own root at boot); a too-large template costs you the choice permanently. Going *below* 32GB is where it gets uncomfortable: apt caches and journals fill a small root faster than you'd like. And if you ever do need to resize the template itself: `qm resize 9000 scsi0 <size>` — absolute, grow-only, done before converting to a template.

## 9.4 Cloud-init defaults

```bash
qm set 9000 --ide2 apps:cloudinit && \
qm set 9000 --ipconfig0 ip=dhcp && \
qm set 9000 --ciuser devops && \
qm set 9000 --nameserver 192.168.0.1 && \
qm set 9000 --searchdomain lan
```

At each clone's first boot, cloud-init creates the `devops` user with passwordless sudo (default-user semantics), sets the IP you give it in the Cloud-Init tab, and grows the root filesystem into the clone's disk — that's Stages 10 and 11 relying on template behavior configured right here.

**SSH key instead of passwords** — do this now and every clone comes up key-only:
```bash
# on pve1, if you don't already have a key:
test -f /root/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519

# ...or, if this pair already exists (a previous build, or your password
# manager if you keep a copy there), restore it instead of generating:
#   mkdir -p /root/.ssh && chmod 700 /root/.ssh
#   echo '-----BEGIN OPENSSH PRIVATE KEY...' > /root/.ssh/id_ed25519
#   echo 'ssh-ed25519 AAAA...' > /root/.ssh/id_ed25519.pub
#   chmod 600 /root/.ssh/id_ed25519
#   chmod 644 /root/.ssh/id_ed25519.pub
# (no chown — on the host this key belongs to root, unlike the control VM's
#  id_ed25519_devops from native/example, which belongs to devops)

qm set 9000 --sshkeys /root/.ssh/id_ed25519.pub
```

Restoring beats regenerating whenever the pair exists: this public key is already in `authorized_keys` on every VM cloned so far, so the restored private half opens all of them immediately — a fresh pair opens nothing until it's re-seeded everywhere, and it silently invalidates the [21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives) inventory. This matters most when rebuilding pve1 after an OS-disk failure or a node replacement ([19.2 step 5](../operations/19-node-replacement.md#5-build-the-new-node) sends you through this stage), where the existing VMs and their locks are still alive.

You can add the control VM's key later too — `--sshkeys` takes a file, so append additional public keys to it and re-run the command.

**And a console password** — key-only SSH still needs a last-resort login path that doesn't depend on SSH at all. If every key is ever lost, the Proxmox console is how you get back in, and it only helps if a password exists:

```bash
qm set 9000 --cipassword '<strong password — store it in your password manager NOW>'
```

Every clone inherits it. This does **not** weaken SSH: the Ansible `common` role pins `PasswordAuthentication no` in sshd, so the password works at the console and nowhere else. The full reasoning and the recovery paths it unlocks are in [Stage 21](../operations/21-credentials.md#stage-21--credentials--key-management).

## 9.5 Convert to template

```bash
qm template 9000
```

Irreversible: 9000 can no longer be started or edited as a VM. Everything from here is clones.

Optional but cheap insurance — back the template up once, so a future rebuild is a restore instead of redoing all of Stage 9:
```bash
vzdump 9000 --storage usb-backup --compress zstd     # after Stage 17.2 sets up the drive
```

## 9.6 Verify before you build on it

```bash
qm config 9000 | egrep 'cpu|scsi0|ide2|agent|template|ciuser'
```

Expected: `cpu: x86-64-v3`, `scsi0: apps:...`, `ide2: apps:...cloudinit,media=cdrom`, `agent: 1`, `template: 1`, `ciuser: devops`.

Then a throwaway smoke test, because catching a broken template now saves rebuilding four VMs later:
```bash
qm clone 9000 999 --name smoke-test --full --storage apps
qm set 999 --ipconfig0 ip=192.168.0.99/24,gw=192.168.0.1
qm start 999
```

Four things to check, each proving a different part of the template:

| Check | Proves |
|---|---|
| `ssh devops@192.168.0.99` logs in with your key | cloud-init took the static IP *and* seeded the key — not DHCP, not password |
| The Proxmox summary page shows the VM's IP | the guest agent from 9.2 is alive |
| `df -h /` inside shows ~31G | the root grew itself into the 32G disk at boot — the mechanism [Stage 10](10-vms.md#grow-the-disk--per-vm) relies on for every clone |
| `qm terminal 999` gives a login prompt | the serial console works (`--vga serial0`) |

Then:
```bash
qm stop 999 && qm destroy 999
```

## 9.7 Cluster note

The template lives on pve1's local `apps` pool, so it exists only on pve1 — that's fine. In the clone dialog, **Mode: Full Clone** lets you pick either node as target; Proxmox streams the disk across for you. Linked clones can't leave the node, which is one more reason Stage 10 uses full clones throughout.

If you'd rather have the template available locally on both nodes, just clone it to pve2 once and run `qm template` on the copy — but there's little to gain.

## 9.8 The alternative: interactive ISO install

Use this route only when the primary one doesn't fit — no direct internet from pve1 (an ISO can arrive on a stick), or you specifically want to drive partitioning by hand. It produces an equivalent template; the cost is ~15 interactive minutes plus every generalization step the cloud image ships already done. These steps are also the fragile part: the subiquity filenames in (d) have changed across Ubuntu releases before, and the failure mode — clones silently ignoring their static IP — surfaces late.

**a) Get the ISO.** **Datacenter → pve1 → local → ISO Images → Download from URL**, from https://ubuntu.com/download/server. Confirm the filename: `ls /var/lib/vz/template/iso`.

**b) VM shell.** As in 9.3, with three differences: the disk is created empty (`apps:32` instead of the import), the ISO goes in the CD drive, and **no `--vga serial0`** — the ISO's Ubuntu has no serial console until (d), so that flag would leave you staring at a blank screen:

```bash
qm create 9000 --name ubuntu-template --ostype l26 --memory 4096 \
  --sockets 1 --cores 4 --net0 virtio,bridge=vmbr0 --machine q35 \
  --scsihw virtio-scsi-single --cpu x86-64-v3 --agent enabled=1 \
  --scsi0 apps:32,discard=on,ssd=1,iothread=1 \
  --cdrom local:iso/ubuntu-26.04-live-server-amd64.iso \
  --boot order='scsi0;ide2'
```

**c) Install Ubuntu.** Console → ESC at the boot prompt → pick the DVD/CD entry. The answers:

| Screen | Answer |
|---|---|
| Language / Keyboard | English → Done |
| Type of install | Ubuntu Server (not minimized) → Done |
| Network | Leave DHCP → Done |
| Proxy / Mirror | Done → Done |
| Guided storage | Keep **Use an entire disk** + **Set up this disk as an LVM group** → Done |
| Storage configuration | See the LVM note below → Done → **Continue** on the destructive-action warning |
| Profile | name `devops`, server `devops`, user `devops`, password `devops` |
| Ubuntu Pro | Skip |
| SSH | ✔ **Install OpenSSH server** |
| Snaps | Done |

> **Claim the whole volume group.** The installer gives the root logical volume only about *half* the VG by default — a 32GB disk ends up carrying a 15GB root. On the **Storage configuration** screen select `ubuntu-lv` → **Edit** → retype **Size** as the figure from the `(max …)` label **including the `G` suffix** (a bare number is read as bytes and silently clamped); leave **Format** on `ext4` (the growth chain uses `resize2fs`) and everything else untouched.

Reboot when it finishes, log in at the console, `ip a` for the DHCP address, then SSH in and `sudo -i`.

**d) Prepare the guest:**

```bash
apt update && apt upgrade -y
apt install -y qemu-guest-agent cloud-init cloud-guest-utils sudo curl wget bash-completion
systemctl start qemu-guest-agent
```

> `start`, not `enable --now`. `qemu-guest-agent.service` is a **static** unit — no `[Install]` section, nothing to enable: a udev rule starts it at every boot once the virtio port appears. `systemctl enable` on it fails with *"The unit files have no installation config"*, and because `--now` runs the enable first, the service doesn't get started either. `systemctl is-enabled <unit>` printing `static` is the tell.

Undo the installer's cloud-init lockdown — **do not skip this**, or every clone ignores the IP from the Cloud-Init tab and silently comes up on DHCP:

```bash
rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg
rm -f /etc/cloud/cloud.cfg.d/99-installer.cfg
rm -f /etc/netplan/00-installer-config.yaml
rm -f /etc/cloud/cloud-init.disabled
```

And configure the serial console (the cloud image has this out of the box):

```bash
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200"/' /etc/default/grub
sed -i 's/^#\?GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' /etc/default/grub
update-grub
```

**e) Generalize** — strip everything that must be unique per clone (shared machine-id = same DHCP lease everywhere; shared host keys = identical fingerprints on every VM):

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

Shut it down **from the Proxmox shell** (a guest reboot would regenerate what you just stripped): `qm shutdown 9000`.

**f) Cloud-init drive** — swap the CD for the cloud-init drive, add the serial device, but keep the default VGA (both consoles then work, thanks to the grub change in (d)):

```bash
qm set 9000 --delete ide2 && \
qm set 9000 --ide2 apps:cloudinit && \
qm set 9000 --serial0 socket && \
qm set 9000 --boot order='scsi0'
```

Then continue exactly as the primary route: the defaults, SSH key and console password from [9.4](#94-cloud-init-defaults), conversion in [9.5](#95-convert-to-template), verification in [9.6](#96-verify-before-you-build-on-it) — minus the `df -h` and serial-console rows, which work differently here (see g).

**g) The LVM consequence.** Root sits on LVM, so clones do **not** grow themselves at boot — cloud-init's `growpart` can't cross the LVM layer. Leave `grow_root_filesystem: true` in `group_vars` (the [11.4](11-bootstrap.md#114-vaultyml-and-mainyml) cloud-image delta does *not* apply to this route) and the `common` role runs the full chain on every playbook run. Before the first Ansible run, or on a VM outside the inventory, by hand:

```bash
lsblk    # confirm the layout: sda3 → ubuntu--vg-ubuntu--lv
growpart /dev/sda 3 && \
pvresize /dev/sda3 && \
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv && \
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```
