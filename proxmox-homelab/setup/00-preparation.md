# Stage 0 — Preparation

*Part of the [Proxmox homelab guide](../README.md).*

## 0.1 BIOS

**pve1 (ThinkStation, F1 at boot):** VT-x → Enabled; VT-d → Enabled; **VMD/RST → Disabled** (otherwise Linux won't see the NVMe drives individually); **After Power Loss / Restore on AC → Power On** (so the node comes back by itself when power returns — the tail end of the long-outage chain in [Stage 4](04-ups.md#44-the-long-outage-timeline-end-to-end)); Secure Boot can stay on.

**pve2 (ZBook, F10 at boot):** VT-x/VT-d → Enabled; RST/VMD → AHCI-NVMe if the option exists; also look for a "Wake on AC / Power on AC" setting → Enabled (so the laptop powers back on when power returns).

## 0.2 USB stick

Download the Proxmox VE ISO (latest 9.x): https://www.proxmox.com/en/downloads
Write it with Rufus (DD Image mode).

## 0.3 Network plan

No 10G switch (they're still expensive for what they'd add here). Instead: **two direct cables, two cables per host, zero extra hardware beyond the Thunderbolt adapter.**

| Link | Cabling | Network | Role |
|---|---|---|---|
| **1G** | onboard NIC of each host → existing router / home switch | 192.168.0.11 / .12 /24, gw 192.168.0.1 | `vmbr0`: management + VM traffic + internet; corosync **Link 1** (backup) |
| **10G** | pve1 X550 port 1 ↔ pve2 TB adapter, **direct cable, no switch** | 10.10.10.1 / .2 /24, **no gateway** | Migration + replication; corosync **Link 0** (primary) |

**Why corosync's primary ring sits on the 10G direct link:** it's point-to-point, deterministic, and has no other tenants competing for it beyond migration bursts — which you cap anyway. The 1G side carries VM traffic *and* the nightly offsite sync to Digi Storage, so it's the link more likely to saturate. The 1G ring stays configured as Link 1, so if the direct cable is unplugged corosync fails over instantly.

**What you give up versus a 10G switch:** cross-node VM-to-VM traffic runs at 1G. In practice this almost never matters — `app` and `postgres` normally live on the same node (traffic never leaves the host), and after a failover they land on the same surviving node together. Only during a transient split does it apply.

**What you gain:** no switch to buy, no switch to power, and no single device sitting between two redundant nodes.

**Other notes:**
- **pve1's X550 port 2 stays empty** — spare for a future third node.
- Address plan, all on 192.168.0.0/24 — infrastructure low, guests from `.20` up, deliberately **above** the hosts so nothing guest-side ever sorts below a hypervisor: `.11` pve1, `.12` pve2, `.13` QDevice (any fixed IP works — the guide writes `<qdevice-ip>` where it's needed); then `.20` control (1020), `.21` app (1021), `.22` postgres (1022), `.23` monitoring (1023). **The rule: VM `10NN` lives at `.NN`** — read the ID, know the address — and scratch clones extend it: spare ID `11NN` takes spare IP `.1NN` (the upgrade rehearsal's 1122 at `.122`). The guest trio `.21`/`.22`/`.23` is the same one `native/example` and `hyper-v` use — one addressing dialect across the whole repo.
- Keep MTU at 1500 to start. Jumbo frames (MTU 9000) are genuinely tempting on a dedicated point-to-point link like this one and carry little risk there, since nothing else shares the segment — but leave it until everything else is proven.
- **Optional later:** a second bridge (`vmbr1`) on the 10G link with its own subnet, giving `app` and `postgres` a second NIC each so DB traffic runs at 10G even when the VMs are split across nodes. Extra complexity for a rare case — skip it for now.

**Fallback if the Thunderbolt adapter isn't ready yet:** run everything over the 1G network, single link, skip Stage 5.2. Add the 10G link later without rebuilding anything — the only change is one cluster setting and the interface config.

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
        │  onboard 1G ─────┘        └───── onboard 1G    │
        │                  │        │                    │
        │  X550-T2 port 1 ─┼── ③ ───┼─ TB4 → 10GbE adapt.│
        │  X550-T2 port 2  │        │                    │
        │     (unused)     │        │                    │
        └──────────────────┘        └────────────────────┘
                    ③ Cat6a, DIRECT, no switch
```

**Cable checklist:**

| # | From | To | Type | Purpose |
|---|---|---|---|---|
| ① | pve1 — **onboard** 1G RJ45 | Existing router / home switch | Cat5e or better | `vmbr0`: management, VM traffic, internet, corosync Link 1 |
| ② | pve2 — **onboard** 1G RJ45 | Existing router / home switch | Cat5e or better | Same as ① |
| ③ | pve1 — X550-T2 **port 1** | pve2 — Thunderbolt→10GbE adapter (in a **TB4** port) | **Cat6a** | Migration, replication, corosync Link 0 — direct, no switch |

**Power:** pve1 and the QDevice on the UPS. pve2 (the ZBook) can go on the UPS too, though its own battery already covers it. No switch to worry about — one less thing on the UPS and one less failure domain.

**Notes on the physical side:**
- **Cable ③ needs no crossover cable.** Both ends do Auto MDI/MDIX. Use Cat6a here — Cat5e negotiates 10G only over very short runs, and Cat6a is cheap enough to remove the doubt.
- **Which TB4 port on the ZBook:** either works; prefer the one not shared with your dock or charger to reduce contention. Plug the adapter in *before* booting, so it's present at install and at every boot.
- **Label the cables.** At 3AM during an incident, "which one is the corosync link" is not a question you want to answer by tracing.
- **Don't route the 10G link through the router.** Its whole value is being a private, quiet, point-to-point path.

## 0.5 Keys — generate all of them now

Five SSH key pairs carry this build, and left to the natural order they'd be created at four different moments, on four different machines, each with a "copy this to your password manager" note attached — which is how that step gets postponed four times and done zero. Twenty minutes here, before any hardware is powered on, and every later stage becomes *install the one it needs*.

The stronger reason is [9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)'s rule: when a machine dies, **restoring its old key beats generating a new one**, because the old public half is already in `authorized_keys` on every VM while a fresh pair opens nothing. That rule is only actionable if the pair exists somewhere outside the machine that died. Generating up-front is what makes "restore" the normal path later instead of a lucky one.

### The five

| Key | Private half ends up on | What it opens | Installed in |
|---|---|---|---|
| `pve1_root` | pve1, `/root/.ssh/id_ed25519` | every VM — the only key that can be there *before* the VM exists | [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) |
| `pve2_root` | pve2, `/root/.ssh/id_ed25519` | every VM, from the other node | [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) |
| `id_ed25519_devops` | VM 1020, `~/.ssh/` | 1021 / 1022 / 1023 — Ansible's identity, used on every playbook run | [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) |
| `workstation` | your PC, `~/.ssh/id_ed25519` | every VM, directly — this is *you* | already there |
| `breakglass` | **nowhere in the lab** — password manager + paper only | every VM, on the day nothing else does | public half only, [21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring) |

The five **public** halves become one file on pve1, `vm_keys.pub`, which the template hands to every clone at first boot ([9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)). A VM created on day 300 is then born opening to all five, including the break-glass key whose private half never touched the lab.

### Generate — Windows (PowerShell)

```powershell
# your own identity, if you don't have one yet
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519")) {
    ssh-keygen -t ed25519 -C "workstation" -f "$env:USERPROFILE\.ssh\id_ed25519"
}

# the lab's four, in a scratch folder that gets deleted at the end of Stage 10
New-Item -ItemType Directory -Force "$env:USERPROFILE\lab-keys" | Out-Null
cd "$env:USERPROFILE\lab-keys"
ssh-keygen -t ed25519 -N '""' -C "pve1-root"    -f .\pve1_root
ssh-keygen -t ed25519 -N '""' -C "pve2-root"    -f .\pve2_root
ssh-keygen -t ed25519 -N '""' -C "devops-1020"  -f .\id_ed25519_devops
ssh-keygen -t ed25519         -C "break-glass"  -f .\breakglass      # type a passphrase here
Copy-Item "$env:USERPROFILE\.ssh\id_ed25519.pub" .\workstation.pub
```

`-N '""'` is not a typo: PowerShell eats a plain `-N ""` before `ssh-keygen` ever sees it, and you get an interactive prompt instead (harmless — press Enter twice). Windows ships OpenSSH, so nothing needs installing; if you later use a private key from Windows directly, expect `ssh` to refuse one whose ACL is too open — `icacls key /inheritance:r /grant:r "$env:USERNAME:R"` fixes it.

### Generate — Linux / macOS

```bash
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -C "workstation" -f ~/.ssh/id_ed25519

mkdir -p ~/lab-keys && cd ~/lab-keys
for k in pve1_root pve2_root id_ed25519_devops; do
    ssh-keygen -t ed25519 -N "" -C "$k" -f "./$k"
done
ssh-keygen -t ed25519 -C "break-glass" -f ./breakglass      # type a passphrase here
cp ~/.ssh/id_ed25519.pub ./workstation.pub
```

Either way you end up with nine files: four pairs plus `workstation.pub`.

### Passphrases — one yes, four no

`breakglass` gets a passphrase and the others don't, and the asymmetry is the whole point. The four lab keys live on machines whose own access is already the boundary — the Proxmox root password, or a VM you had to log into first — and one of them, `id_ed25519_devops`, is used by every unattended Ansible run, where a passphrase means an agent to keep alive or a playbook that hangs. `breakglass` is the opposite: it never sits on a lab machine, the only place it can leak from is your password manager, and its entire job is to still work on the day everything else is gone. Your workstation key is your call — `ssh-agent` makes a passphrase cheap there.

### Where they go — before you install anything

**One password-manager item per key, private and public half attached as files** (attachments, not pasted text — a mangled newline in a private key is a bad thing to discover during a recovery). Name them exactly as above so [21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives)'s inventory reads back cleanly.

Two deliberate exceptions to "all in one place", both from [21.3](../operations/21-credentials.md#213-the-rule-recovery-credentials-must-live-outside-the-thing-they-recover):

- **`breakglass` goes somewhere else** — a different vault, a different manager, or paper in another building. A break-glass key stored next to the four keys it's meant to survive is decoration.
- **Paper copy:** the break-glass private key and its passphrase, alongside the two other things that are unrecoverable rather than merely inconvenient — the rclone crypt passwords ([17.6](../backup/17-backup-restore.md#176-offsite--digi-storage-via-rclone)) and the VM `--cipassword` ([21.4](../operations/21-credentials.md#214-the-console-is-the-final-safety-net--give-it-a-password)).

**Delete `~/lab-keys` at the end of [Stage 10](../vms/10-vms.md), not before** — that's when the last private half reaches its machine. Until then it's the staging area; after that, leaving it makes your workstation a copy of every key in the lab.

### Then: which key, where, when

| Stage | What happens to the keys |
|---|---|
| [2.5](02-post-install.md#25-install-the-nodes-key-pair-both-nodes) | each node gets its own pair as `/root/.ssh/id_ed25519`; pve1 also receives all five public halves |
| [9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults) | the five public halves become `vm_keys.pub` → `qm set 9000 --sshkeys` → every clone from here on |
| [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) | `id_ed25519_devops`'s private half lands on VM 1020; its public half is already authorized everywhere |
| [Stage 11](../vms/11-bootstrap.md) → [21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring) | the same five public halves go into `ansible_ssh_extra_public_keys`, and Ansible owns the list from then on |

The last row is the handover that matters: `vm_keys.pub` decides who can open a VM on its *first* boot, Ansible decides it forever after. A key that's in one list and not the other is the whole class of surprise this build can produce — see [21.6](../operations/21-credentials.md#216-two-habits-that-make-key-loss-boring).
