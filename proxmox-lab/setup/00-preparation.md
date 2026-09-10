# Stage 0 — Preparation

*Part of the [Proxmox lab guide](../README.md).*

## 0.1 BIOS

**pve1 (ThinkStation, F1 at boot):** VT-x → Enabled; VT-d → Enabled; **VMD/RST → Disabled** (otherwise Linux won't see the NVMe drives individually — on pve1 that means the one Kingston NVMe that becomes pool `db`; its other two drives are SATA SSDs and were never behind VMD, see [2.3](02-post-install.md#23-hardware-check)); **After Power Loss / Restore on AC → Power On** (so the node comes back by itself when power returns — the tail end of the long-outage chain in [Stage 4](04-ups.md#44-the-long-outage-timeline-end-to-end)); Secure Boot can stay on.

**pve2 (ZBook, F10 at boot):** VT-x/VT-d → Enabled; RST/VMD → AHCI-NVMe if the option exists; also look for a "Wake on AC / Power on AC" setting → Enabled (so the laptop powers back on when power returns).

**QDevice (Dell Pro 14, F2 at boot):** SATA/NVMe operation → **AHCI/NVMe, not "RAID On"** — Dell's default hides the disk from the Debian installer entirely; plus the same power-on-after-AC-loss setting. No VT-x/VT-d needed, it runs no VMs. Details and the rest of its build: [8.1](../cluster/08-qdevice.md#81-the-box-and-its-os).

> **Every one of these settings is reset by a BIOS update.** That's not a reason to avoid firmware updates, it's a reason to come back to this section after each one — the checklist is in [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely), along with which of them fails loudly and which fails months later.

## 0.2 USB stick

Download the Proxmox VE ISO (latest 9.x): https://www.proxmox.com/en/downloads
Write it with Rufus (DD Image mode).

## 0.3 Network plan

No 10G switch (they're still expensive for what they'd add here). Instead: **one direct cable between the two nodes, two cables per host, zero extra hardware beyond the Thunderbolt adapter** — and that one direct cable is normally *out*, not standing infrastructure: it goes in for a migration and comes out afterwards ([5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)).

| Link | Cabling | Network | Role |
|---|---|---|---|
| **1G** | the LAN port of each host → existing router / home switch — pve2's onboard NIC, but on pve1 **X550 port 2**, not the onboard one (see below) | 192.168.0.11 / .12 /24, gw 192.168.0.1 | `vmbr0`: management + VM traffic + internet; **migration + replication**; corosync **Link 0** — the ring the cluster actually runs on |
| **10G** | pve1 X550 port 1 ↔ pve2 TB adapter, **direct cable, no switch** | 10.10.10.1 / .2 /24, **no gateway** | corosync **Link 1** — the redundant ring; plus per-migration throughput when the cable is in ([5.4](05-network.md#54-using-the-10g-link-for-a-migration)). **On demand: normally unplugged** ([5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)) |
| **1G (QDevice)** | Dell Pro 14 onboard NIC, or a USB-C adapter → same router / switch | 192.168.0.10 /24, gw 192.168.0.1 | Third corosync vote (qnetd) + Postgres WAL receiver. Wired only — never Wi-Fi ([8.1](../cluster/08-qdevice.md#81-the-box-and-its-os)) |

**Why the primary ring is on the 1G LAN and the direct cable carries only the second one.** It was not chosen; `pvecm` decided it at create-and-join time. The address you build the cluster on becomes `ring0_addr` unless you pass `link0=` explicitly at that moment, and here the management address took it. `/etc/pve/corosync.conf` reads `ring0_addr: 192.168.0.x` / `ring1_addr: 10.10.10.x` on both nodes, and `datacenter.cfg` pins both `migration` and `replication` to `192.168.0.0/24` — an ordinary migration has never touched the direct cable, and deliberately still doesn't: the 10G path is requested per migration instead ([5.4](05-network.md#54-using-the-10g-link-for-a-migration)). Name the cost plainly. A routine migration or replication runs at the 1G ceiling (~118 MB/s): 8 GiB of guest memory is about seventy seconds in a single pass, and a live migration re-copies whatever the guest dirties while that pass runs, so call it two to three minutes end to end against roughly twenty seconds over the cable — which is exactly what the cable is plugged in for when a move carries real data. And the one ring corosync actually uses shares a wire with VM traffic, every replication job — 1022's runs every minute — and the QDevice's votes at `.10`: lose the router or that switch and you lose the ring *and* the third vote in the same instant. With Link 1 unplugged — the normal state here — each node is then left at 1 vote of 3, non-quorate, and with fencing armed **both** nodes self-fence; the table in [5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected) is where that trade is written down rather than left to be discovered mid-outage. There is also no bandwidth limit set at all (`pvesh get /cluster/options` returns no `bwlimit`), which mattered little on a dedicated cable and matters on a shared ring: a large replication can jitter the token. Two rules follow. **`corosync-cfgtool -s` is the authority on which number is which** — every "Link 0" in this repo means the number that command prints on the node, not the faster cable. And **turning the mapping round is a planned change, not a documentation edit**: `corosync.conf` on both nodes with a `config_version` bump (the same edit-a-copy-then-move procedure as [collapsing to one network](../troubleshooting.md#optional--collapsing-everything-onto-one-network)), on a live cluster with the watchdog armed. It moves nothing else: migration and replication are pinned in `datacenter.cfg` by *subnet*, so they neither know nor care which ring carries which number.

**What you give up versus a 10G switch:** cross-node VM-to-VM traffic runs at 1G — and so, on an ordinary day, do migration and replication, since both are pinned to `192.168.0.0/24`. For *guest* traffic this almost never matters: `app` and `postgres` normally live on the same node (traffic never leaves the host), and after a failover they land on the same surviving node together, so only a transient split exposes it. For migration it is the difference between minutes and seconds, which is why [5.4](05-network.md#54-using-the-10g-link-for-a-migration) exists as a deliberate per-move override rather than a permanent setting.

**What you gain:** no switch to buy, no switch to power, and no single device sitting between two redundant nodes.

**Other notes:**
- **On pve1 the LAN cable is in X550 port 2, and the onboard 1G is what stays empty** — the reverse of the obvious reading of the table above, and it is how the machine is actually built: `vmbr0` is bridged onto `nic2` (X550 port 2) and the onboard I219 (`nic0`) sits `manual` with no carrier. Plan the *addresses* from this table and pick the *port* by carrier, never by name ([5.1](05-network.md#51-management-network--vmbr0-on-the-port-that-holds-the-lan-cable)). What that leaves spare for a future third node is therefore a 1G RJ45, not a second 10G run: another point-to-point ring would need X550 port 2 back, i.e. moving the LAN cable and the bridge port together on the node whose web UI you are moving.
- Address plan, all on 192.168.0.0/24 — infrastructure low, guests from `.20` up, deliberately **above** the hosts so nothing guest-side ever sorts below a hypervisor: `.10` QDevice, `.11` pve1, `.12` pve2; then `.20` control (1020), `.21` app (1021), `.22` postgres (1022), `.23` monitoring (1023). All three infrastructure addresses are **static on the machine and outside the router's DHCP pool** — the QDevice's `.10` in particular is not a suggestion you can vary: it is written into `corosync.conf` by `pvecm qdevice setup` *and* into 1022's `pg_hba.conf` + UFW as a `/32` ([8.1](../cluster/08-qdevice.md#81-the-box-and-its-os)), and moving it later breaks the third vote and the WAL stream silently. **The rule: VM `10NN` lives at `.NN`** — read the ID, know the address — and scratch clones extend it: spare ID `11NN` takes spare IP `.1NN` (the upgrade rehearsal's 1122 at `.122`). The guest trio `.21`/`.22`/`.23` is the same one `native/example` and `hyper-v` use — one addressing dialect across the whole repo.
- Keep MTU at 1500 to start. Jumbo frames (MTU 9000) are genuinely tempting on a dedicated point-to-point link like this one and carry little risk there, since nothing else shares the segment — but leave it until everything else is proven.
- **Not an option while the cable is on demand:** a second bridge (`vmbr1`) on the 10G link, giving `app` and `postgres` a second NIC each, would put database traffic on a wire that is normally unplugged — and on pve2 on an interface that does not exist at all while the dock is out ([5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)). A guest path that is down more often than up is worse than no second path. It becomes worth considering only if the cable ever goes back to being permanent.

**Fallback if the Thunderbolt adapter isn't ready yet:** run everything over the 1G network, single link, skip [5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected). Adding the cable afterwards is cheap on the interface side and not cheap on the corosync side: a second ring means editing `corosync.conf` on both nodes with a `config_version` bump on a live cluster with the watchdog armed — the planned change described above, whose price for getting it wrong is a fenced node and rebooted guests. Nothing in Datacenter → Options changes with it, because migration and replication stay pinned to `192.168.0.0/24` either way and the fast path is asked for per move ([5.4](05-network.md#54-using-the-10g-link-for-a-migration)).

## 0.4 Physical cabling — what goes where

```
                    ┌──────────────────────────┐
                    │   Existing ISP router     │  192.168.0.1
                    │  (gateway + DHCP + 5G     │
                    │   failover)               │
                    └──┬───────────────────┬───┘
                    ①  │                   │  ②
                 Cat5e/6                Cat5e/6
                       │                   │
        ┌──────────────┴───┐        ┌──────┴─────────────┐
        │  pve1            │        │  pve2              │
        │  ThinkStation    │        │  ZBook Fury G10    │
        │                  │        │                    │
        │  X550-T2 port 2 ─┘        └───── onboard 1G    │
        │                  │        │                    │
        │  X550-T2 port 1 ─┼── ③ ───┼─ TB4 → 10GbE adapt.│
        │  onboard 1G      │        │                    │
        │     (unused)     │        │                    │
        └──────────────────┘        └────────────────────┘
                    ③ Cat6a, DIRECT, no switch

        ┌──────────────────┐
        │  QDevice         │  192.168.0.10 — static, wired, never Wi-Fi
        │  Dell Pro 14     │
        │  onboard 1G ─────┼── ④ ──→ same router / switch as ① and ②
        └──────────────────┘
```

**Cable checklist:**

| # | From | To | Type | Purpose |
|---|---|---|---|---|
| ① | pve1 — **X550-T2 port 2**, not the onboard RJ45 | Existing router / home switch | Cat5e or better | `vmbr0`: management, VM traffic, internet, **migration + replication**, and corosync **Link 0**. pve1's onboard I219 is the port left unused ([5.1](05-network.md#51-management-network--vmbr0-on-the-port-that-holds-the-lan-cable)) |
| ② | pve2 — **onboard** 1G RJ45 (here the onboard port really is the one) | Existing router / home switch | Cat5e or better | Same role as ①: `vmbr0` and corosync **Link 0** |
| ③ | pve1 — X550-T2 **port 1** | pve2 — Thunderbolt→10GbE adapter (in a **TB4** port) | **Cat6a** | Direct, no switch. Carries corosync **Link 1** and nothing else — `datacenter.cfg` pins migration and replication to `192.168.0.0/24` ([0.3](#03-network-plan)), and the 10G path is asked for per move ([5.4](05-network.md#54-using-the-10g-link-for-a-migration)) |
| ④ | QDevice — **onboard** 1G RJ45 (or a USB-C adapter) | Existing router / home switch | Cat5e or better | Third corosync vote (qnetd) + WAL receiver, at static `192.168.0.10` ([8.1](../cluster/08-qdevice.md#81-the-box-and-its-os)) |

**Power:** pve1 on the UPS — it's the only machine of the three with no battery of its own, so it's the one that needs the runtime. pve2 (the ZBook) and the QDevice (the Dell Pro) can go on the UPS too, but both are already covered by their own batteries and each one you leave off buys pve1 more of the 5h. No switch to worry about — one less thing on the UPS and one less failure domain.

**Notes on the physical side:**
- **Cable ③ needs no crossover cable.** Both ends do Auto MDI/MDIX. Use Cat6a here — Cat5e negotiates 10G only over very short runs, and Cat6a is cheap enough to remove the doubt.
- **Which TB4 port on the ZBook:** either works; prefer the one not shared with your dock or charger to reduce contention. Have the adapter plugged in for the install and for [5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)'s one-time configuration — and know that unlike every other NIC in this build, this one can **vanish** rather than go down. It arrives through the `atlantic` driver as a hot-pluggable PCIe device (`enp62s0` here), so when the dock is unplugged, resets, or the Thunderbolt link drops, the interface leaves `ip link` altogether: pve2's `address 10.10.10.2/24` stanza has nothing left to bring up, and `ethtool` answers `No such device` where pve1's X550 at the far end would still say `Link detected: no`. Every symptom the rest of this guide teaches you to look for — an interface that is down, a speed that is wrong — is therefore absent, and the loss shows only in `corosync-cfgtool -s`, as `disconnected` on the ring carrying `10.10.10.0/24`. Two commands settle it, and they are worth running any time the ZBook has been moved or re-docked: `ip -br link | grep enp62s0` on pve2 (absent = the dock is gone, not the cable) and `corosync-cfgtool -s` on either node.

  **On this build that absence is the normal state, not a fault.** The cable is plugged in for a migration and unplugged afterwards ([5.2](05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), so `enp62s0` usually does not exist on pve2 and link 1 usually reads `disconnected` — which is why the repo's `cluster-health` classifies the rings per link through `ON_DEMAND_LINKS` rather than treating link 1's absence as a fault. **That is the repo's copy.** The one installed on both nodes is still the 2026-09-04 build: it has no such list, and under cron's bare `/usr/bin:/bin` it never even finds `corosync-cfgtool` (which lives in `/usr/sbin`), so the nightly report has printed `[ OK ] corosync: all links healthy` every morning regardless — for link 0 as much as for link 1. It starts saying anything true about the rings the day [2.4](02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run on each node, and not before. What that costs is ring redundancy and only that: migration and replication are pinned to `192.168.0.0/24`, and quorum still has ring 0 plus the QDevice. The bill arrives only if the LAN itself dies, and 5.2 has the table.
- **Label the cables with the ring number `corosync-cfgtool -s` reports, not the one you intended.** Link numbers are fixed in `corosync.conf` when the cluster is created and cannot be renumbered afterwards, so the cable that was *meant* to be Link 0 can end up as Link 1 — as ③ did here. At 3AM during an incident, "which one is the corosync link" is not a question you want to answer by tracing, and a cable mislabelled `Link 0` is worse than an unlabelled one: it turns a lost redundant ring into what looks like a lost primary ring, and sends you fixing quorum and migration that were never affected.
- **Don't route the 10G link through the router.** Its whole value is being a private, quiet, point-to-point path.

## 0.5 Keys — generate all of them now

Five SSH key pairs carry this build, and left to the natural order they'd be created at four different moments, on four different machines, each with a "copy this to your password manager" note attached — which is how that step gets postponed four times and done zero. Twenty minutes here, before any hardware is powered on, and every later stage becomes *install the one it needs*.

The stronger reason is [9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)'s rule: when a machine dies, **restoring its old key beats generating a new one**, because the old public half is already in `authorized_keys` on every VM while a fresh pair opens nothing. That rule is only actionable if the pair exists somewhere outside the machine that died. Generating up-front is what makes "restore" the normal path later instead of a lucky one.

> **Already have some of these?** A workstation key you use elsewhere, the four pairs from an earlier build, or a lab that is already running and a machine that is not — then this section is not the one you want. Don't regenerate: [Reuse](#reuse--installing-a-pair-that-already-exists) at the end covers where each private half goes, how to confirm it is the right one, and when reusing is the wrong answer.

### The five

| Key | Private half ends up on | What it opens | Created / installed in |
|---|---|---|---|
| `pve1_root` | pve1, `/root/.ssh/id_ed25519` | every VM — the only key that can be there *before* the VM exists | here → [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) |
| `pve2_root` | pve2, `/root/.ssh/id_ed25519` | every VM, from the other node | here → [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) |
| `workstation` | your PC, `~/.ssh/id_ed25519` | every VM, directly — this is *you* | here, if it doesn't exist yet |
| `breakglass` | **nowhere in the lab** — password manager + paper only | every VM, on the day nothing else does | here; only its public half ever enters the lab |
| `devops` | VM 1020, as `~/.ssh/id_ed25519_devops` | 1021 / 1022 / 1023 — Ansible's identity, used on every playbook run; in `vm_keys.pub` like the rest, so every VM trusts it from birth | here → [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) |

**All five here — this section is required, and it is the only place a key is ever generated.** The rule: every pair is created in this one sitting, before any machine that will hold it exists, and its permanent copy is the password-manager item made below. Every later stage only *installs* a pair that already exists, so no later stage ever raises "when was this generated, where does it live, is there a backup" — the answer is always the same: *0.5; password manager*. A rebuilt pve1 has to open the VMs it left behind, a rebuilt 1020 has to keep running playbooks against 1021–1023, and both recoveries are the same move: re-install the pair from the password manager ([21.5](../operations/21-credentials.md#215-recovery-scenarios--what-losing-each-thing-actually-means)). (The `devops` pair *could* instead be born on 1020 and never copied out — but that would make it the one key with a different generation-and-storage story, and a uniform "every pair comes from 0.5 and lives in the password manager" is worth more than the marginal exposure of one more vault item.)

The **public** halves become one file on pve1, `vm_keys.pub`, which the template hands to every clone at first boot ([9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)) — all five of them, from here, so the list is complete before the first VM exists and is never appended to afterwards. A VM created on day 300 is then born opening to all five, including the break-glass key whose private half never touched the lab.

### Generate — Windows (PowerShell)

```powershell
# your own identity, if you don't have one yet
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519")) {
    ssh-keygen -t ed25519 -C "workstation" -f "$env:USERPROFILE\.ssh\id_ed25519"
}

# the lab's four, in a staging folder that lives until Stage 10 installs the last of them
New-Item -ItemType Directory -Force "$env:USERPROFILE\lab-keys" | Out-Null
cd "$env:USERPROFILE\lab-keys"
ssh-keygen -t ed25519 -N '""' -C "pve1-root"    -f .\pve1_root
ssh-keygen -t ed25519 -N '""' -C "pve2-root"    -f .\pve2_root
ssh-keygen -t ed25519 -N '""' -C "devops"       -f .\devops
ssh-keygen -t ed25519         -C "break-glass"  -f .\breakglass      # type a passphrase here
Copy-Item "$env:USERPROFILE\.ssh\id_ed25519.pub" .\workstation.pub
```

`-N '""'` is not a typo: PowerShell eats a plain `-N ""` before `ssh-keygen` ever sees it, and you get an interactive prompt instead (harmless — press Enter twice). Windows ships OpenSSH, so nothing needs installing; if you later use a private key from Windows directly, expect `ssh` to refuse one whose ACL is too open — `icacls key /inheritance:r /grant:r "${env:USERNAME}:R"` fixes it (the braces matter: `"$env:USERNAME:R"` parses as one nonexistent variable and expands to an empty string).

### Generate — Linux / macOS

```bash
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -C "workstation" -f ~/.ssh/id_ed25519

mkdir -p ~/lab-keys && cd ~/lab-keys
for k in pve1_root pve2_root devops; do
    ssh-keygen -t ed25519 -N "" -C "$k" -f "./$k"
done
ssh-keygen -t ed25519 -C "break-glass" -f ./breakglass      # type a passphrase here
cp ~/.ssh/id_ed25519.pub ./workstation.pub
```

Either way `~/lab-keys` ends up with nine files: four pairs plus `workstation.pub`.

### Passphrases — one yes, the rest no

`breakglass` gets a passphrase and the others don't, and the asymmetry is the whole point. The lab keys live on machines whose own access is already the boundary — the Proxmox root password, or a VM you had to log into first — and one of them, `devops`, is used by every unattended Ansible run, where a passphrase means an agent to keep alive or a playbook that hangs. `breakglass` is the opposite: it never sits on a lab machine, the only place it can leak from is your password manager, and its entire job is to still work on the day everything else is gone. Your workstation key is your call — `ssh-agent` makes a passphrase cheap there.

### Where they go — before you install anything

**One password-manager item per key, private and public half attached as files** (attachments, not pasted text — a mangled newline in a private key is a bad thing to discover during a recovery). Name them exactly as above so [21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives)'s inventory reads back cleanly. Four items, then: `pve1_root`, `pve2_root`, `devops`, `breakglass` — plus your workstation key if you keep it there. Every pair now has a copy that outlives its machine, which is what every recovery row in [21.5](../operations/21-credentials.md#215-recovery-scenarios--what-losing-each-thing-actually-means) quietly assumes.

Two deliberate exceptions to "all in one place", both from [21.3](../operations/21-credentials.md#213-the-rule-recovery-credentials-must-live-outside-the-thing-they-recover):

- **`breakglass` goes somewhere else** — a different vault, a different manager, or paper in another building. A break-glass key stored next to the keys it's meant to survive is decoration.
- **Paper copy:** the break-glass private key and its passphrase, alongside the two other things that are unrecoverable rather than merely inconvenient — the rclone crypt passwords ([17.6](../backup/17-backup-restore.md#176-offsite--digi-storage-via-rclone)) and the VM `--cipassword` ([21.4](../operations/21-credentials.md#214-the-console-is-the-final-safety-net--give-it-a-password)).

**Two deletions close the loop.** The break-glass private half leaves the staging folder *now*, the moment its password-manager and paper copies exist — only its public half has any further role in the lab: `rm ~/lab-keys/breakglass`, or `Remove-Item "$env:USERPROFILE\lab-keys\breakglass"`. The folder itself stays until [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) installs the `devops` pair on VM 1020 — the last private half in it to reach its machine — and is deleted there. Losing the folder early costs nothing (the password manager is every pair's home; re-download and continue), but don't leave it past Stage 10: a workstation holding both node keys is the standing skeleton-key copy [21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives) asks you not to keep.

### Then: which key, where, when

| Stage | What happens to the keys |
|---|---|
| [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) | each node gets its own pair as `/root/.ssh/id_ed25519`; pve1 also receives all five public halves |
| [9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults) | those five public halves become `vm_keys.pub` → `qm set 9000 --sshkeys` → every clone from here on is born trusting all five |
| [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) | the `devops` pair is installed on 1020 as `~/.ssh/id_ed25519_devops` — nothing to generate, push, or append; its public half has been in `vm_keys.pub` since 9.4. `~/lab-keys` is deleted here |
| [Stage 11](../vms/11-bootstrap.md) → [21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring) | the same five public halves go into `ansible_ssh_public_key` + `ansible_ssh_extra_public_keys`, and Ansible owns the list from then on |

The last row is the handover that matters: `vm_keys.pub` decides who can open a VM on its *first* boot, Ansible decides it forever after. A key that's in one list and not the other is the whole class of surprise this build can produce — see [21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring).

### Reuse — installing a pair that already exists

Everything above is written for the first build. Afterwards, nearly every time you touch a key you are *installing* one that already exists rather than making one: a new workstation, a rebuilt node, a re-created 1020. [9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)'s rule is what makes that the default rather than the exception — a fresh pair opens nothing, the old one already opens everything.

**The whole operation is putting the private half back.** Its public half is already in `vm_keys.pub`, in `authorized_keys` on every VM, and — since [Stage 11](../vms/11-bootstrap.md) — in the list Ansible reconciles. So there is no `ssh-copy-id`, no playbook run, no console session, and no window in which a machine is unreachable. That is also exactly why the mistake is tempting: generating a fresh pair *feels* cheaper than finding the old one, right up to the point where seeding it costs you a trip through [21.5](../operations/21-credentials.md#215-recovery-scenarios--what-losing-each-thing-actually-means).

| The pair | Goes back to | As | Same install as |
|---|---|---|---|
| `workstation` | your new PC | `~/.ssh/id_ed25519`, mode 600 | — |
| `devops` | a rebuilt 1020 | `~/.ssh/id_ed25519_devops`, mode 600 | [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) |
| `pve1_root` / `pve2_root` | a rebuilt node | `/root/.ssh/id_ed25519`, mode 600 | [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) |
| `breakglass` | nothing — it is never installed | used in place: `ssh -i ./breakglass`, then the local copy is deleted | — |

**Windows (PowerShell)** — replace `<source>` with the folder you downloaded the attachments into:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
Copy-Item <source>\id_ed25519     "$env:USERPROFILE\.ssh\"
Copy-Item <source>\id_ed25519.pub "$env:USERPROFILE\.ssh\"
icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "${env:USERNAME}:R"
```

The `icacls` line is not optional: OpenSSH refuses a private key whose ACL is too open, with *UNPROTECTED PRIVATE KEY FILE*, and it refuses before it ever tries the key — which reads like "the key is wrong" and is not. The braces matter too, `"$env:USERNAME:R"` parses as one nonexistent variable and expands to an empty string. Git Bash reads the same `%USERPROFILE%\.ssh`, so there is nothing to duplicate for it.

**Linux / macOS:**

```bash
install -m 700 -d ~/.ssh
install -m 600 <source>/id_ed25519     ~/.ssh/id_ed25519
install -m 644 <source>/id_ed25519.pub ~/.ssh/id_ed25519.pub
```

**Confirm you installed the pair you think you did**, before drawing any conclusion about reachability:

```bash
ssh-keygen -lf ~/.ssh/id_ed25519.pub                     # on the new machine
ssh root@<node> ssh-keygen -lf /root/.ssh/vm_keys.pub    # what the lab actually trusts
```

The first fingerprint has to appear in the second list. If it doesn't, what you installed is a *different* pair, and it will open nothing however correct its permissions are — a generated key wearing a restored key's filename.

Three traps, in the order they are usually hit:

- **Copy the file; never retype it or paste it through an editor.** A BOM or a CRLF picked up on the way makes the key invalid and OpenSSH names neither in the error. A password-manager attachment or a USB stick is a transport; chat and email are not — a key that travels through them is rotated, not installed.
- **Install only the pair that machine needs.** A new workstation needs exactly two files — `id_ed25519` and `id_ed25519.pub` — and nothing else. Re-creating a full `lab-keys` folder there rebuilds precisely the standing skeleton-key copy that the two deletions above exist to prevent — and now on a machine that travels.
- **Carry `known_hosts` over as well.** With it, host-key verification keeps meaning something. Without it, the first connection to every host is trust-on-first-use, and any warning it would have raised is accepted silently.

**When reuse is the wrong answer.** If the old machine was sold, lost, or handed to someone else, its key is not an inheritance — it is an outstanding credential, and the section you want is [21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring). Go in knowing that on this build rotating the workstation key is a four-place edit rather than one playbook run: the three VMs through Ansible; 1020 by hand, because it is not in `hosts.ini`; `/root/.ssh/authorized_keys` on both nodes, which no Ansible manages; and `/root/.ssh/vm_keys.pub` on pve1, without which a VM cloned afterwards would be born not trusting you. Remove the old key only once the new one is verified in all four.

**Registering a key the lab has never seen.** A pair restored from the password manager needs none of this — its public half is already in all four places. A *new* one has to be put there, and with `ssh_authorized_keys_exclusive` on ([21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring)) appending it to a VM's `authorized_keys` by hand is undone by the next playbook run:

```bash
# 1. the three VMs - add the line to ansible_ssh_extra_public_keys in vault.yml
#    on the control node, then from native/infra/ansible:
ansible-playbook playbooks/bootstrap.yml --tags common

# 2. control-ubuntu itself - not in hosts.ini, so by hand, on 1020:
cat new.pub >> ~/.ssh/authorized_keys

# 3. root on both nodes - no Ansible here, on pve1 and pve2:
cat new.pub >> /root/.ssh/authorized_keys

# 4. clones made later - on pve1. The qm set is not optional: the template stores
#    the file's *contents*, so editing the file alone changes nothing (9.4)
cat new.pub >> /root/.ssh/vm_keys.pub
qm set 9000 --sshkeys /root/.ssh/vm_keys.pub
```

Then log in from the new machine to all six — both nodes and the four VMs — before removing the old key anywhere.
