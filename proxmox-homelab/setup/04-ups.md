# Stage 4 — UPS monitoring on pve1 (NUT)

*Part of the [Proxmox homelab guide](../README.md).*

[Stage 3.2](03-laptop-node.md#32-battery-check-clean-shutdown-at-critical-battery-level) gave pve2 a clean shutdown at 10% battery. pve1 has no equivalent: it sits on the UPS, and when the UPS runs dry after ~5h the ThinkStation dies mid-write — with Postgres most likely running on it, because the battery script migrated everything there hours earlier. A hard power cut won't corrupt ZFS, but "the database crashes at hour five of every long outage" is not a property to keep when fixing it takes fifteen minutes.

NUT (Network UPS Tools) closes the gap: it watches the UPS over its USB data cable and issues a clean shutdown when the battery goes low. **This assumes the UPS has a USB data port** — practically every consumer APC/Eaton/CyberPower unit does. If yours doesn't, no software can see its state; that's worth fixing at the hardware level.

## 4.1 Install and detect

```bash
apt install -y nut
nut-scanner -U        # should print a usbhid-ups block for the UPS
```

## 4.2 Configure — standalone mode

Four small files. Replace `<password>` with something random (it's only used between local NUT components, but don't leave the example value):

```bash
cat << 'EOF' > /etc/nut/ups.conf
[ups]
    driver = usbhid-ups
    port = auto
    desc = "lab UPS"
EOF

echo 'MODE=standalone' > /etc/nut/nut.conf

cat << 'EOF' > /etc/nut/upsd.users
[upsmon]
    password = <password>
    upsmon master
EOF

cat << 'EOF' > /etc/nut/upsmon.conf
MONITOR ups@localhost 1 upsmon <password> master
SHUTDOWNCMD "/sbin/shutdown -h now"
EOF

chown root:nut /etc/nut/*.conf /etc/nut/upsd.users && chmod 640 /etc/nut/*.conf /etc/nut/upsd.users
systemctl restart nut-server nut-monitor
systemctl enable nut-server nut-monitor
```

The defaults do the right thing from here: when the UPS reports *on battery + low battery* (`OB LB`), `upsmon` triggers `SHUTDOWNCMD`. Since `shutdown_policy=migrate` ([Stage 15.2](../ha/15-ha.md#152-shutdown-policy--important)), a clean pve1 shutdown live-migrates the VMs to pve2 if it's still up; if pve2 is already down, the VMs receive a clean guest shutdown as part of the node's own shutdown — data safe either way, service down until power returns.

## 4.3 Verify

```bash
upsc ups@localhost | grep -E 'ups.status|battery.charge|battery.runtime'
systemctl is-enabled nut-server nut-monitor    # expect "enabled" on both
```

Confirm the enablement rather than assume it: unlike `qemu-guest-agent` ([9.2](../vms/09-ubuntu-template.md#92-inject-the-guest-agent)) these units aren't static, but NUT packaging has moved around across releases and some versions wire them up through `nut.target` instead of `multi-user.target`. If either reports something other than `enabled`, `systemctl enable nut.target` covers that variant — and a safety net that doesn't come back after a reboot is no safety net at all.

`ups.status: OL` means on line power. Pull the UPS's **input** plug for a few seconds: the status flips to `OB`, and back to `OL` when you reconnect. That proves the data path; the full-drain path is tested once, below.

## 4.4 The long-outage timeline, end to end

With this stage done, a power outage needs zero human action at any point:

| When | What happens | Why |
|---|---|---|
| Power fails | pve1 + QDevice keep running on the UPS; pve2 on its own battery; router failover covers internet | Stage 0.4 |
| pve2's battery hits 10% | `battery-check` → clean shutdown → VMs live-migrate to pve1 | Stage 3.2 + 15.2 |
| UPS battery goes low (~5h) | NUT → clean pve1 shutdown, VMs cleanly stopped (pve2 is already off) | this stage |
| Power returns | pve1 powers on (BIOS *restore on AC*, [Stage 0.1](00-preparation.md#01-bios)), pve2 powers on (*Wake on AC*), QDevice boots; HA starts 1021 + 1022 automatically | HA desired state = `started` |
| Afterward | 1020 stays off until you start it — by design ([15.1](../ha/15-ha.md#151-which-vms-get-ha)); run the health check script and move on | |

One note at the tail: the QDevice loses power hard when the UPS dies. For this build's box (NVMe mini PC) that's a non-event — the filesystem takes it fine, and `pg-receivewal` ([Stage 13](../ha/13-wal-stream.md)) reconnects at boot and resumes from its slot, no action needed. Check for a "power on after AC loss" BIOS setting on it too, so all three machines come back unattended.

## 4.5 Test it once, for real

During the [18.6](../ha/18-failover.md#186-pre-launch-test-plan) pre-launch window, run one full rehearsal: everything running, pull the UPS's input plug, and walk away. The correct outcome is boring — pve2 eventually shuts itself down, then pve1, and when you restore power everything comes back and the app answers. Time it, write the numbers down next to the 18.6 results. If you can't afford a full UPS drain, at least force the final step: `upsmon -c fsd` on pve1 simulates the low-battery signal and runs the real shutdown path.
