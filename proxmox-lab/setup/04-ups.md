# Stage 4 — UPS monitoring on pve1 (NUT)

*Part of the [Proxmox lab guide](../README.md).*

> **Not in service on this build (2026-09-04).** The UPS has no data path to pve1 — nothing on USB (`lsusb` sees only the root hubs and a card reader) and no network management card in the unit — so `usbhid-ups` had nothing to attach to: `nut-driver@ups` sat in a restart loop and `nut-monitor` logged *Poll UPS [ups@localhost] failed - Driver not connected* every five seconds. NUT is now stopped, disabled and masked on pve1 ([4.6](#46-disabled-on-this-build)); pve2 never had it installed. **The third row of the [4.4](#44-the-long-outage-timeline-end-to-end) timeline does not hold here — pve1 loses power hard when the UPS runs dry.** Everything below stays as written: it is what to do the day the UPS gains a data port, and 4.6 is the switch back.

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

With this stage done, a power outage needs zero human action at any point. **On this build the third row is the exception** — NUT is disabled ([4.6](#46-disabled-on-this-build)), so pve1 is cut off rather than shut down; the rest of the table is unchanged:

| When | What happens | Why |
|---|---|---|
| Power fails | pve1 keeps running on the UPS; pve2 and the QDevice on their own batteries; router failover covers internet | Stage 0.4 |
| pve2's battery hits 10% | `battery-check` → clean shutdown → VMs live-migrate to pve1 | Stage 3.2 + 15.2 |
| UPS battery goes low (~5h) | NUT → clean pve1 shutdown, VMs cleanly stopped (pve2 is already off). **Not here** — no data cable, no signal, so pve1 simply loses power ([4.6](#46-disabled-on-this-build)) | this stage |
| QDevice's battery hits 10% | `battery-check` → clean shutdown. It outlives both nodes, so the last thing still up is the vote nobody needs any more | Stage 3.2, via [8.6](../cluster/08-qdevice.md#86-its-a-laptop--stage-3-applies-here-too) |
| Power returns | pve1 powers on (BIOS *restore on AC*, [Stage 0.1](00-preparation.md#01-bios)), pve2 powers on (*Wake on AC*), QDevice boots; HA starts 1021 + 1022, `onboot` starts 1023 | HA desired state = `started`; [Stage 10](../vms/10-vms.md#start-at-boot--what-comes-back-after-a-node-reboot) |
| Afterward | 1020 stays off until you start it — by design ([15.1](../ha/15-ha.md#151-which-vms-get-ha)); run the health check script and move on | |

Two notes at the tail. **The QDevice's battery is why row 4 exists**: a mini PC in that role loses power hard the moment the UPS gives out — survivable, but abrupt — whereas this build's laptop runs on past pve1 and shuts itself down cleanly via the same 3.2 script. Either way `pg-receivewal` ([Stage 13](../ha/13-wal-stream.md)) reconnects at boot and resumes from its slot with no action needed — the battery just removes an unclean power-off from the routine.

**And check the wake behaviour on all three.** pve1 and pve2 need *restore on AC* / *Wake on AC* ([0.1](00-preparation.md#01-bios)); a laptop QDevice that shut down on a flat battery normally comes back when AC returns, but the setting is worth confirming in its BIOS rather than assuming — an outage that leaves the third vote off is exactly the state [18.3](../ha/18-failover.md#183-scenario-table)'s worst row describes.

## 4.5 Test it once, for real

During the [18.6](../ha/18-failover.md#186-pre-launch-test-plan) pre-launch window, run one full rehearsal: everything running, pull the UPS's input plug, and walk away. The correct outcome is boring — pve2 eventually shuts itself down, then pve1, and when you restore power everything comes back and the app answers. Time it, write the numbers down next to the 18.6 results. If you can't afford a full UPS drain, at least force the final step: `upsmon -c fsd` on pve1 simulates the low-battery signal and runs the real shutdown path.

**On this build neither half of that test exists** ([4.6](#46-disabled-on-this-build)): `upsmon -c fsd` has nothing to signal, and the drain rehearsal now measures a hard cut rather than a shutdown. It is still worth running once for the other rows — pve2's 3.2 shutdown and the return-to-power sequence — but time how long Postgres takes to finish crash recovery on the way back, because that is the number the missing safety net costs you.

## 4.6 Disabled on this build

The UPS in this lab has no data port pve1 can reach — no USB cable, and no network management card — so the stage above was configured against a device that was never there. `nut-driver@ups` failed on every start, systemd restarted it, and `nut-monitor` polled a driver that would never connect:

```
Failed to start nut-driver@ups.service - Network UPS Tools - device driver for NUT device 'ups'.
nut-monitor[1883]: Poll UPS [ups@localhost] failed - Driver not connected
```

Turned off on pve1 rather than left looping. The packages stay installed, so this is an unmask away from working the day the hardware changes:

```bash
UNITS="nut-monitor nut-server nut-driver-enumerator.path nut-driver-enumerator.service nut-driver.target nut.target"

systemctl stop    $UNITS nut-driver@ups
systemctl disable $UNITS
sed -i 's/^MODE=.*/MODE=none/' /etc/nut/nut.conf
systemctl mask    $UNITS 'nut-driver@.service'
```

`MODE=none` is NUT's own "do not run" switch, and the masks are what make it survive a reboot and an `apt upgrade` of the `nut` packages — `disable` alone doesn't, because `nut-driver-enumerator` re-creates driver instances the moment it runs and the postinst restarts whatever it finds enabled. The template `nut-driver@.service` is masked rather than the `@ups` instance, which covers every instance the enumerator could invent. `/etc/nut` is left in place — still swept up by [`pve-config-backup`](../scripts/README.md) — including the stale `/etc/systemd/system/nut-driver@ups.service.d/` drop-in the enumerator generated: inert while the template is masked, regenerated if it ever isn't. [`cluster-health`](../scripts/README.md) reads `MODE` and reports this as the intended state, so the nightly mail stays quiet.

**What it costs** is exactly what this stage was written to prevent: at ~5h into an outage the UPS gives out and the ThinkStation stops mid-write, with Postgres most likely on it because [3.2](03-laptop-node.md#32-battery-check-clean-shutdown-at-critical-battery-level) migrated everything there hours earlier. ZFS survives a hard cut and Postgres does crash recovery at boot, so this is not a data-loss hole — it is an unclean stop on every long outage, a worse starting position than the one [18.3](../ha/18-failover.md#183-scenario-table) assumes.

**To bring it back**, in order: give the UPS a data path — a USB cable to pve1, or a network management card at a static address in the [Stage 0](00-preparation.md) plan — then `systemctl unmask` the units above, set `MODE=standalone` again, and re-run [4.1](#41-install-and-detect)–[4.3](#43-verify). A network card is not a drop-in for [4.2](#42-configure--standalone-mode)'s config: the driver becomes `snmp-ups` or `netxml-ups` with `port = <ip>`, not `usbhid-ups` with `port = auto`.

