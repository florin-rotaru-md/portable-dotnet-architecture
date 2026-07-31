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
