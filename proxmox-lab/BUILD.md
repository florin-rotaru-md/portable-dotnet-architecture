# Build or replace the infrastructure

[Map](README.md) · [Operations](OPERATIONS.md) · [Recovery](RECOVERY.md) · [VM provisioning](../native/README.md)

Use this for a new installation or a controlled replacement. On a live cluster, first follow
the maintenance/recovery procedure. Never run storage creation against an unidentified disk.

## Hardware and firmware

| Node | Boot | `apps` pool | `db` pool |
|---|---|---|---|
| pve1 ThinkStation P2 | Intel S3710 SATA | Samsung MZ7KM SATA | Kingston Fury NVMe |
| pve2 ZBook Fury G10 | SK hynix PC801 NVMe | Kingston KC3000 NVMe | WD SN8000S NVMe |

Both nodes have 64 GB RAM and **single-disk** data pools; there is no local mirror/parity.
Disk names are not symmetric. Match model/serial through `/dev/disk/by-id` before any wipe,
replacement or import. QDevice is the separate Dell laptop, not a VM on either node.

Enable virtualization and IOMMU, disable VMD/RST/RAID hiding individual drives, and enable
power-on-after-AC-return. On Dell select AHCI/NVMe rather than RAID On. Recheck after firmware
updates. pve2's AC-return option was reported disabled in the existing hardware notes; verify it
physically before relying on unattended restart. Do not infer battery/firmware state from a healthy VM.

Install the chosen supported Proxmox release on the boot disk, configure the appropriate package
repository/subscription, update, reboot and verify running kernel. The audited nodes ran PVE
9.2.18; consult current vendor upgrade instructions before changing releases.

## Network

| Machine | LAN address | Optional direct link |
|---|---|---|
| QDevice | 192.168.0.10 | None |
| pve1 | 192.168.0.11 | 10.10.10.1/24 |
| pve2 | 192.168.0.12 | 10.10.10.2/24 |
| control/app/postgres/monitoring | .20/.21/.22/.23 | None |

Gateway/DNS is `192.168.0.1`; infrastructure addresses must be outside DHCP allocation. `vmbr0`
bridges the actual connected LAN port. On pve1 that is X550 port 2; its onboard NIC is unused.
pve2 uses the onboard LAN. Detect carrier/MAC rather than assuming a Linux interface name.

The direct 10G link is plugged in for selected migrations. It has no gateway and no guest bridge.
Corosync Link 0 uses LAN; Link 1 uses direct addresses. Routine replication/migration must not
depend on the optional cable. Use a local console when editing the management bridge.

After network changes:

```bash
ip -br address
ip route
ping -c 3 192.168.0.1
corosync-cfgtool -s
```

Expect one default route. With direct cable connected, both peer links must connect; normally
Link 1 can be disconnected. The [quorum consequence](OPERATIONS.md#quorum-and-network) remains real.

## Storage and cluster

Identify disks, create ZFS `apps` and `db` on each node with compression, and register them as
ZFS VM storage. The names must match across nodes. Do not copy `/dev/sdX` or NVMe enumeration
from the other node.

Before creating VM disks, on pve1:

```bash
pvesm set apps --delete nodes
pvesm set db --delete nodes
pvesm set apps --sparse 1
pvesm set db --sparse 1
zpool status
```

Thin provisioning makes discard return space. Existing thick volumes are not converted by the
storage flag. Single-disk ZFS detects corruption but cannot repair from a second local copy.

Create the cluster on pve1 and join empty pve2 using the Proxmox cluster UI. Specify LAN as Link 0
and direct network as Link 1 on both ends. Joining replaces pve2's cluster configuration; recheck
storage availability on both nodes afterwards.

```bash
pvecm status
corosync-cfgtool -s
pvesh get /nodes/pve2/storage
grep -E '^(migration|replication):' /etc/pve/datacenter.cfg
```

Set migration and replication independently to secure transport on `192.168.0.0/24` in Datacenter
Options. Expected config:

```text
migration: secure,network=192.168.0.0/24
replication: network=192.168.0.0/24,type=secure
```

## QDevice

Install Debian on the separate wired Dell at `.10`. Set static addressing, key-based SSH and
power policy. Install `corosync-qnetd` there and `corosync-qdevice` on both Proxmox nodes. Arrange
the supported initial SSH trust from the cluster to QDevice, then run on a cluster node:

```bash
pvecm qdevice setup 192.168.0.10
pvecm status
```

Expect three total votes and quorum two. Prove key-only login and remove any temporary bootstrap
access after setup. QDevice requires its own backup/recovery credentials and notification path.
It must remain outside the two-node failure domain.

## Laptop power

pve2 and QDevice must keep working with lids closed. Disable automatic sleep/hibernate and desktop
idle actions; do not accidentally disable a deliberate low-battery shutdown. Verify AC loss,
battery reporting and AC-return behavior with a controlled test before enabling production HA.

pve1's UPS has no data port in this build; NUT monitoring is not active. Do not promise a battery
triggered clean shutdown there. The power-loss recovery path must tolerate a hard cut.

Use the [power recipes](#laptop-power-recipes) when rebuilding. Compare with the installed units
and host configuration archive; default laptop sleep settings can silently remove quorum.

## VM template

Build template 9000 from the verified Ubuntu cloud image. Use the image/release compatible with
the native roles; the current guide/config uses Ubuntu 26.04. Download image and checksums from
Canonical, verify the checksum, then inject the guest agent offline:

```bash
apt install libguestfs-tools
virt-customize -a /var/lib/vz/template/iso/ubuntu-26.04-server-cloudimg-amd64.img \
  --install qemu-guest-agent --truncate /etc/machine-id
qm create 9000 --name ubuntu-template --ostype l26 --memory 4096 --sockets 1 --cores 4 \
  --net0 virtio,bridge=vmbr0 --machine q35 --scsihw virtio-scsi-single \
  --cpu x86-64-v3 --agent enabled=1 --serial0 socket --vga serial0
qm set 9000 --scsi0 apps:0,import-from=/var/lib/vz/template/iso/ubuntu-26.04-server-cloudimg-amd64.img,discard=on,ssd=1,iothread=1
qm set 9000 --boot order=scsi0
qm disk resize 9000 scsi0 32G
qm set 9000 --ide2 apps:cloudinit --ipconfig0 ip=dhcp --ciuser devops \
  --nameserver 192.168.0.1 --searchdomain lan
qm set 9000 --sshkeys /root/.ssh/vm_keys.pub
qm template 9000
```

Prepare `vm_keys.pub` from approved workstation, control/devops, break-glass and both host public
keys. Cloud-init seeds keys; Ansible later owns revocation. Keep private keys out of the image.
Truncate machine-id after package injection so clones get distinct identities. Use `x86-64-v3`,
not `host`, because the CPUs differ. The smallest disk is 32 GB; clones can grow, not shrink.

Test a scratch clone's guest agent, static address, unique machine-id, key-based access and
filesystem growth before creating production guests.

## Guests and native provisioning

| VM | Address | RAM | Disk / storage | HA |
|---|---|---|---|---|
| 1020 control | .20 | 4 GB | 32 GB / apps | Manual recovery |
| 1021 app | .21 | 8 GB | 128 GB / apps | Yes |
| 1022 postgres | .22 | 32 GB | 1024 GB / db | Yes |
| 1023 monitoring | .23 | 8 GB | 320 GB / apps | Manual recovery; start at boot |

Use [create-vms.sh](scripts/create-vms.sh) after reviewing its parameters and occupied IDs. It
creates guests from the template; it is not a repair command for existing VMs. Verify addresses
through the guest agent and inside each guest, SSH/sudo and disk growth.

Install Ansible on control, check out this repository and populate `~/app-inventory` outside it.
Use the committed native examples as schema and the reviewed installation inventory as inputs.
The detailed apply/release procedure is [platform operations](../../platform/docs/OPERATIONS.md#inventory).
Bootstrap installs PostgreSQL, .NET, Nginx, application slots, cloudflared and monitoring according
to inventory. Fiscal has no bundle; Educa is not installed merely because a template exists.

## Replication and HA

Add replication to the other node for 1022 at `*/1`; 1020/1021/1023 at `*:0`. Inspect last successful
sync and failures with `pvesr status`. The interval is a target, not proof of current recoverability.

Register only 1021 and 1022 with HA; use shutdown policy `migrate`, no automatic failback/rebalance.
Verify watchdog/fencing and capacity on the surviving node. Control/monitoring recovery remains
manual after node loss. Reboot behavior is separately controlled by VM start-at-boot.

Install/review [helper scripts](scripts/README.md), configure report credentials and verify actual
receipt of reports. Complete [backup activation and restore checks](RECOVERY.md#backup-activation)
before declaring recovery protection. A working HA pair is not a backup.

## Laptop power recipes

Apply lid/sleep and battery protection on pve2 and QDevice. Governor/TLP tuning applies only to pve2.
Inspect the actual battery and AC paths before enabling the timer; `/sys/class/power_supply/AC/online`
is hardware-specific. A deliberate shutdown can migrate HA guests only while the peer is healthy,
quorate and has capacity; battery time must cover that migration.

```bash
nano /etc/systemd/logind.conf
```

```text
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
```

```bash
systemctl restart systemd-logind
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

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

```bash
apt install tlp -y
systemctl enable --now tlp

cat << 'EOF' > /etc/tlp.d/99-proxmox-laptop.conf
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave

CPU_ENERGY_PERF_POLICY_ON_AC=powersave
CPU_ENERGY_PERF_POLICY_ON_BAT=powersave

RUNTIME_PM_ON_BAT=on
USB_AUTOSUSPEND=0
EOF

systemctl restart tlp
```

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

```bash
systemctl status cpu-power-manager.timer
journalctl -u cpu-power-manager.service -n 50
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
```
