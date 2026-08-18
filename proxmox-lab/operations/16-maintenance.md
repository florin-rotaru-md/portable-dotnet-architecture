# Stage 16 — Hardware maintenance procedure (zero downtime)

*Part of the [Proxmox lab guide](../README.md).*

## 16.1 Planned maintenance, same day

1. Put the node into **HA maintenance mode**. This migrates its HA guests away for you and — the part a manual migrate cannot give you — takes the node out of the recovery pool, so if the *other* node fails while you are elbow-deep in this one, HA will not pick the half-disassembled machine as its target:

   ```bash
   ha-manager crm-command node-maintenance enable pve2
   ha-manager status                 # the pair now runs on the other node
   ```

2. Migrate the non-HA guests by hand — 1020 and 1023 are not the HA manager's business ([15.1](../ha/15-ha.md#151-which-vms-get-ha)), so maintenance mode does not touch them. Bulk Migrate does both in one go; leaving 1023 down for a short window is also a legitimate choice.
3. `pvecm status` — quorum OK (the QDevice holds the third vote).
4. Shut down the empty node.
5. Work on the hardware; the cluster runs on one node.
6. Power the node back on — it rejoins automatically, replication resumes.
7. Leave maintenance mode — but only once the node is fit to *receive* workload again:

   ```bash
   ha-manager crm-command node-maintenance disable pve2
   ```

⚠️ **Disabling maintenance mode moves the HA guests back on its own.** The stack recorded where each one was when you enabled it, and returns them there. That is exactly what you want after an afternoon of work, and exactly what you don't want after a long one: [16.2](#162-returning-a-node-after-a-long-outage-days-to-weeks) exists because a returning node needs its packages aligned and its replication caught up *before* it takes workload, and this command asks neither question — it just moves them. For anything beyond same-day work, don't use maintenance mode as the return path: leave the node out of it, follow 16.2, migrate by hand.

> That auto-return is the whole difference between the two routes. For a short window you can skip maintenance mode entirely — `shutdown_policy=migrate` ([15.2](../ha/15-ha.md#152-shutdown-policy--important)) already live-migrates the HA guests when you shut the node down, and brings nothing back afterwards ([15.5](../ha/15-ha.md#155-rules--and-the-failback-flag-that-is-on-by-default): no rules, no failback). Maintenance mode earns its place when the work doesn't start with a shutdown: a firmware sweep, a long diagnostic, anything where the node stays up and untrustworthy for a while and you want HA to stop considering it.

## 16.2 Returning a node after a long outage (days to weeks)

Step 6 above assumes the node was gone for an hour. If it was gone for two weeks — a dead PSU waiting on a part, a laptop you took on a trip, an RMA — the cluster mechanics are identical but three things have drifted underneath you. Nothing here is dangerous *if* you take it in order; the failure mode is doing it in the wrong order and discovering the problem mid-migration.

**What has *not* changed, and needs no action:**

corosync has no membership expiry. The node authenticates with the cluster key it already has, pmxcfs syncs `/etc/pve` down from the quorate side, and votes go from 2 back to 3. Two hours or two months makes no difference. There is also no split-brain risk from the absence itself: while it was without quorum its `/etc/pve` was mounted **read-only**, so it could not have produced conflicting cluster state. This is a different situation from the removed node in [19.2 step 4](19-node-replacement.md#4-power-off-pve2-permanently-then-remove-it) — that one is no longer a member and must never be powered back on; this one is still a legitimate member.

**What has changed:**

| Drifted | What actually happened | Why it matters |
|---|---|---|
| **Replication baseline** | The job reversed at failover, so pve1 is now the source. It retried and failed for two weeks with backoff (up to ~30 min between attempts), keeping its last successful replication snapshot the whole time | The return sync is one large incremental, not a delta. It also means the source pool has been growing (see below) |
| **Package versions** | pve1 took two weeks of updates; the returning node is on whatever shipped before it died | Live migration from a newer QEMU onto an older one can fail on machine type. **This is the one that bites** |
| **The clock** | RTC drift on a machine that sat powered off | Skew shows up as confusing log timestamps and, at extremes, pmxcfs and certificate complaints |

> **Watch the surviving node's pools *during* a long outage, not after.** The retained replication snapshot (`__replicate_1022-0_<timestamp>__`) pins every block that Postgres has since overwritten or deleted. At this scale that's noise, but the mechanism is real and unbounded: a write-heavy workload can fill the pool on the node that's still up, turning a redundancy problem into an outage. `zfs list -t snapshot -o name,used` and `zpool list` weekly while a node is away.

### The return procedure

Order matters: **rejoin → align versions → replicate → only then migrate.**

> The whole sequence below is wrapped in [`node-return`](../scripts/README.md) (installed in Stage 2.4), which checks each gate and refuses to continue until it passes — run that, and keep reading so you know what it's gating. `node-return --check` reports the gates without changing anything.

```bash
# 1. Power it on. On the returning node:
pvecm status                      # Quorate: Yes, Total votes: 3
corosync-cfgtool -s               # LINK 0 and LINK 1 both OK
timedatectl                       # "System clock synchronized: yes"
zpool status                      # apps and db ONLINE, imported cleanly

# 2. Align versions BEFORE moving any workload onto it
apt update && apt dist-upgrade
reboot                            # if a new kernel landed
pveversion -v                     # compare against pve1 — they should match

# 3. Now let replication catch up
pvesr status
pvesr run --id 1022-0             # force each job rather than waiting out the backoff
                                  # this is the big transfer; watch it to OK

# 4. Confirm the space comes back on the surviving node once the old snapshot is released
zpool list

# 5. Only now move workload back — live, no downtime
qm migrate 1021 pve2 --online

# 6. The node sat idle for two weeks; this is the right moment
zpool scrub apps && zpool scrub db
```

**If replication refuses with `no common base to restore the job state`,** the incremental path is gone (snapshots pruned, pool recreated, job edited). Delete the job, remove the stale volumes on the returning node, recreate the job per Stage 12 — you get a full transfer, which is slower but not a problem. Nothing is lost either way; the authoritative copy is the running one.

⚠️ **Do not start the VM on the returning node "just to check that it works."** Its disks hold a two-week-old copy. The VM's config lives under `/etc/pve/nodes/pve1/`, so the cluster won't do this on its own — but a manual `qm start` on the wrong node would bring up Postgres on stale data. Wait for `pvesr status` to report OK, then migrate.

> **HA does not fail back, by design.** [15.1](../ha/15-ha.md#151-which-vms-get-ha) adds 1021 and 1022 as plain HA resources with nothing in Rules, so they stay on pve1 until you migrate them yourself. That's the behavior you want — automatic failback toward a node whose replica is two weeks stale is strictly worse than doing it by hand after step 3. But it holds *only* while that panel stays empty: every resource already carries `failback: 1`, so the first node affinity rule you add turns this paragraph false unless you clear the flag with it ([15.5](../ha/15-ha.md#155-rules--and-the-failback-flag-that-is-on-by-default)).

One thing that went right by accident and shouldn't be relied on: backups kept working through the outage because the USB drive lives on pve1 ([17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive)) and every VM was already there. Had you added the optional second drive on pve2, that job would have been failing silently for two weeks — which is what the notification target in [15.3](../ha/15-ha.md#153-notifications) is for.

## 16.3 Firmware — detect always, flash rarely

Firmware is the layer the rest of this guide leaves implicit, and it divides along the line that actually matters: who carries the risk.

**Runtime blobs** — `pve-firmware`, `intel-microcode` — are apt packages the kernel pushes into the device at every boot. They're undone by reinstalling the old package, re-applied automatically on any rebuild, and cost nothing beyond a reboot you were taking anyway. Take them automatically; [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) sets that up on all three machines.

**Flashed firmware** — the system BIOS and everything else with a writable chip — is written once and stays written. It survives a reinstall, it is in no backup ([`pve-config-backup`](../scripts/README.md) archives the config, not the chip), and a bad flash hands you a node that doesn't POST. Take it deliberately, on a reason, one machine at a time.

| Layer | Where | Updated by |
|---|---|---|
| CPU microcode | all three | **apt** — `intel-microcode`, early-loaded at boot |
| Driver blobs | all three | **apt** — `pve-firmware` on the nodes, `firmware-*` on the QDevice |
| System BIOS + ME/CSME | all three | flashed |
| NVMe firmware | 3 + 3 + 1 drives | flashed — `nvme-cli`, occasionally LVFS |
| X550-T2 NVM | pve1 | flashed — Intel's NVM Update Utility; needs a power cycle, not a reboot |
| TB4 controller + 10G adapter | pve2 | flashed — the controller via LVFS, the adapter via the vendor's own tool |
| EC / battery | pve2 + QDevice | flashed, inside the BIOS capsule — [Stage 3](../setup/03-laptop-node.md)'s battery shutdown rides on it, on both laptops |

### Detection

`fwupd` is the radar, on all three machines ([2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) installs it). It refreshes LVFS metadata on its own timer; you only read the result:

```bash
fwupdmgr get-devices          # every part it can see, with the version running now
fwupdmgr refresh --force
fwupdmgr get-updates          # what LVFS has that this box doesn't
```

> **Nothing reported is not the same as up to date.** Lenovo, HP and Dell publish much of their business hardware to LVFS — which, in this build, is all three machines — while generic mini PCs and consumer boards almost never do. `fwupdmgr get-devices` settles it per box in seconds — one that lists a *System Firmware* device with a version is covered and will keep telling you the truth on its own; one that shows only its NVMe and TPM is not, and the vendor's support page is the only feed it has.

What fwupd can't answer, or can't see at all:

```bash
dmidecode -s bios-version; dmidecode -s bios-release-date
dmidecode -s system-product-name      # the machine type the vendor's download page asks for
nvme list                             # FW Rev column, per drive
ethtool -i enp1s0f0 | grep firmware   # the X550's NVM version (pve1)
boltctl list                          # the Thunderbolt controller and what's hanging off it (pve2)
grep -m1 microcode /proc/cpuinfo      # the microcode revision actually loaded
```

[`cluster-health`](../scripts/README.md) carries one line for this — pending updates plus the running BIOS version — so a covered machine reports itself daily. An uncovered one is a calendar item: check the vendor's page **quarterly**, in the same sweep as [18.7](../ha/18-failover.md#187-health-checks-worth-running-periodically). Checking quarterly is not the same as flashing quarterly, which is the next part.

### When to flash

| Trigger | Flash? |
|---|---|
| Microcode or a driver blob lands in apt | **Always**, unattended — it rides the normal `apt full-upgrade` |
| A published vulnerability you're actually exposed to — CSME, TPM, a microcode erratum | Yes, in a scheduled window |
| A bug you are hitting — the 10G link dropping, an NVMe not enumerating, the laptop not waking on AC | Yes; in practice this is the common one |
| New or replacement hardware, before it joins ([Stage 19](19-node-replacement.md)) | Yes — the one moment it's free |
| "There's a newer version out" | **No** |

That last row is the whole policy, and it deliberately contradicts the instinct that keeps `apt full-upgrade` on a weekly rhythm. The asymmetry is the reason: this cluster is built to survive a node dying at random ([Stage 18](../ha/18-failover.md)), but a flash takes a node down at a moment *you* chose, for a benefit you couldn't name, and occasionally doesn't give it back. Update the software aggressively and the chips only when something asks you to.

### Three routes to a flash

**A — `fwupdmgr update`, in-band.** The cleanest when the machine is on LVFS: one command everywhere, versions recorded, no stick to write. Two things to check first on a Proxmox node, both about the ESP:

```bash
findmnt /boot/efi          # mounted → fwupd behaves as it does anywhere else
proxmox-boot-tool status   # if this lists ESPs, they are deliberately NOT mounted
```

This build installs on ext4/LVM ([Stage 1](../setup/01-installation.md)), so the first is what you'll see and there is nothing to do. On a ZFS-root install the second applies: mount the ESP yourself, point fwupd at it with `OverrideESPMountPoint=/boot/efi` in `/etc/fwupd/uefi_capsule.conf`, and run `proxmox-boot-tool refresh` afterwards. Separately, with Secure Boot left on (pve1, [0.1](../setup/00-preparation.md#01-bios)), fwupd's EFI helper has to be signed — `apt install fwupd-amd64-signed` if it didn't come in with the rest.

> **Take dbx updates last.** fwupd also offers the UEFI revocation list, which is worth keeping current — but it revokes old signed bootloaders, so applying it to a host whose own bootloader is behind is a way to make a node unbootable. `apt full-upgrade` and reboot first, then dbx.

**B — the vendor's own media.** The route each vendor actually tests, and the one to prefer for the *system BIOS* on a machine you can't afford to lose:

- **pve1** — Lenovo ships a bootable BIOS image; write it with Rufus in DD mode exactly like the install stick in [0.2](../setup/00-preparation.md#02-usb-stick), boot it, flash, remove it.
- **pve2** — HP's SoftPaq, applied from the UEFI firmware-update screen. It refuses to run without AC connected *and* the battery above a threshold, which on a node that lives plugged in means charging it first.
- **QDevice** — a Dell Pro, so it's on LVFS and route A is the normal answer ([8.7](../cluster/08-qdevice.md#87-firmware-baseline)). The fallback is Dell's own BIOS executable copied to a FAT32 stick and launched from the F12 one-time-boot menu's *BIOS Flash Update* entry — no Windows needed.

**C — per component, only when that component is the problem.** `nvme fw-download` + `nvme fw-commit` for an SSD (with the node evacuated), Intel's `nvmupdate64e` for the X550 — that one needs a full **power cycle** or the new NVM doesn't take. The TB4 10G adapter usually has a Windows-only updater; treat it as a device you replace rather than one you maintain.

**The short version:** fwupd everywhere as the radar, the vendor's own media as the tool for the system BIOS.

### The window, and the order

A flash is two to four reboots and at least one stretch where the machine looks dead, so it's [16.1](#161-planned-maintenance-same-day) — not something you slip between two commands. The order is what makes it safe:

1. **QDevice first.** With both nodes up you keep 2 of 3 votes and stay quorate, so the cluster doesn't notice. What pauses is the WAL stream ([Stage 13](../ha/13-wal-stream.md)): the slot retains WAL on 1022 while it's away and `pg-receivewal` resumes at boot. Fine for minutes — and if it ever becomes hours, that's exactly what [`backup-verify`](../scripts/README.md) flags.
2. **pve2 next** — evacuate it (Bulk Migrate → pve1), flash, reboot, let it rejoin.
3. **Then wait.** Give the new firmware a week of real running before pve1 gets it. Firmware bugs surface as intermittent, hard-to-attribute misbehaviour — a link that drops once a day, a drive that vanishes under load — and you want a known-good node underneath while you work out which it is.
4. **pve1 last**, the same way.

⚠️ **Never both machines in one window, and never while the peer is down.** Same rule as [20.3 step 3](20-upgrades.md#step-3-preconditions-before-you-start), for the same reason: it removes the safety net at the moment you're most likely to need it.

### After every flash — five minutes that save an evening

A flash routinely resets the firmware settings to defaults, and this build depends on four of them. Walk [0.1](../setup/00-preparation.md#01-bios) again before letting the machine back into service — all of it, not just the setting you happen to remember:

| Re-check | Why it bites here |
|---|---|
| **VMD/RST still disabled** | Re-enabled by a settings reset, Linux stops seeing the NVMe drives individually — the node won't boot, or boots without `apps` and `db`. The [2.3](../setup/02-post-install.md#23-hardware-check) symptom, except months later and with a cluster attached |
| **VT-x / VT-d on** | Without them, no VM starts at all |
| **Restore on AC / Wake on AC** | Lost silently, and you find out at the *next* power cut, when the machine doesn't come back by itself — the tail of the [4.4](../setup/04-ups.md#44-the-long-outage-timeline-end-to-end) timeline, QDevice included |
| **A boot entry exists** | A flash can wipe the UEFI boot entries. Keep the Proxmox stick nearby; `efibootmgr` puts the entry back, and the ESP's fallback path boots the node in the meantime |

Then, before moving any workload back:

```bash
ip -br link           # interface names unchanged?
corosync-cfgtool -s   # LINK 0 and LINK 1 both OK
cluster-health
```

⚠️ **The one to be genuinely afraid of is interface renaming.** A BIOS update that changes ACPI slot naming renames the NICs, `/etc/network/interfaces` then configures nothing, and the node comes back with **both corosync rings down and no management address** — unreachable over the network, from a change you made on purpose. Save `ip -br link` and `/etc/network/interfaces` *before* the flash ([`pve-config-backup`](../scripts/README.md) already archives the second one nightly), and don't start one without physical console access to that machine. The way back is the one from [19.3 step 5](19-node-replacement.md#193-approach-b--transplanting-the-disks) — new names into `/etc/network/interfaces` at the console, `ifreload -a` — which is worth reading once *before* you're sitting in front of a silent node.
