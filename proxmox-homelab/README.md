# waa Proxmox homelab — 2 nodes, replication, live migration

A two-node Proxmox VE cluster for the waa app: ZFS replication, HA with automatic failover, live migration over a direct 10G link, three backup tiers, and everything inside the VMs managed by Ansible from [`native/infra/ansible`](../native/infra/ansible). Written so it can be followed top-to-bottom by someone building this for the first time.

## Hardware

- **Node 1 `pve1`** — ThinkStation P2 Gen 2, Core Ultra 7 265, 64GB, 3× NVMe, Intel X550-T2
- **Node 2 `pve2`** — HP ZBook Fury G10 16", i9-13850HX, 64GB, 3× NVMe, Thunderbolt 4 (role: failover)
- QDevice: any always-on third device (Raspberry Pi / mini PC / VM on another system)
- ~5h UPS, router with tested 5G failover (~30s), Cloudflare Tunnel already in place

## Design decisions (vs the defaults you'd otherwise pick)

| Topic | The obvious default | This build | Reason |
|---|---|---|---|
| VM storage | LVM-Thin | **ZFS** (`apps`, `db`) | Proxmox replication works ONLY on ZFS |
| VM CPU type | `host` | **`x86-64-v3`** | Different CPUs (Raptor Lake vs Arrow Lake) — `host` would crash a migrated VM |
| Migration network | Everything over the 1G LAN | Direct 10G cable (X550 ↔ TB adapter), no switch; 1G to the router as backup ring | Full 10G for migration/replication at zero extra cost, plus corosync redundancy |

The result, in one paragraph: two nodes joined by a direct 10G cable (corosync Link 0, migration, replication) and by the home LAN (vmbr0, corosync Link 1), with a QDevice holding the third vote. Three VMs — `1010 control` (Ansible), `1020 app` (.NET + nginx + cloudflared), `1030 postgres` — replicate between nodes every 1–15 minutes; HA restarts `app` and `postgres` on the surviving node in ~2–3 minutes if a node dies. Backups go to a USB disk nightly and encrypted to Digi Storage offsite.

## The guide

### [setup/](setup/) — from empty machines to two updated nodes

| | Covers |
|---|---|
| [Stage 0 — Preparation](setup/00-preparation.md) | BIOS settings, install USB, the network plan and why there's no 10G switch, physical cabling |
| [Stage 1 — Installation](setup/01-installation.md) | Proxmox installer choices, identical on both nodes |
| [Stage 2 — Post-install](setup/02-post-install.md) | No-Subscription repositories (click-by-click), first upgrade, hardware sanity check |
| [Stage 3 — Laptop node](setup/03-laptop-node.md) | pve2 only: lid/sleep, battery-driven clean shutdown, TLP + dynamic CPU governor |
| [Stage 3b — UPS monitoring](setup/03b-ups.md) | pve1 only: NUT, clean shutdown when the UPS runs dry, the full long-outage timeline |
| [Stage 4 — Network](setup/04-network.md) | `vmbr0` on 1G, the 10G point-to-point link, the one-default-route rule |

### [cluster/](cluster/) — storage and quorum

| | Covers |
|---|---|
| [Stage 5 — ZFS pools](cluster/05-zfs-pools.md) | Identifying disks, `apps` + `db` pools — same names on both nodes, non-negotiable |
| [Stage 6 — Cluster](cluster/06-cluster.md) | Create/join with two corosync rings, migration network settings |
| [Stage 7 — QDevice](cluster/07-qdevice.md) | The third vote — mandatory for maintenance with one node down |

### [vms/](vms/) — the guests

| | Covers |
|---|---|
| [Stage 8 — Ubuntu template](vms/08-ubuntu-template.md) | The golden image: install, cloud-init, generalization, console password, smoke test; the faster cloud-image alternative |
| [Stage 9 — The VMs](vms/09-vms.md) | Cloning 1010/1020/1030, postgres disk resize, Ansible control node, SSH keys |
| [Stage 9b — First Ansible bootstrap](vms/09b-bootstrap.md) | Filling the VMs: inventory, the split-VM variables, `bootstrap.yml`, verification |
| [Cloudflare Tunnel](vms/cloudflare-tunnel.md) | Why `cloudflared` runs inside the app VM, not on the host |

### [ha/](ha/) — replication, migration, failover

| | Covers |
|---|---|
| [Stage 10 — Replication](ha/10-replication.md) | Per-VM schedules — the interval *is* your data-loss window |
| [Stage 11 — First live migration](ha/11-live-migration.md) | The ping test |
| [Stage 12 — HA](ha/12-ha.md) | Which VMs get HA, `shutdown_policy=migrate`, notifications |
| [Stage 15 — Failover mechanics](ha/15-failover.md) | How detection/fencing/recovery actually work, the full scenario table with RTO/RPO, forcing quorum, the pre-launch test plan, periodic health checks |

### [backup/](backup/) — the three tiers

| | Covers |
|---|---|
| [Stage 14 — Backup & restore](backup/14-backup-restore.md) | USB tier, offsite (rclone + crypt) tier, the in-VM Postgres dump tier, every restore scenario A–F, post-restore checklist, restore drills |

### [operations/](operations/) — running it over the years

| | Covers |
|---|---|
| [Stage 13 — Maintenance](operations/13-maintenance.md) | Zero-downtime hardware maintenance; returning a node after a long outage (days–weeks) |
| [Stage 16 — Node replacement](operations/16-node-replacement.md) | Swapping in new hardware: clean swap vs disk transplant, step by step |
| [Stage 17 — Upgrades](operations/17-upgrades.md) | Postgres minors (automatic, by design) and majors (a project with a rehearsal); the same pattern for OS and Proxmox upgrades |
| [Stage 18 — Credentials](operations/18-credentials.md) | What authenticates what, what a restore gives back, recovery when a key is lost, the console password, key rotation via Ansible |

### [scripts/](scripts/) — speed for the operational side

One command each for the daily question (`cluster-health`), the protection question (`backup-verify`), the hosts' only backup (`pve-config-backup`), and the two riskiest procedures made guided (`node-return`, `restore-drill`). Installed on both nodes in [Stage 2.4](setup/02-post-install.md#24-install-the-helper-scripts-both-nodes); details in [scripts/README.md](scripts/README.md).

### [troubleshooting.md](troubleshooting.md) — symptom → cause, one line each

## Build checklist

The whole build, in execution order, with the two deliberate "come back later" points made explicit. Tick as you go; every line links to its stage above.

- [ ] **0** Preparation — BIOS (both nodes), USB stick, network plan, cabling
- [ ] **1** Install Proxmox — pve1, then pve2
- [ ] **2** Post-install — repos, upgrade, hardware check, **helper scripts (2.4)** — both nodes
- [ ] **3** Laptop config — pve2 only
- [ ] **3b** UPS monitoring (NUT) — pve1 only
- [ ] **4** Network — `vmbr0` + 10G link, both nodes; verify one default route
- [ ] **5** ZFS pools `apps` + `db` — both nodes, identical names
- [ ] **6** Cluster — two corosync rings, migration network
- [ ] **7** QDevice — third vote
- [ ] **8** Ubuntu template — *(8.6's template backup needs the USB drive; postponed to the 14 line below)*
- [ ] **9** Clone 1010/1020/1030, resize postgres disk, control node, SSH keys
- [ ] **9b** First Ansible bootstrap — the VMs get their contents; verify app + db + tunnel
- [ ] **10** Replication schedules per VM
- [ ] **11** First live migration — the ping test, both directions
- [ ] **12** HA for 1020/1030, `shutdown_policy=migrate`, notifications
- [ ] **14** Backups — USB drive, nightly job, offsite rclone + crypt; **now take the template backup from 8.6**
- [ ] **15.6** Pre-launch failover tests — all three, timed and written down
- [ ] **14.9** First restore drill — `restore-drill`, before going live, not after
- [ ] Go live 🎉

## Reading paths

- **Building from zero:** the checklist above, top to bottom. Stages 0–12 are a weekend; 14 and the test plan in 15.6 before going live are not optional.
- **A node just died:** [15.2](ha/15-failover.md#152-anatomy-of-an-unplanned-failover) for what's happening on its own, [15.3](ha/15-failover.md#153-scenario-table) for your row, [15.5](ha/15-failover.md#155-emergency-forcing-quorum) only if the QDevice is also down.
- **A node comes back after weeks:** [13.2](operations/13-maintenance.md#132-returning-a-node-after-a-long-outage-days-to-weeks) — order matters: rejoin → update → replicate → migrate.
- **Locked out / lost a key:** [18.5](operations/18-credentials.md#185-recovery-scenarios--what-losing-each-thing-actually-means) has the way back for each case.
- **Restoring anything:** [14.7](backup/14-backup-restore.md#147-restore--pick-your-scenario) — pick scenario A–F, then the [post-restore checklist](backup/14-backup-restore.md#148-post-restore-checklist).
- **Something looks wrong:** `cluster-health` on either node ([what it checks](scripts/README.md)), then [troubleshooting](troubleshooting.md).

## Relationship to the rest of the repo

The Proxmox hosts are managed by hand — this guide *is* their documentation. Everything **inside** the VMs (Postgres, the .NET app, nginx, cloudflared, backups, SSH keys) comes from [`native/infra/ansible`](../native/infra/ansible), run from the control VM. That ownership boundary is deliberate; it's spelled out in [17.5](operations/17-upgrades.md#175-the-same-pattern-applied-elsewhere). Change VM state via the playbook, not by hand — and mirror any `group_vars` change into [`native/example`](../native/example) and the hyper-v/docker example files, which are full copies meant to stay in sync.
