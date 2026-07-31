# Proxmox homelab — 2 nodes, replication, live migration

A two-node Proxmox VE cluster for a self-hosted app: ZFS replication, HA with automatic failover, live migration over a direct 10G link, three backup tiers, and everything inside the VMs managed by Ansible from [`native/infra/ansible`](../native/infra/ansible). Written so it can be followed top-to-bottom by someone building this for the first time.

## Hardware

- **Node 1 `pve1`** — ThinkStation P2 Gen 2, Core Ultra 7 265, 64GB, 3× NVMe, Intel X550-T2
- **Node 2 `pve2`** — HP ZBook Fury G10 16", i9-13850HX, 64GB, 3× NVMe, Thunderbolt 4 (role: failover)
- QDevice: mini PC — Core Ultra 5 225U, 16GB DDR5, 2TB NVMe. Holds the third vote *and* the continuous WAL archive ([Stage 13](ha/13-wal-stream.md))
- ~5h UPS, router with tested 5G failover (~30s), Cloudflare Tunnel already in place

## Design decisions (vs the defaults you'd otherwise pick)

| Topic | The obvious default | This build | Reason |
|---|---|---|---|
| VM storage | LVM-Thin | **ZFS** (`apps`, `db`) | Proxmox replication works ONLY on ZFS |
| ZFS volume mode | Thick — what the *Add Storage* checkbox leaves you with | **Thin provision** (`sparse 1`) on both pools | Declared disk sizes become ceilings instead of reservations, and `discard=on` only returns freed blocks on a thin volume |
| VM CPU type | `host` | **`x86-64-v3`** | Different CPUs (Raptor Lake vs Arrow Lake) — `host` would crash a migrated VM |
| Migration network | Everything over the 1G LAN | Direct 10G cable (X550 ↔ TB adapter), no switch; 1G to the router as backup ring | Full 10G for migration/replication at zero extra cost, plus corosync redundancy |

The result, in one paragraph: two nodes joined by a direct 10G cable (corosync Link 0, migration, replication) and by the home LAN (vmbr0, corosync Link 1), with a QDevice holding the third vote. Four VMs — `1010 control` (Ansible), `1020 app` (.NET + nginx + cloudflared), `1030 postgres`, `1040 monitoring` (Loki + Grafana) — replicate between nodes every 1–30 minutes depending on the VM; HA restarts `app` and `postgres` on the surviving node in ~2–3 minutes if a node dies, while `control` and `monitoring` stay out of HA and are started by hand if their node goes down. Backups go to a USB disk nightly and encrypted to Digi Storage offsite.

## The guide

### [setup/](setup/) — from empty machines to two updated nodes

| | Covers |
|---|---|
| [Stage 0 — Preparation](setup/00-preparation.md) | BIOS settings, install USB, the network plan and why there's no 10G switch, physical cabling |
| [Stage 1 — Installation](setup/01-installation.md) | Proxmox installer choices, identical on both nodes |
| [Stage 2 — Post-install](setup/02-post-install.md) | No-Subscription repositories (click-by-click), first upgrade, hardware sanity check |
| [Stage 3 — Laptop node](setup/03-laptop-node.md) | pve2 only: lid/sleep, battery-driven clean shutdown, TLP + dynamic CPU governor |
| [Stage 4 — UPS monitoring](setup/04-ups.md) | pve1 only: NUT, clean shutdown when the UPS runs dry, the full long-outage timeline |
| [Stage 5 — Network](setup/05-network.md) | `vmbr0` on 1G, the 10G point-to-point link, the one-default-route rule |

### [cluster/](cluster/) — storage and quorum

| | Covers |
|---|---|
| [Stage 6 — ZFS pools](cluster/06-zfs-pools.md) | Identifying disks, `apps` + `db` pools — same names on both nodes, non-negotiable; thin provisioning, while the pools are still empty |
| [Stage 7 — Cluster](cluster/07-cluster.md) | Create/join with two corosync rings, migration network settings |
| [Stage 8 — QDevice](cluster/08-qdevice.md) | The third vote — mandatory for maintenance with one node down |

### [vms/](vms/) — the guests

| | Covers |
|---|---|
| [Stage 9 — Ubuntu template](vms/09-ubuntu-template.md) | The golden image, built from Canonical's cloud image: guest-agent injection, cloud-init defaults, console password, smoke test; the interactive-ISO alternative |
| [Stage 10 — The VMs](vms/10-vms.md) | Cloning 1010/1020/1030/1040, per-VM disk sizes (one `qm resize` each), Ansible control node, SSH keys |
| [Stage 11 — First Ansible bootstrap](vms/11-bootstrap.md) | Filling the VMs: inventory, the split-VM variables, the monitoring VM (Loki + Grafana), `bootstrap.yml`, verification |
| [Cloudflare Tunnel](vms/cloudflare-tunnel.md) | Why `cloudflared` runs inside the app VM, not on the host |

### [ha/](ha/) — replication, migration, failover

| | Covers |
|---|---|
| [Stage 12 — Replication](ha/12-replication.md) | Per-VM schedules — the interval *is* your data-loss window |
| [Stage 13 — WAL stream](ha/13-wal-stream.md) | Postgres WAL → QDevice, continuously: the failover minute becomes recoverable seconds, plus a 7-day any-second PITR window |
| [Stage 14 — First live migration](ha/14-live-migration.md) | The ping test |
| [Stage 15 — HA](ha/15-ha.md) | Which VMs get HA, `shutdown_policy=migrate`, notifications |
| [Stage 18 — Failover mechanics](ha/18-failover.md) | How detection/fencing/recovery actually work, the full scenario table with RTO/RPO, forcing quorum, the pre-launch test plan, periodic health checks |

### [backup/](backup/) — the three tiers

| | Covers |
|---|---|
| [Stage 17 — Backup & restore](backup/17-backup-restore.md) | USB tier, offsite (rclone + crypt) tier, the in-VM Postgres dump tier, every restore scenario A–F, post-restore checklist, restore drills |

### [operations/](operations/) — running it over the years

| | Covers |
|---|---|
| [Stage 16 — Maintenance](operations/16-maintenance.md) | Zero-downtime hardware maintenance; returning a node after a long outage (days–weeks) |
| [Stage 19 — Node replacement](operations/19-node-replacement.md) | Swapping in new hardware: clean swap vs disk transplant, step by step |
| [Stage 20 — Upgrades](operations/20-upgrades.md) | Postgres minors (automatic, by design) and majors (a project with a rehearsal); the same pattern for OS and Proxmox upgrades |
| [Stage 21 — Credentials](operations/21-credentials.md) | What authenticates what, what a restore gives back, recovery when a key is lost, the console password, key rotation via Ansible |

### [scripts/](scripts/) — speed for the operational side

One command each for the daily question (`cluster-health`), the protection question (`backup-verify`), the hosts' only backup (`pve-config-backup`), and the two riskiest procedures made guided (`node-return`, `restore-drill`). Installed on both nodes in [Stage 2.4](setup/02-post-install.md#24-install-the-helper-scripts-both-nodes); details in [scripts/README.md](scripts/README.md).

### [troubleshooting.md](troubleshooting.md) — symptom → cause, one line each

## Build checklist

The whole build, in execution order, with the two deliberate "come back later" points made explicit. Tick as you go; every line links to its stage above.

- [ ] **0** Preparation — BIOS (both nodes), USB stick, network plan, cabling
- [ ] **1** Install Proxmox — pve1, then pve2
- [ ] **2** Post-install — repos, upgrade, hardware check, **helper scripts (2.4)** — both nodes
- [ ] **3** Laptop config — pve2 only
- [ ] **4** UPS monitoring (NUT) — pve1 only
- [ ] **5** Network — `vmbr0` + 10G link, both nodes; verify one default route
- [ ] **6** ZFS pools `apps` + `db` — both nodes, identical names; **thin provision (6.1)** before any VM disk exists
- [ ] **7** Cluster — two corosync rings, migration network
- [ ] **8** QDevice — third vote
- [ ] **9** Ubuntu template from the cloud image — *(9.5's template backup needs the USB drive; postponed to the 17 line below)*
- [ ] **10** Clone 1010/1020/1030/1040, `qm resize` each to its size, control node, SSH keys
- [ ] **11** First Ansible bootstrap — the VMs get their contents; verify app + db + tunnel + Loki/Grafana
- [ ] **12** Replication schedules per VM
- [ ] **13** WAL stream to the QDevice — both ends, verified end to end
- [ ] **14** First live migration — the ping test, both directions
- [ ] **15** HA for 1020/1030 only — 1010 and 1040 deliberately stay out, `shutdown_policy=migrate`, notifications
- [ ] **17** Backups — USB drive, nightly job, offsite rclone + crypt; **now take the template backup from 9.5**
- [ ] **18.6** Pre-launch failover tests — all three, timed and written down
- [ ] **17.9** First restore drill — `restore-drill`, before going live, not after
- [ ] Go live 🎉

## Reading paths

- **Building from zero:** the checklist above, top to bottom. Stages 0–15 are a weekend; 17 and the test plan in 18.6 before going live are not optional.
- **A node just died:** [18.2](ha/18-failover.md#182-anatomy-of-an-unplanned-failover) for what's happening on its own, [18.3](ha/18-failover.md#183-scenario-table) for your row, [18.5](ha/18-failover.md#185-emergency-forcing-quorum) only if the QDevice is also down.
- **A node comes back after weeks:** [16.2](operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) — order matters: rejoin → update → replicate → migrate.
- **Locked out / lost a key:** [21.5](operations/21-credentials.md#215-recovery-scenarios--what-losing-each-thing-actually-means) has the way back for each case.
- **Restoring anything:** [17.7](backup/17-backup-restore.md#177-restore--pick-your-scenario) — pick scenario A–G, then the [post-restore checklist](backup/17-backup-restore.md#178-post-restore-checklist).
- **Something looks wrong:** `cluster-health` on either node ([what it checks](scripts/README.md)), then [troubleshooting](troubleshooting.md).

## Relationship to the rest of the repo

The Proxmox hosts are managed by hand — this guide *is* their documentation. Everything **inside** the VMs (Postgres, the .NET app, nginx, cloudflared, backups, SSH keys) comes from [`native/infra/ansible`](../native/infra/ansible), run from the control VM. That ownership boundary is deliberate; it's spelled out in [20.5](operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere). Change VM state via the playbook, not by hand — and mirror any `group_vars` change into [`native/example`](../native/example) and the hyper-v/docker example files, which are full copies meant to stay in sync.
