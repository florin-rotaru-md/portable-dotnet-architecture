# Proxmox Guide — waa Homelab (2 nodes, replication, live migration)

**Hardware:**
- **Node 1 `pve1`** — ThinkStation P2 Gen 2, Core Ultra 7 265, 64GB, 3× NVMe, Intel X550-T2
- **Node 2 `pve2`** — HP ZBook Fury G10 16", i9-13850HX, 64GB, 3× NVMe, Thunderbolt 4 (role: failover)
- QDevice: any always-on third device (Raspberry Pi / mini PC / VM on another system)
- ~5h UPS, router with tested 5G failover (~30s), Cloudflare Tunnel already in place

**Design decisions (differences vs the old PROXMOX-INIT.md):**

| Topic | Old (init doc) | Now | Reason |
|---|---|---|---|
| VM storage | LVM-Thin (`nvme2-thin`) | **ZFS** (`apps`, `db`) | Proxmox replication works ONLY on ZFS |
| VM CPU type | `host` | **`x86-64-v3`** | Different CPUs (Raptor Lake vs Arrow Lake) — `host` would crash a migrated VM |
| Migration network | — | 10G segment via SODOLA switch; corosync on a dedicated 1G direct link | Bandwidth for migration, quiet path for cluster heartbeat |

---

## Stage 0 — Preparation

### 0.1 BIOS

**pve1 (ThinkStation, F1 at boot):** VT-x → Enabled; VT-d → Enabled; **VMD/RST → Disabled** (otherwise Linux won't see the NVMe drives individually); Secure Boot can stay on.

**pve2 (ZBook, F10 at boot):** VT-x/VT-d → Enabled; RST/VMD → AHCI-NVMe if the option exists; also look for a "Wake on AC / Power on AC" setting → Enabled (so the laptop powers back on when power returns).

### 0.2 USB stick

Download the Proxmox VE ISO (latest 9.x): https://www.proxmox.com/en/downloads
Write it with Rufus (DD Image mode).

### 0.3 Network plan

Hardware: SODOLA/HRUI **SL-SWTGW2C80N** 10G switch (8× 10GBase-T, web managed, autonegotiating 100M/1G/2.5G/5G/10G) + Thunderbolt→10GbE adapter on pve2. The switch is *not* a router — the existing router stays the gateway.

**Two cables per host, with deliberately assigned roles:**

| Link | Cabling | Network | Role |
|---|---|---|---|
| **10G** | X550 port 1 (pve1) and TB adapter (pve2) → SODOLA switch → uplink into the existing router | 192.168.0.11 / .12 /24, gw 192.168.0.1 | `vmbr0`: management + VM traffic + migration + replication; corosync **Link 1** (backup) |
| **1G** | onboard NICs, **direct cable host-to-host** (no switch) | 10.10.10.1 / .2 /24, no gateway | corosync **Link 0** (dedicated) |

**Why corosync's primary link is the 1G direct cable, not the 10G:**
corosync needs *consistent latency*, not bandwidth (it pushes a few KB/s). A dedicated link with no other traffic and no switch in the path is ideal. Sharing it with migration and VM traffic can introduce jitter and, in extreme cases, make corosync believe the peer node died. The 10G link stays configured as Link 1, so a cut direct cable fails over instantly.

Bonus: the direct link doesn't depend on the switch. If the SODOLA dies, the cluster stays quorate and healthy — you only lose the UI and VM traffic until it's replaced. With both links through the switch, a dead switch would isolate the nodes from each other completely.

**Other notes:**
- The switch **must be on the UPS**. Otherwise it becomes a single point of failure sitting between two redundant nodes.
- Uplink to the existing router will run at 1G — that's internet-bound traffic only. VM-to-VM traffic (`app` ↔ `postgres`) stays inside the switch at 10G regardless of which node each lands on after a failover.
- Keep MTU at 1500 for now. Jumbo frames would help replication, but on a segment that also carries VM traffic and uplinks to the router, MTU mismatches cause subtle, hard-to-debug failures. Revisit only once everything is stable.
- VMs keep the addressing scheme from the init doc: `.10` control, `.20` app, `.30` postgres — all on 192.168.0.0/24.

**Fallback if the 10G gear isn't ready yet:** run everything over the 1G management network (192.168.0.x), single link, and skip Stage 4. You can add the 10G link and the second corosync link later without rebuilding anything.

### 0.4 Physical cabling — what goes where

```
                    ┌─────────────────────────┐
                    │   Existing ISP router    │  192.168.0.1
                    │  (gateway + DHCP + 5G    │
                    │   failover)              │
                    └───────────┬─────────────┘
                                │  ① Cat6a  (uplink, 1G or whatever the router has)
                                │
                    ┌───────────┴─────────────┐
                    │  SODOLA SL-SWTGW2C80N   │   ← ON THE UPS
                    │  8 × 10GBase-T          │
                    └──┬──────────────────┬───┘
                  ② Cat6a             ③ Cat6a
                       │                  │
        ┌──────────────┴───┐        ┌─────┴──────────────┐
        │  pve1            │        │  pve2              │
        │  ThinkStation    │        │  ZBook Fury G10    │
        │                  │        │                    │
        │  X550-T2 port 1 ─┘        └─ TB→10GbE adapter  │
        │  X550-T2 port 2  (unused)   (Thunderbolt 4 port)│
        │                  │        │                    │
        │  onboard 1G ─────┼── ④ ───┼───── onboard 1G    │
        └──────────────────┘        └────────────────────┘
                         ④ Cat5e/6, DIRECT, no switch
```

**Cable checklist:**

| # | From | To | Type | Purpose |
|---|---|---|---|---|
| ① | SODOLA, any port | Existing router LAN port | Cat6a | Internet / rest of the home network |
| ② | pve1 — X550-T2 **port 1** | SODOLA, any port | Cat6a | `vmbr0`: management, VM traffic, migration, replication, corosync Link 1 |
| ③ | pve2 — Thunderbolt→10GbE adapter (in a **TB4** port) | SODOLA, any port | Cat6a | Same as ② |
| ④ | pve1 — **onboard** 1G RJ45 | pve2 — **onboard** 1G RJ45 | Cat5e or better | corosync Link 0 only — direct, no switch in between |

**Power:** SODOLA switch, pve1, and the QDevice all go on the UPS. pve2 (the ZBook) can go on the UPS too, but its own battery already covers it.

**Notes on the physical side:**
- **X550-T2 port 2 stays empty.** Leave it for a future third node or an LACP pair — no reason to use it now.
- **Which TB4 port on the ZBook:** either one works; prefer the one not shared with your dock/charger if you use one, to reduce contention. Plug the adapter in *before* booting the Proxmox installer so it's detected during install.
- **Cable ④ needs no crossover cable.** Both NICs do Auto MDI/MDIX, so a regular patch cable works. Any leftover Cat5e is fine — corosync uses a few KB/s.
- **Label the cables.** At 3AM during an incident, "which one is the corosync cable" is not a question you want to answer by tracing.
- **Don't plug the onboard NICs into the switch.** That would put both corosync links behind the same device and defeat the redundancy the second cable exists for.
- **Cat6a for ①②③** — Cat5e technically negotiates 10G only over very short runs; Cat6a is cheap and removes the doubt.

---

## Stage 1 — Proxmox installation (identical on both nodes)

1. Boot from the stick → **Install Proxmox VE (Graphical)** → accept the EULA.
2. **Target Harddisk: disk 1 (OS).** Careful not to pick the data disks. Default filesystem (ext4/LVM).
3. Romania / Europe/Bucharest.
4. Root password + email.
5. Network: pick the **10G interface** if the installer detects it (X550 on pve1; the TB adapter on pve2 — plug it in *before* booting the installer). Hostname `pve1.local` / `pve2.local`, management IP 192.168.0.11 / .12, gateway 192.168.0.1, DNS.
   - If the TB adapter isn't detected at install time, install using the onboard NIC and move the management IP onto the 10G interface in Stage 4 — nothing is lost.
6. Install → reboot → remove the stick.

Web access: `https://192.168.0.11:8006` (login `root`; the certificate warning is normal).

---

## Stage 2 — Post-install (both nodes)

**Updates → Repositories:**
- Disable the `enterprise` repos (pve + ceph)
- Add → **No-Subscription**

**Shell:**
```bash
apt update && apt full-upgrade -y
reboot
```

**Hardware check (Shell):**
```bash
lspci | grep -i ethernet     # pve1: two X550 entries
lsblk                        # all 3 NVMe drives visible
```

---

## Stage 3 — Laptop-specific configuration (pve2 ONLY)

### 3.1 Ignore the lid + disable sleep

```bash
nano /etc/systemd/logind.conf
```
Add/modify:
```
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
```
```bash
systemctl restart systemd-logind
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
echo "setterm -blank 0 -powerdown 0" >> /etc/profile
```

### 3.2 Battery check (clean shutdown at critical battery level)

```bash
apt install -y ntfs-3g acpi

cat << 'EOF' > /usr/local/bin/battery-check.sh
#!/bin/bash

BATTERY_LEVEL=$(acpi -b | grep -P -o '[0-9]+(?=%)' | head -1)
AC_STATUS=$(cat /sys/class/power_supply/AC/online 2>/dev/null)

if [ -z "$BATTERY_LEVEL" ]; then
    logger "battery-check: Battery level not detected"
    exit 0
fi

if [ "$AC_STATUS" = "0" ] && [ "$BATTERY_LEVEL" -le 10 ]; then
    logger "battery-check: Battery low (${BATTERY_LEVEL}%) and not charging. Shutting down."
    /usr/sbin/shutdown -h now
fi
EOF

chmod +x /usr/local/bin/battery-check.sh

cat << 'EOF' > /etc/systemd/system/battery-check.service
[Unit]
Description=Check battery level and shutdown if critically low

[Service]
Type=oneshot
ExecStart=/usr/local/bin/battery-check.sh
EOF

cat << 'EOF' > /etc/systemd/system/battery-check.timer
[Unit]
Description=Run battery check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=battery-check.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now battery-check.timer
systemctl status battery-check.timer
```

> Cluster note: when the battery hits 10% and pve2 shuts down, HA VMs restart on pve1 from the latest replica. The 5h UPS + laptop battery cover long outages; this script is the final safety net.

### 3.3 TLP + dynamic governor

```bash
apt install tlp -y
systemctl enable --now tlp

cat << 'EOF' > /etc/tlp.d/99-proxmox-laptop.conf
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave

CPU_ENERGY_PERF_POLICY_ON_AC=powersave
CPU_ENERGY_PERF_POLICY_ON_BAT=powersave
EOF

systemctl restart tlp
```

The `cpu-power-manager` script (switches to `performance` at load ≥60%, back down at load ≤20%):

```bash
cat << 'EOF' > /usr/local/bin/cpu-power-manager.sh
#!/bin/bash

STATE_FILE="/run/cpu-power-manager.state"

LOW_LOAD=20
HIGH_LOAD=60
REQUIRED_HITS=3

CPU0_GOVERNOR_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
CPU0_AVAILABLE_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"

if [ ! -f "$CPU0_GOVERNOR_FILE" ]; then
    logger "cpu-power-manager: CPU governor file not found"
    exit 0
fi

CURRENT_GOVERNOR=$(cat "$CPU0_GOVERNOR_FILE")
AVAILABLE_GOVERNORS=$(cat "$CPU0_AVAILABLE_FILE" 2>/dev/null)

CPU_CORES=$(nproc)
LOAD_1MIN_INT=$(awk '{print int($1 * 100)}' /proc/loadavg)
LOAD_PERCENT=$(( LOAD_1MIN_INT / CPU_CORES ))

BALANCED_GOVERNOR="schedutil"

if ! echo "$AVAILABLE_GOVERNORS" | grep -qw "$BALANCED_GOVERNOR"; then
    BALANCED_GOVERNOR="powersave"
fi

TARGET="$CURRENT_GOVERNOR"

if [ "$LOAD_PERCENT" -ge "$HIGH_LOAD" ]; then
    TARGET="performance"
elif [ "$LOAD_PERCENT" -le "$LOW_LOAD" ]; then
    TARGET="$BALANCED_GOVERNOR"
else
    TARGET="$CURRENT_GOVERNOR"
fi

if ! echo "$AVAILABLE_GOVERNORS" | grep -qw "$TARGET"; then
    logger "cpu-power-manager: target governor $TARGET not available. Available: $AVAILABLE_GOVERNORS"
    exit 0
fi

LAST_TARGET=""
HITS=0

if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
fi

if [ "$TARGET" = "$LAST_TARGET" ]; then
    HITS=$((HITS + 1))
else
    HITS=1
fi

cat << STATE > "$STATE_FILE"
LAST_TARGET="$TARGET"
HITS=$HITS
STATE

if [ "$HITS" -lt "$REQUIRED_HITS" ]; then
    logger "cpu-power-manager: load=${LOAD_PERCENT}% target=${TARGET} hits=${HITS}/${REQUIRED_HITS}, waiting"
    exit 0
fi

if [ "$CURRENT_GOVERNOR" != "$TARGET" ]; then
    for governor_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        available_file="$(dirname "$governor_file")/scaling_available_governors"
        available="$(cat "$available_file" 2>/dev/null)"

        if echo "$available" | grep -qw "$TARGET"; then
            echo "$TARGET" > "$governor_file"
        else
            logger "cpu-power-manager: skipping $governor_file, $TARGET not available. Available: $available"
        fi
    done

    logger "cpu-power-manager: load=${LOAD_PERCENT}% governor changed ${CURRENT_GOVERNOR} -> ${TARGET}"
else
    logger "cpu-power-manager: load=${LOAD_PERCENT}% governor already ${CURRENT_GOVERNOR}"
fi
EOF

chmod +x /usr/local/bin/cpu-power-manager.sh

cat << 'EOF' > /etc/systemd/system/cpu-power-manager.service
[Unit]
Description=Smart CPU power manager for Proxmox laptop

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cpu-power-manager.sh
EOF

cat << 'EOF' > /etc/systemd/system/cpu-power-manager.timer
[Unit]
Description=Run smart CPU power manager every 1 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=cpu-power-manager.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cpu-power-manager.timer
```

Verify:
```bash
systemctl status cpu-power-manager.timer
journalctl -u cpu-power-manager.service -n 50
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```

---

## Stage 4 — Network interfaces

### 4.1 The 10G segment (vmbr0 — management + VMs + migration)

1. Connect pve1's X550 port 1 and pve2's Thunderbolt adapter to the SODOLA switch with Cat6a. Uplink one switch port to the existing router.
2. On each node: **System → Network**. The bridge `vmbr0` should be tied to the 10G interface (pve1: `enp…f0`; pve2: the adapter, name like `enp…` or `enx…`).
   - If the installer bound `vmbr0` to the onboard NIC instead, double-click `vmbr0` → change **Bridge ports** to the 10G interface name → Apply Configuration.
3. `vmbr0` holds the management IP: 192.168.0.11 / .12 /24, gateway 192.168.0.1.
4. Verify link speed:
```bash
ethtool <10g-interface> | grep -i speed     # expect 10000Mb/s
```

### 4.2 The dedicated corosync link (1G, direct cable)

1. Run a single cable directly between the two onboard NICs — no switch. Auto MDI/MDIX handles the crossover, any Cat5e or better works.
2. On each node: **System → Network** → double-click the onboard interface → check **Autostart** → IPv4/CIDR `10.10.10.1/24` (pve1) and `10.10.10.2/24` (pve2), **no gateway** → **Apply Configuration**.
3. Test from the pve1 Shell:
```bash
ping 10.10.10.2
```

> This link carries corosync only. Don't bridge it, don't route through it, don't put VM traffic on it — its value is being quiet and predictable.

### 4.3 UPS

Plug the SODOLA switch into the UPS along with the nodes. A switch on unprotected power turns two redundant nodes into two isolated ones the moment the lights go out.

---

## Stage 5 — The `apps` and `db` ZFS pools (both nodes)

⚠️ This fully replaces the LVM-Thin section from the init doc. Pool names must be **identical** on both nodes.

If the disks were previously used, wipe them first (Shell, CAREFUL with device names — verify with `lsblk`):
```bash
wipefs -a /dev/nvme1n1
wipefs -a /dev/nvme2n1
```

Then from the UI, on each node: **Disks → ZFS → Create: ZFS**
- Pool 1: Name `apps`, disk 2, RAID Level **Single Disk**, compression on, ✔ Add Storage
- Pool 2: Name `db`, disk 3, same settings

Verify: **Datacenter → Storage** — `apps` and `db` visible on both nodes.

---

## Stage 6 — Cluster

**On pve1:** Datacenter → Cluster → **Create Cluster** → name `lab`:
- **Link 0** = `10.10.10.1` (the dedicated 1G direct link — corosync's primary)
- **Link 1** = `192.168.0.11` (the 10G segment — backup path)

→ Create → **Join Information → Copy**.

**On pve2:** Datacenter → Cluster → **Join Cluster** → paste the info, pve1's root password:
- **Link 0** = `10.10.10.2`
- **Link 1** = `192.168.0.12`

→ Join. The page will "freeze" (certificates change) — reload the browser.

Verify both rings are up:
```bash
corosync-cfgtool -s     # both LINK ID 0 and 1 should show "localhost on ... status = OK"
```

**Migration Settings:** Datacenter → Options → Migration Settings → Network = `192.168.0.0/24` (the 10G segment — migration wants bandwidth, corosync wants quiet; they belong on different links).

Also set a bandwidth limit of ~500 MB/s there, so a large migration doesn't starve VM traffic sharing the same 10G segment.

---

## Stage 7 — QDevice (mandatory for maintenance with one node down)

On the third device (Debian/Ubuntu, fixed IP reachable from both nodes):
```bash
apt update && apt install corosync-qnetd
```

On BOTH Proxmox nodes:
```bash
apt install corosync-qdevice
```

On pve1 ONLY:
```bash
pvecm qdevice setup <third-device-IP>
```

Verify:
```bash
pvecm status    # Total votes: 3, Quorate: Yes
```

---

## Stage 8 — Ubuntu template with cloud-init (on pve1)

Download the Ubuntu Server ISO (https://ubuntu.com/download/server) → `local` storage → ISO Images → Upload (or Download from URL).

```bash
ls /var/lib/vz/template/iso   # check the exact ISO filename

qm create 9000 \
  --name ubuntu-template \
  --memory 4096 \
  --cores 4 \
  --net0 virtio,bridge=vmbr0

qm set 9000 --machine q35 && \
qm set 9000 --bios seabios && \
qm set 9000 --scsihw virtio-scsi-single && \
qm set 9000 --scsi0 apps:32,discard=on,iothread=1 && \
qm set 9000 --cpu x86-64-v3 && \
qm set 9000 --agent enabled=1 && \
qm set 9000 --cdrom local:iso/ubuntu-24.04.4-live-server-amd64.iso && \
qm set 9000 --boot order="scsi0;ide2" && \
qm set 9000 --bootdisk scsi0
```

> Changes vs the init doc: `--scsi0 apps:32` (ZFS instead of `nvme2-thin`) and `--cpu x86-64-v3` set on the template — all clones inherit it and remain safely migratable between the two different CPUs.

Ubuntu installation in the console (same as the init doc): Console → standard install, user/password `devops`, ✔ Install OpenSSH server, Skip Ubuntu Pro, reboot.

After the install, inside the VM (ssh `devops@<dhcp-ip>`, then `sudo -i`):
```bash
apt update && \
apt upgrade -y && \
apt install -y qemu-guest-agent cloud-init sudo curl wget bash-completion && \
systemctl enable --now qemu-guest-agent && \
apt clean && \
journalctl --rotate && \
journalctl --vacuum-time=1s && \
cloud-init clean --logs && \
history -c && \
truncate -s 0 /etc/machine-id && \
rm -f /var/lib/dbus/machine-id && \
rm -rf /tmp/* /var/tmp/* && \
sync
```

Shutdown + cloud-init + convert to template (Proxmox Shell):
```bash
qm shutdown 9000

qm set 9000 --delete ide2 && \
qm set 9000 --ide2 apps:cloudinit && \
qm set 9000 --serial0 socket --vga serial0 && \
qm set 9000 --ipconfig0 ip=dhcp && \
qm set 9000 --boot order='scsi0'

qm template 9000
```

---

## Stage 9 — The VMs

All via cloning: right-click on 9000 → Clone → **Full Clone**.

| VM ID | Name | Storage | CPU | RAM | IP (Cloud-init) |
|---|---|---|---|---|---|
| 1010 | control-ubuntu | `apps` | 2 | 4 GiB | 192.168.0.10/24, gw .1 |
| 1020 | app-ubuntu | `apps` | 8 | 8 GiB | 192.168.0.20/24, gw .1 |
| 1030 | postgres-ubuntu | **`db`** | 8 | 32 GiB | 192.168.0.30/24, gw .1 |

> ⚠️ Under Hardware → Processors, the type stays **x86-64-v3** (inherited from the template). Do NOT change it to `host` — the VM would no longer migrate safely between the two nodes.

### Resize the postgres disk (after cloning)

Proxmox Shell:
```bash
qm resize 1030 scsi0 +608G
```

Inside the VM (ssh → `sudo -i`):
```bash
apt update && apt install cloud-guest-utils
lsblk    # identify the LVM partition (e.g. sda3 → ubuntu--vg-ubuntu--lv)

growpart /dev/sda 3 && \
pvresize /dev/sda3 && \
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv && \
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

(`resize2fs` at the end — it was missing from the init doc; without it the filesystem doesn't see the new space.)

### Control node — Ansible

On control-ubuntu (192.168.0.10):
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

### SSH keys

On control-ubuntu:
```bash
test -f ~/.ssh/id_ed25519_devops || ssh-keygen -t ed25519 -C "devops" -f ~/.ssh/id_ed25519_devops
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub devops@192.168.0.20
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub devops@192.168.0.30
ssh devops@192.168.0.20 hostname
ssh devops@192.168.0.30 hostname
```

---

## Stage 10 — ZFS replication

For each VM: select the VM → **Replication → Add** → Target: the other node → Schedule.

The replication interval **is** your data-loss window on an unplanned failover, so differentiate it per VM:

| VM | Schedule | Why |
|---|---|---|
| 1030 postgres | `*/1` (every minute) | RSVPs and event edits — the data you actually can't afford to lose |
| 1020 app | `*/5` | Mostly stateless; holds little unique state |
| 1010 control | `*/15` or `*/30` | Tooling only, rebuildable |

The first run copies the whole disk (takes a while); after that only deltas (seconds). On the 10G link a minute's worth of Postgres writes is nothing.

> After a failover or migration, replication jobs **reverse direction automatically** — you don't reconfigure anything. The cluster knows the VM now lives on the other node and replicates back toward the recovered one.

---

## Stage 11 — First live migration 🎯

1. From another computer: `ping -t 192.168.0.20`.
2. Right-click on the VM → **Migrate** → Target: the other node → Migrate.
3. "migration finished successfully" — the ping continues uninterrupted (at most 1 lost packet). Migrate it back as well.

---

## Stage 12 — HA (automatic failover)

### 12.1 Which VMs get HA

**Datacenter → HA → Add** for **1020 (app)** and **1030 (postgres)** only.

Leave 1010 (control) out — it serves no users, and fewer moving parts during an incident is a feature. You start it manually when you need Ansible.

### 12.2 Shutdown policy — important

**Datacenter → Options → HA Settings → `shutdown_policy` = `migrate`**

Default behavior on a clean node shutdown is to *stop* HA VMs and restart them on the other node. With `migrate`, a clean shutdown triggers a **live migration** instead — zero downtime.

This ties directly into the laptop battery script (Stage 3.2): on a long outage where the UPS is exhausted and the ZBook's battery hits 10%, the script issues a clean shutdown → the VMs live-migrate to pve1 on their own before pve2 powers off. Unattended, graceful failover.

### 12.3 Notifications

**Datacenter → Notifications** → configure an SMTP target and enable notifications for replication and backup failures.

A silently failing replication job means your RPO quietly drifts from 1 minute to hours. You want to find out that day, not during a failover.

### 12.4 Behavior summary

If a node dies suddenly, HA VMs restart on the healthy node within ~2-3 minutes, from the latest replica (data loss ≤ the replication interval). See Stage 15 for the full mechanics.

---

## Stage 13 — Hardware maintenance procedure (zero downtime)

1. Live-migrate all VMs off the target node (one by one or Bulk Migrate).
2. `pvecm status` — quorum OK (the QDevice holds the third vote).
3. Shut down the empty node.
4. Work on the hardware; the cluster runs on one node.
5. Power the node back on — it rejoins automatically, replication resumes.
6. Rebalance the VMs if you want.

---

## Stage 14 — Backup

### 14.1 Local, on USB (from the init doc)

```bash
lsblk -f          # identify the USB disk (e.g. sdb2, NTFS)
blkid             # the partition UUID

mkdir -p /mnt/usb-backup
nano /etc/fstab
```
Add (with your UUID):
```
UUID=30848B8B848B51F0 /mnt/usb-backup ntfs-3g defaults,nofail,x-systemd.automount 0 0
```
```bash
systemctl daemon-reload
mount -a
pvesm add dir usb-backup --path /mnt/usb-backup --content backup
```

Manual backup / restore:
```bash
vzdump 1020 --storage usb-backup --mode snapshot --compress zstd
qmrestore /mnt/usb-backup/dump/vzdump-qemu-1020-*.vma.zst 1020
```

Recommended: **Datacenter → Backup → Add** — scheduled job (e.g. daily 02:00, all VMs, storage `usb-backup`, snapshot mode, zstd, retention e.g. 7).

### 14.2 Offsite — Digi Storage via rclone

Digi Storage has native rclone support (the `digistorage` provider). First generate an app password: https://storage.rcs-rds.ro/app/admin/preferences/password

On the node holding the backups:
```bash
apt install rclone -y
rclone config
# n (new) → name: digi → storage: koofr → provider: digistorage
# user: <your Digi username> → password: <the generated app password>

# Encryption layer on top (recommended — waa customer data shouldn't leave in cleartext):
rclone config
# n → name: digi-crypt → storage: crypt → remote: digi:proxmox-backups
# → choose encryption passwords (WRITE THEM DOWN — without them the backups are unrecoverable)
```

Automatic sync after the local backup (cron, e.g. daily 04:00):
```bash
crontab -e
```
```
0 4 * * * rclone sync /mnt/usb-backup/dump digi-crypt: --transfers 2 --log-file /var/log/rclone-backup.log
```

Periodic restore test:
```bash
rclone ls digi-crypt:
rclone copy digi-crypt:vzdump-qemu-1030-<date>.vma.zst /tmp/restore-test/
```

> The full chain: replication (node↔node, minutes) → local USB backup (daily) → encrypted offsite copy on Digi Storage. Three tiers, three disaster types covered.

---

## Cloudflare Tunnel — placement in the new setup

Run `cloudflared` **inside the app VM (1020)**, not on the Proxmox host. That way the tunnel migrates together with the VM, and on an HA failover it restarts automatically on the healthy node — public exposure follows the application with zero intervention.

---

## Stage 15 — Failover: how it works, scenarios & FAQ

### 15.1 The three mechanisms

Failover in a 2-node Proxmox cluster is the collaboration of three parts:

| Mechanism | Answers | Component |
|---|---|---|
| **Replication** | Is the data there? | ZFS send/receive, per schedule |
| **HA manager** | Should I act, and on what? | `pve-ha-manager`, VMs added to HA |
| **Quorum** | Am I allowed to act? | corosync + QDevice (3 votes) |

All three must be healthy. Replication without quorum = no automatic action. Quorum without replication = the VM starts on the other node with stale or missing data.

### 15.2 Anatomy of an unplanned failover

pve2 dies suddenly (power cut, hardware fault, kernel panic):

1. **Detection (seconds).** corosync sees pve2 stop responding. pve1 + QDevice hold 2 of 3 votes → the cluster stays quorate and has the authority to act.
2. **Fencing (~60-120s).** Before restarting anything, the cluster must be *certain* pve2 is dead rather than merely network-isolated — otherwise two copies of Postgres write in parallel (split-brain, the worst possible outcome). Proxmox solves this with **self-fencing**: a node that loses quorum resets itself via hardware watchdog within ~60 seconds. The wait isn't hesitation — it's the guarantee.
3. **Recovery.** The HA manager on pve1 takes ownership of the HA VMs and boots them from the latest local ZFS replica. Postgres performs crash recovery on startup (exactly as after a power loss) and comes back on its own.

**Result: RTO ~2-3 minutes, RPO = the replication interval.** Symmetric in both directions — there is no "primary" node.

### 15.3 Scenario table

| Scenario | What happens | Downtime | Data loss | Your action |
|---|---|---|---|---|
| **Planned maintenance** (Stage 13) | You live-migrate, then shut the node down | **0** | **0** | Migrate → shutdown → work → power on |
| **Clean shutdown** with `shutdown_policy=migrate` | VMs live-migrate automatically | **0** | **0** | None |
| **Laptop battery hits 10%** | battery-check → clean shutdown → auto live-migration | **0** | **0** | None; plug power back in later |
| **Node dies suddenly** | Fencing → HA restart on the healthy node | ~2-3 min | ≤ replication interval | None; verify afterward |
| **Direct corosync cable pulled** | corosync fails over to Link 1 (10G segment) | 0 | 0 | Replace the cable; check `corosync-cfgtool -s` |
| **SODOLA switch dies** | corosync survives on Link 0 (direct cable), cluster stays quorate; UI and VM traffic unreachable | Service down until replaced | 0 | Replace the switch; nodes and VMs keep running throughout |
| **QDevice down, both nodes up** | Cluster runs on 2/2 votes, everything normal | 0 | 0 | Restore the QDevice — you have no margin until then |
| **QDevice down AND a node dies** | Surviving node has 1/3 votes → **no quorum, no automatic failover** | Until you intervene | ≤ replication interval | `pvecm expected 1` on the survivor (see 15.5) |
| **Internet outage** | 5G router failover | ~30s | 0 | None |
| **Power outage** | UPS ~5h, then ZBook battery, then graceful shutdown | 0 while power lasts | 0 | None |
| **A data disk fails** | That pool is lost on that node; VMs fail | Minutes | ≤ replication interval | Migrate/restart VMs on the other node, replace the disk, recreate the pool, re-enable replication |
| **The OS disk fails** | That node is down; HA takes over | ~2-3 min | ≤ replication interval | Reinstall Proxmox, `zpool import apps db`, rejoin cluster |
| **Ransomware / accidental deletion** | Replication faithfully replicates the damage | — | — | **Restore from backup** (Stage 14) — this is why replication isn't backup |
| **Fire, theft, flood** | Both nodes gone | — | — | **Offsite restore** from Digi Storage (Stage 14.2) |

### 15.4 What failover does NOT cover

Worth being explicit, so expectations match reality:

- **It is not a backup.** Replication copies corruption, deletions and encryption just as faithfully as it copies good data. The USB + offsite chain in Stage 14 is the answer to those.
- **It does not protect a single node's split second.** An unplanned failover always costs the last N minutes of writes. Zero RPO requires shared/synchronous storage — a different, considerably more expensive architecture.
- **It does not cover the frontend.** Which in waa's case is fine by design: the frontend and invitations live on Cloudflare, so a backend failover degrades RSVP/edits for a couple of minutes, while invitations themselves stay up throughout.

### 15.5 Emergency: forcing quorum

If the QDevice is unreachable *and* a node is down, the survivor refuses to start VMs. On the surviving node:

```bash
pvecm expected 1
```

⚠️ Use this **only** when you are physically certain the other node is powered off. Running it while the other node is alive but unreachable is exactly how you get split-brain and a corrupted database. Never run it "just to make things work". Restore normal quorum as soon as the QDevice or the second node is back.

### 15.6 Pre-launch test plan

A failover you haven't tested is a hope, not a solution. Run all three before waa goes live, and write down the timings:

1. **Planned live migration.** `ping -t` the app VM, migrate, confirm ≤1 lost packet. Migrate back.
2. **Clean shutdown with `shutdown_policy=migrate`.** Shut down pve2 from the UI; confirm the VMs migrate on their own rather than restarting. This also validates the battery-script path.
3. **Hard kill.** Cut power to pve2 (pull the plug, UPS bypassed). Time how long until the app answers again. Then check Postgres: did crash recovery complete cleanly? How much data was lost versus the replication interval? Power pve2 back on and confirm it rejoins and replication reverses on its own.

Repeat test 3 once after any significant infrastructure change.

### 15.7 Health checks worth running periodically

```bash
pvecm status                  # Quorate: Yes, Total votes: 3
corosync-cfgtool -s           # both LINK 0 and LINK 1 status = OK
zpool status                  # no errors, no DEGRADED
pvesr status                  # replication jobs OK, no stale entries
ha-manager status             # HA services started, on which node
qm list                       # VMs running where you expect
```

Add `zpool scrub apps` / `zpool scrub db` monthly (or a cron job) to catch silent disk corruption early.

---

## Quick troubleshooting

- **An NVMe drive isn't visible at install** → VMD/RST in BIOS (Stage 0.1).
- **Replication fails** → does a pool with the same name exist on the target? Does it have space? (`zpool list`)
- **Migration is slow** → Migration Settings pointing at the wrong network (Stage 6).
- **"cluster not ready - no quorum"** → QDevice down/unreachable; emergency on the surviving node: `pvecm expected 1` (temporary!).
- **VM won't live-migrate** → ISO mounted in the CD drive (remove it) or non-migratable local resources attached.
- **VM crashed after migration** → someone set CPU type `host`; revert to `x86-64-v3`.

### Useful app debug commands (from the init doc)
```bash
nginx -T | grep -A 10 -B 10 "upstream"
ss -lntp | grep 5000
sudo lsof -i :5000
systemctl list-units --type=service | grep myapp
sudo systemctl restart myapp.service
systemctl reload nginx
ps aux | grep myapp
readlink -f /proc/<PID>/exe
```
