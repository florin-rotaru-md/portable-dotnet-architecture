# Stage 3 — Laptop-specific configuration (pve2 ONLY)

*Part of the [Proxmox homelab guide](../README.md).*

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

> Cluster note: when the battery hits 10% and pve2 shuts down, HA VMs restart on pve1 from the latest replica. The 5h UPS + laptop battery cover long outages; this script is the final safety net.

## 3.3 TLP + dynamic governor

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
