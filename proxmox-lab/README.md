# Proxmox lab — 2 nodes, replication, live migration

A two-node Proxmox VE cluster for a self-hosted app: ZFS replication, HA with automatic failover, live migration over the LAN — or over a direct 10G cable plugged in for the occasion ([5.2](setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)) — multi-tier backups, and everything inside the VMs managed by Ansible from [`native/infra/ansible`](../native/infra/ansible). Written so it can be followed top-to-bottom by someone building this for the first time.

## Hardware

- **Node 1 `pve1`** — ThinkStation P2 Gen 2, Core Ultra 7 265, 64GB, **1× NVMe + 2× SATA SSD** — Kingston Fury 2TB NVMe → pool `db`, Samsung MZ7KM 1.92TB SATA → pool `apps`, Intel S3710 400GB SATA → boot + `local-lvm` — Intel X550-T2. **The nodes are not symmetric** — three drives each, but only pve2's are all NVMe — so read every device name in this guide as pve2's unless the text says otherwise. [2.3](setup/02-post-install.md#23-hardware-check) counts drives rather than NVMe (a single `nvme0n1` here is the correct answer, not a VMD/RST setting still to hunt) and [Stage 6](cluster/06-zfs-pools.md) opens with the per-node disk table and wipes by `/dev/disk/by-id/`, but [19.3](operations/19-node-replacement.md#193-approach-b--transplanting-the-disks)'s transplant still says "the same three NVMe drives", which on this node is one NVMe and two SATA SSDs. The asymmetry also decides what one dead disk costs: `apps` here is the SATA `/dev/sdb`, carrying 1020, 1021 and 1023, while the NVMe carries `db` (1022) alone — and every pool is a single device (see the status note below)
- **Node 2 `pve2`** — HP ZBook Fury G10 16", i9-13850HX, 64GB, **3× NVMe** — SK hynix PC801 512GB → boot, Kingston KC3000 2TB → pool `apps`, WD PC SN8000S 4TB → pool `db` — Thunderbolt 4 (role: failover). Note the two Kingstons sit on opposite pools (pve1's Fury on `db`, this one's KC3000 on `apps`); keep the model names in mind during a transplant so they do not get swapped
- QDevice: Dell Pro 14 (PC14250) — Core Ultra 5 225U, 16GB DDR5, 2TB NVMe, Debian 13, static `192.168.0.10`. Holds the third vote *and* the continuous WAL archive ([Stage 13](ha/13-wal-stream.md)); being a laptop, it also carries its own battery and needs [Stage 3](setup/03-laptop-node.md)'s lid/sleep treatment ([8.1](cluster/08-qdevice.md#81-the-box-and-its-os))
- ~5h UPS — **unmonitored**: no USB or network data port, so pve1 takes a hard cut when it runs dry ([4.6](setup/04-ups.md#46-disabled-on-this-build)) — router with tested 5G failover (~30s), Cloudflare Tunnel already in place

## Design decisions (vs the defaults you'd otherwise pick)

| Topic | The obvious default | This build | Reason |
|---|---|---|---|
| VM storage | LVM-Thin | **ZFS** (`apps`, `db`) | Proxmox replication works ONLY on ZFS |
| ZFS volume mode | Thick — what the *Add Storage* checkbox leaves you with | **Thin provision** (`sparse 1`) on both pools | Declared disk sizes become ceilings instead of reservations, and `discard=on` only returns freed blocks on a thin volume |
| VM CPU type | `host` | **`x86-64-v3`** | Different CPUs (Raptor Lake vs Arrow Lake) — `host` would crash a migrated VM |
| Migration network | Everything over the 1G LAN | The 1G LAN for both, pinned in `datacenter.cfg`; a direct 10G cable (X550 ↔ ACASIS NT0201A Thunderbolt dock, no switch) plugged in **per migration** and unplugged after ([5.2](setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)) | Full 10G for the one operation that moves tens of GB, without letting anything routine rest on a cable being in — the dock has dropped off on its own more than once. The price is paid in quorum: corosync ring 1 rides that cable, so while it is out the LAN is the only path to both the peer *and* the QDevice, and one dead switch fences both nodes ([5.2's cost table](setup/05-network.md#what-an-unplugged-ring-1-actually-costs-you)) |

The result, in one paragraph: two nodes joined by the home LAN (`vmbr0` — corosync **ring 0**, migration, replication) and, when a migration wants the throughput, by a direct 10G cable (corosync **ring 1**, plugged in for that migration and unplugged after — [5.2](setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), with a QDevice holding the third vote. That order is a requirement, not an accident of which address `pvecm` was given first: with `link_mode: passive` and no link priorities set, membership rides the lowest-numbered live link, so ring 0 has to be the cable that is always in ([Stage 7](cluster/07-cluster.md)). It is also the thing you read under stress, so learn it in that order: `corosync-cfgtool -s` reports LINK 0 on `192.168.0.x` and LINK 1 on `10.10.10.x`, which makes **link 1 disconnected the normal resting state here** and link 0 down an incident. Four VMs — `1020 control` (Ansible), `1021 app` (.NET + nginx + cloudflared), `1022 postgres`, `1023 monitoring` (Loki + Grafana) — replicate between nodes on a schedule that differs per VM — every minute for `postgres`, hourly for `app`, `monitoring` and `control` ([Stage 12](ha/12-replication.md)); HA restarts `app` and `postgres` on the surviving node in ~2–3 minutes if a node dies, while `control` and `monitoring` stay out of HA and are started by hand if their node goes down — a plain reboot still brings `monitoring` back on its own, via [start-at-boot](vms/10-vms.md#start-at-boot--what-comes-back-after-a-node-reboot). Backups — VM images, host config and a mirror of all three R2 buckets (the two products' media plus the company's filed fiscal documents) — go to a USB disk nightly and on to Digi Storage offsite, encrypted ([Stage 17](backup/17-backup-restore.md)). **Not on this cluster**: Stage 17 has never been executed — read the note below before you trust any backup signal here.

> **Status, 2026-09-10 — this build has no hypervisor-level backup at all.** No USB drive is attached to either node (`/mnt` is empty on both), `/etc/pve/jobs.cfg` does not exist, `/etc/pve/vzdump.cron` holds only its generated header, and `/var/log/pve/tasks/index` has never recorded a single `vzdump`. That is not a cosmetic gap, because [Stage 6](cluster/06-zfs-pools.md) deliberately builds every pool as a **single device** — `apps` and `db` are one bare disk per node, no mirror, no raidz — so these tiers were the *whole* redundancy story, not a second line behind a mirror. What is left is the pve1→pve2 replication and the nightly in-VM Postgres dump on 1022, and neither is a backup: replication copies a deletion, a bad deploy or a corrupt page to the peer within the minute, and the dump rides on the same replicated disks. Until the **17** line of the checklist below is actually done, read every green backup line as *nothing was checked* — [`backup-verify`](scripts/README.md) and `cluster-health` were corrected on 2026-09-10 to FAIL when no `vzdump` job is scheduled anywhere in the cluster, but both nodes are still running the 2026-09-04 copies of every helper script, which reassure instead, until [2.4](setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) is re-run on each. Take that caveat as standing for this whole page: what a helper script does, here and in [scripts/README.md](scripts/README.md), is what the copy **in this repo** does — the copy on the nodes is whatever the last install run put there.

## The guide

### [setup/](setup/) — from empty machines to two updated nodes

| | Covers |
|---|---|
| [Stage 0 — Preparation](setup/00-preparation.md) | BIOS settings, install USB, the network plan and why there's no 10G switch, physical cabling, **and the whole SSH key model** — what exists, generated up-front (Windows + Linux), and where each half is stored |
| [Stage 1 — Installation](setup/01-installation.md) | Proxmox installer choices, identical on both nodes |
| [Stage 2 — Post-install](setup/02-post-install.md) | No-Subscription repositories (click-by-click), first upgrade, **CPU microcode + `fwupd` (2.2)**, hardware sanity check, helper scripts, each node's SSH key pair |
| [Stage 3 — Laptop node](setup/03-laptop-node.md) | pve2 now, the QDevice later ([8.1](cluster/08-qdevice.md#81-the-box-and-its-os)): lid/sleep, battery-driven clean shutdown, TLP + dynamic CPU governor |
| [Stage 4 — UPS monitoring](setup/04-ups.md) | pve1 only: NUT, clean shutdown when the UPS runs dry, the full long-outage timeline — **not in service**: this UPS has no data port, so NUT is disabled ([4.6](setup/04-ups.md#46-disabled-on-this-build)) |
| [Stage 5 — Network](setup/05-network.md) | `vmbr0` on 1G, the 10G point-to-point link as an **on-demand** cable (why ring 1 still names it, what its absence costs quorum, how to run a migration over it), the one-default-route rule |

### [cluster/](cluster/) — storage and quorum

| | Covers |
|---|---|
| [Stage 6 — ZFS pools](cluster/06-zfs-pools.md) | Identifying disks, `apps` + `db` pools — same names on both nodes, non-negotiable; thin provisioning, while the pools are still empty |
| [Stage 7 — Cluster](cluster/07-cluster.md) | Create/join with two corosync rings, migration network settings |
| [Stage 8 — QDevice](cluster/08-qdevice.md) | The third box, end to end: which OS and why (8.1), Debian 13 from download to first boot (8.2), its static address (8.3), key-only SSH from your PC *and* from both nodes (8.4), joining it (8.5), the laptop treatment it needs (8.6), firmware (8.7). The third vote is mandatory for maintenance with one node down |

### [vms/](vms/) — the guests

| | Covers |
|---|---|
| [Stage 9 — Ubuntu template](vms/09-ubuntu-template.md) | The golden image, built from Canonical's cloud image: guest-agent injection, cloud-init defaults, console password, smoke test; the interactive-ISO alternative |
| [Stage 10 — The VMs](vms/10-vms.md) | Cloning 1020/1021/1022/1023, per-VM disk sizes (one `qm resize` each), proving each guest *took* its static IP, key-only SSH and how to get in, Ansible control node |
| [Stage 11 — First Ansible bootstrap](vms/11-bootstrap.md) | Filling the VMs: inventory, the split-VM variables, the monitoring VM (Loki + Grafana), `bootstrap.yml`, verification |
| [Cloudflare Tunnel](vms/cloudflare-tunnel.md) | Why `cloudflared` runs inside the app VM, not on the host |

### [ha/](ha/) — replication, migration, failover

| | Covers |
|---|---|
| [Stage 12 — Replication](ha/12-replication.md) | Per-VM schedules — the interval *is* your data-loss window |
| [Stage 13 — WAL stream](ha/13-wal-stream.md) | Postgres WAL → QDevice, continuously: the failover minute becomes recoverable seconds, plus a 7-day any-second PITR window — **both only once a `vzdump` base exists to replay onto**, which on this cluster it does not ([13.4](ha/13-wal-stream.md#134-what-this-buys-beyond-the-failover-minute)) |
| [Stage 14 — First live migration](ha/14-live-migration.md) | The ping test |
| [Stage 15 — HA](ha/15-ha.md) | Which VMs get HA and what actually goes in the Add dialog, `shutdown_policy=migrate`, the notification path proved on both of its halves, **the watchdog everything else rests on (15.4)**, and why the Rules panel stays empty while `failback` and `auto-rebalance` — both ticked for you — get unticked |
| [Stage 18 — Failover mechanics](ha/18-failover.md) | How detection/fencing/recovery actually work, the full scenario table with RTO/RPO, forcing quorum, the pre-launch test plan, periodic health checks |

### [backup/](backup/) — the tiers

| | Covers |
|---|---|
| [Stage 17 — Backup & restore](backup/17-backup-restore.md) | USB tier, offsite (rclone + crypt) tier, the in-VM Postgres dump tier, the R2 media mirror (17.10), every restore scenario A–G, post-restore checklist, restore drills |

### [operations/](operations/) — running it over the years

| | Covers |
|---|---|
| [Stage 16 — Maintenance](operations/16-maintenance.md) | Zero-downtime hardware maintenance; returning a node after a long outage (days–weeks); firmware — what to detect, when a BIOS is worth flashing, and what a flash breaks in *this* build |
| [Stage 19 — Node replacement](operations/19-node-replacement.md) | Swapping in new hardware: clean swap vs disk transplant, step by step |
| [Stage 20 — Upgrades](operations/20-upgrades.md) | Postgres minors (automatic, by design) and majors (a project with a rehearsal); the same pattern for OS and Proxmox upgrades |
| [Stage 21 — Credentials](operations/21-credentials.md) | What authenticates what, what a restore gives back, recovery when a key is lost, the console password, key rotation via Ansible |
| [Stage 22 — R2 mirror: operating it](operations/22-r2-mirror.md) | The media tier day-to-day: how the pieces move, the routine proofs it still works, and the incident table — from a failing sync to a deleted bucket, including writing objects back |
| [Stage 23 — Drill book](operations/23-drill-book.md) | The run order and the record: the pre-launch drill sequence, the daily/monthly/quarterly verification calendar, the app-level checklist that closes every drill, and the log of measured RTO/RPO |

### [scripts/](scripts/) — speed for the operational side

One command each for the daily question (`cluster-health`), the protection question (`backup-verify`), the hosts' only backup (`pve-config-backup`), the R2 media tier ([`r2-backup`](backup/17-backup-restore.md#1710-a-fifth-tier-for-the-r2-media-bucket)), the two riskiest procedures made guided (`node-return`, `restore-drill`), and Stage 10's four clones (`create-vms`) — plus `infra-report`, the cron wrapper all four recurring jobs run through: the exit code passes through untouched, the output does not — stderr is merged into stdout and re-printed there, which for the two nightly jobs whose cron lines end `>/dev/null` takes their stderr off the mail path for good — and the outcome is POSTed to the app, the only channel that can tell a dead cron or a dead mail path from a quiet, healthy morning. Installed on both nodes in [Stage 2.4](setup/02-post-install.md#24-install-the-helper-scripts-both-nodes); details in [scripts/README.md](scripts/README.md).

### [troubleshooting.md](troubleshooting.md) — symptom → cause, one line each

## Build checklist

The whole build, in execution order, with the two deliberate "come back later" points made explicit. Tick as you go; every line links to its stage above.

- [ ] **0** Preparation — BIOS (both nodes), USB stick, network plan, cabling, **the SSH keys (0.5)** into the password manager
- [ ] **1** Install Proxmox — pve1, then pve2
- [ ] **2** Post-install — repos, upgrade, **microcode + `fwupd` (2.2)**, hardware check, **helper scripts (2.4)**, **each node's key pair (2.5)** — both nodes
- [ ] **3** Laptop config — pve2 here; the QDevice gets the same 3.1/3.2 at Stage 8
- [x] **4** UPS monitoring (NUT) — pve1 only; **not applicable on this build**: the UPS has no data port, NUT disabled ([4.6](setup/04-ups.md#46-disabled-on-this-build))
- [ ] **5** Network — `vmbr0` on the LAN, both nodes; verify one default route; configure the 10G link once **with the cable in**, then unplug it — it is an on-demand cable, not standing infrastructure ([5.2](setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected))
- [ ] **6** ZFS pools `apps` + `db` — both nodes, identical names; **un-pin the storages from their node** and **thin provision (6.1)**, both before any VM disk exists
- [ ] **7** Cluster — two corosync rings, migration network
- [ ] **8** QDevice — Debian 13 install (8.2), wired + static `192.168.0.10` (8.3), key-only SSH incl. **pve1's root key** (8.4), third vote (8.5), lid/sleep + battery (8.6)
- [ ] **9** Ubuntu template from the cloud image — *(9.5's template backup needs the USB drive; postponed to the 17 line below)*
- [ ] **10** The four VMs — [`create-vms`](scripts/README.md) (or clone + resize + start-at-boot by hand), confirm each guest *took* its static IP, then control node, SSH keys
- [ ] **11** First Ansible bootstrap — the VMs get their contents; verify app + db + tunnel + Loki/Grafana
- [ ] **12** Replication schedules per VM
- [ ] **13** WAL stream to the QDevice — both ends, verified end to end
- [ ] **14** First live migration — the ping test, both directions
- [ ] **15** HA for 1021/1022 only — 1020 and 1023 deliberately stay out, `shutdown_policy=migrate`, HA Rules left empty and **Failback + Auto-Rebalance unticked on both resources (15.5)**, **watchdog confirmed armed on both nodes (15.4)**, notifications proved from both nodes (15.3)
- [ ] **17** Backups — USB drive, nightly job, offsite rclone + crypt, the R2 media mirror (17.10); **now take the template backup from 9.5**
- [ ] **23** Pre-launch drills — the [drill book](operations/23-drill-book.md) sequence top to bottom (18.6's four failover tests, including the isolation drill that is the only proof fencing works, 17.9's first restore drill, the offsite + R2 proofs), timed and logged
- [ ] Go live 🎉

## Reading paths

- **Building from zero:** the checklist above, top to bottom. Stages 0–15 are a weekend; 17 and the drill book (23) before going live are not optional.
- **Drill day — pre-launch or the quarterly hour:** [Stage 23](operations/23-drill-book.md) is the run order, the pass criteria and the log; the mechanics stay in 14/17/18/22.
- **A node just died:** [18.2](ha/18-failover.md#182-anatomy-of-an-unplanned-failover) for what's happening on its own, [18.3](ha/18-failover.md#183-scenario-table) for your row, [18.5](ha/18-failover.md#185-emergency-forcing-quorum) only if the QDevice is also down.
- **The 10G link is down:** that is its resting state, not an incident — the cable is plugged in per migration and unplugged after ([5.2](setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)). It is corosync **ring 1**, so nothing fails over and nothing needs repointing: membership stays on ring 0 (the LAN), `datacenter.cfg` already pins migration *and* replication to `192.168.0.0/24`, and `cluster-health` — the repo copy; see the status note above — classifies link 1 as expected-down rather than as a fault. What you are living without meanwhile is the second ring — the QDevice shares the LAN with ring 0, so one dead switch leaves each node at 1 vote of 3 and both self-fence ([the cost table](setup/05-network.md#what-an-unplugged-ring-1-actually-costs-you)): treat switch, router or cabling work as a planned full-cluster outage. If the link will not come up *with* the cable in, [the runbook](troubleshooting.md#runbook--the-10g-link-is-down).
- **A node comes back after weeks:** [16.2](operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) — order matters: rejoin → update → replicate → migrate.
- **A brand-new VM won't let me in, or came up on the wrong IP:** [Stage 10](vms/10-vms.md#first-boot--confirm-each-vm-took-its-static-ip) — the two first-boot surprises of the cloud image, in order.
- **Which key opens what, and where it's stored:** [0.5](setup/00-preparation.md#05-keys--generate-all-of-them-now) is the whole key model in one place — all five pairs generated up-front, every one backed by a password-manager item, later stages only install them; [21.1](operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives) is the same set seen from the "what if I lose it" side.
- **Locked out / lost a key:** [21.5](operations/21-credentials.md#215-recovery-scenarios--what-losing-each-thing-actually-means) has the way back for each case.
- **Shipping a new app version:** [20.5](operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere) — one command on 1021 (`deploy.sh`, token already in place) or from 1020 (`playbooks/deploy.yml`), and `rollback.sh` as the instant undo.
- **Restoring anything:** [17.7](backup/17-backup-restore.md#177-restore--pick-your-scenario) — pick scenario A–G, then the [post-restore checklist](backup/17-backup-restore.md#178-post-restore-checklist).
- **Media missing from the site, or an R2 object needs to come back:** [Stage 22](operations/22-r2-mirror.md) — the incident table, then the write-back recipe.
- **A firmware update is being offered:** [16.3](operations/16-maintenance.md#163-firmware--detect-always-flash-rarely) — the answer is usually *don't*, and when it isn't, the order is QDevice → pve2 → wait a week → pve1, with the post-flash checklist that catches the settings a BIOS update quietly reset.
- **Something looks wrong:** `cluster-health` on either node ([what it checks](scripts/README.md)), then [troubleshooting](troubleshooting.md).

## Relationship to the rest of the repo

The Proxmox hosts are managed by hand — this guide *is* their documentation. Everything **inside** the VMs (Postgres, the .NET app, nginx, cloudflared, backups, SSH keys) comes from [`native/infra/ansible`](../native/infra/ansible), run from the control VM. That ownership boundary is deliberate; it's spelled out in [20.5](operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere). Change VM state via the playbook, not by hand — and mirror any `group_vars` change into [`native/example`](../native/example) and the hyper-v/docker example files, which are full copies meant to stay in sync.
