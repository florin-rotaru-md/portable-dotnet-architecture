# Stage 3 — Laptop-specific configuration (pve2 now, the QDevice at Stage 8)

*Part of the [Proxmox lab guide](../README.md).*

Two of the three machines in this build are laptops: pve2, and the QDevice ([8.1](../cluster/08-qdevice.md#81-the-box-and-its-os)). **3.1 and 3.2 apply to both** — run them here for pve2, and again on the QDevice once it has Debian, as [8.6](../cluster/08-qdevice.md#86-its-a-laptop--stage-3-applies-here-too) says. **3.3 and 3.4 are pve2 only:** 3.3 tunes a hypervisor whose load swings with the VMs on it — the QDevice is idle by design and has nothing for the governor script to react to — and 3.4 is about the one piece of cluster hardware that is a laptop consequence.

## 3.1 Ignore the lid + disable sleep

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

## 3.2 Battery check (clean shutdown at critical battery level)

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

> Cluster note: when the battery hits 10% and pve2 shuts down, `shutdown_policy=migrate` ([15.2](../ha/15-ha.md#152-shutdown-policy--important)) **live-migrates** the HA VMs to pve1 before the node powers off — zero downtime, zero data loss, and nothing is ever *recovered* from the replica ([18.3](../ha/18-failover.md#183-scenario-table)); the move itself runs one last incremental replication first, and the job reverses direction afterwards on its own ([Stage 12](../ha/12-replication.md)). Restarting from the latest replica is the *other* path, the one an unclean death gives you, and it costs up to one replication interval ([15.6](../ha/15-ha.md#156-behavior-summary)); shutting down at 10% rather than riding the battery to zero is exactly what keeps you off it. The one case where nothing migrates is pve1 already being down — then the guests get a clean shutdown as part of pve2's own, data safe, service off until a node returns. The 5h UPS + laptop battery cover long outages; this script is the final safety net. On the QDevice the same script has a different meaning — nothing migrates, it just ends the third vote *cleanly* instead of at whatever second the battery gives out ([4.4](04-ups.md#44-the-long-outage-timeline-end-to-end)).

## 3.3 TLP + dynamic governor (pve2 only)

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

The last two lines are not about the CPU. A TLP drop-in overrides only the keys it names — everything else keeps the value shipped in `/usr/share/tlp/defaults.conf` — so a file that lists governors alone still leaves a laptop power daemon managing the peripherals of a hypervisor. Two defaults matter here. `USB_AUTOSUSPEND="1"` is not battery-conditional: it applies from the moment the unit is enabled, on AC as much as on battery, and it governs every USB device on the node. Nothing pve2 does *as a hypervisor* hangs off USB — the UPS data cable ([4.6](04-ups.md#46-disabled-on-this-build)) and the backup drive the checks look for ([17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive)) are both pve1's — but `lsusb` is not empty either: a Logi Bolt receiver, the HP 5MP camera and the AX211 Bluetooth radio, and the last two read `control = auto` on pve2 today, which is the shipped `1` doing exactly what this line exists to stop. The receiver does not, and the reason is worth knowing rather than assuming: TLP hard-codes an exclusion for any device exposing a HID interface (`bInterfaceClass 03` → `control=on`, `_hid_deny`), so the keyboard and mouse you would reach for at a physical console during an incident are never autosuspended whatever this key says — that is not one of the `USB_EXCLUDE_*` switches and cannot be turned off. So `0` costs nothing that matters today, and it is prophylactic and cheap: it stops a laptop power daemon deciding months from now that whatever you did plug into a hypervisor looks idle. `RUNTIME_PM_ON_BAT="auto"` flips on battery and writes `power/control=auto` to every PCI device outside `RUNTIME_PM_DRIVER_DENYLIST` (`mei_me nouveau radeon xhci_hcd`), which lists neither `e1000e` — pve2's onboard 1G, i.e. `vmbr0`, corosync ring 0, migration and every VM — nor `atlantic`, the Thunderbolt 10G adapter that carries the `10.10.10.0/24` ring when it is plugged in ([3.4](#34-pve2s-half-of-the-10g-link-hangs-off-thunderbolt)). Mind the vocabulary: in TLP `on` and `0` mean *no* power management, which is the counter-intuitive half of the setting.

Read this as prevention, not as a diagnosis. An open interface holds a runtime-PM reference while its link is up, and nothing here has been shown to suspend a NIC — in particular the adapter drops in the [10G runbook](../troubleshooting.md#runbook--the-10g-link-is-down) happened on AC, where TLP's own default is `RUNTIME_PM_ON_AC="on"` and it touches nothing. The point is narrower: battery is exactly the window in which pve2 is holding a vote for a cluster that has just lost power, and that is the wrong window to let a laptop tool decide which of its devices look idle. The cost is a slightly higher idle draw on battery, which is irrelevant against [3.2](#32-battery-check-clean-shutdown-at-critical-battery-level) — the node shuts down at 10% anyway.

`tlp-stat -c` prints every setting with the file it came from. Run it after the restart: the keys above should read `99-proxmox-laptop.conf`, and whatever still reads `defaults.conf` is a decision you have not made.

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

## 3.4 pve2's half of the 10G link hangs off Thunderbolt

The ZBook has no PCIe slot, so where pve1 puts an X550 card in the [10G direct link](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected), pve2 puts an **ACASIS NT0201A Thunderbolt 10G dock** (`atlantic` driver, PCI `0000:3e:00.0`) in a TB4 port — cable ③ of [0.4](00-preparation.md#04-physical-cabling--what-goes-where). That is a laptop constraint, not a design choice, and it makes this node asymmetric with pve1 in a way that has already cost console time. Since 2026-09-10 the cable is deliberately on-demand — plugged in for a migration, unplugged afterwards ([5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)) — so on an ordinary day the dock is *supposed* to be absent.

**The interface names are not symmetric, and only half of them are pinned.** The Proxmox installer pins each built-in NIC to a stable `nicN` by MAC; [5.5](05-network.md#55-for-reference--the-resulting-config) owns that story — both nodes' mappings, pve2's `nic1` stanza for a card that can never appear, and why none of those rules are in the config backup. What matters here is the half that is pinned by *nothing*: the dock arrives under a name the kernel derives from its Thunderbolt PCI path (`atlantic 0000:3e:00.0 enp62s0: renamed from eth0`), so pve2's config mixes one pinned name (`nic0`, the bridge port of `vmbr0`) with one bus-path name that changes if the dock moves to a different TB4 port.

Two consequences worth knowing before you need them. Use the same TB4 port every time — [0.4](00-preparation.md#04-physical-cabling--what-goes-where) already says to prefer the one not shared with the charger or a dock, and this is the second reason. And do not trust an interface name copied from another node or from [5.5](05-network.md#55-for-reference--the-resulting-config)'s example: read `ip -br link` on the machine in front of you. That is exactly the step [19.3](../operations/19-node-replacement.md#193-approach-b--transplanting-the-disks) has you perform at a physical console with the node unreachable, and the note there about the name following the MAC is wrong for this adapter — it follows the bus.

**It is a hot-plug bus, so a missing interface is the normal state, not a fault.** `ip link` on pve2 simply will not list `enp62s0` when the dock is unseated, and `networking.service` stays `active (exited)` regardless, because `ifupdown2` has nothing to fail against ([5.3](05-network.md#53-verify)). Check the bus, not the interface:

```bash
boltctl list                          # status: connected / disconnected, on pve2
ip -br link | grep -E 'enp|nic'       # what actually enumerated
```

Nothing in the running cluster depends on the answer. Corosync membership rides ring 0 on the 1G LAN, and `datacenter.cfg` pins migration and replication to `192.168.0.0/24` as well, so an absent dock costs ring redundancy and nothing else — the price of that is the quorum table in [5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected). What matters here is the *other* case: the dock failing to come up on the day you plugged it in for a migration. Reseat first, and if `boltctl` shows repeated connect/disconnect pairs rather than one clean connect, the dock or the port is the fault and the cable is not — this one has enumerated and vanished again inside a minute. The runbook is in [troubleshooting](../troubleshooting.md#runbook--the-10g-link-is-down).
