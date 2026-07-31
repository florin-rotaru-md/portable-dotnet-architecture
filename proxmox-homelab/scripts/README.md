# Helper scripts

*Part of the [waa Proxmox homelab guide](../README.md).*

Host-side scripts for the operations you do often (or under stress), so they take one command instead of a remembered sequence. Installed on **both nodes** in [Stage 2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) — into `/usr/local/sbin`, without the `.sh` suffix. Everything inside the VMs already has its own scripts via Ansible (`deploy.sh`, `rollback.sh`, `pg-backup.sh`, …); these cover the hypervisor side, which is otherwise hand-typed.

Design rules, should you add more: one script = one question or one procedure; `[ OK ] / [WARN] / [FAIL]` lines, not walls of text; exit codes cron can act on; every message points at the guide section that explains it; and anything that changes state asks first.

| Command | Answers / does | When |
|---|---|---|
| `cluster-health` | "Is the cluster fine?" — quorum, corosync rings, ZFS health + capacity + pinned snapshots, replication, HA, version skew between nodes, clock, backup freshness, NVMe SMART/wear, UPS/battery state. The [15.7](../ha/15-failover.md#157-health-checks-worth-running-periodically) list plus the easy-to-forget ones | Cron 07:00 daily; by hand any time something feels off — it's the first command of every investigation |
| `backup-verify` | "Am I protected *right now*?" — per-VM vzdump age and size, host-config archives, offsite sync log + actual remote freshness, in-VM Postgres dump age. Freshness is the signal failure-notifications can't give you | Cron 07:30 daily on pve1; by hand before anything risky |
| `pve-config-backup` | Archives the host's hand-managed config (`/etc/pve`, network, fstab, NUT, stage-3 scripts, crontab, package list) to the USB drive → offsite. The hosts are managed by hand, so this is the only copy that isn't the machine itself | Cron 02:40 nightly, both nodes — part of the [14.5 ordering chain](../backup/14-backup-restore.md#145-a-fourth-tier-for-the-database) |
| `node-return` | The [13.2](../operations/13-maintenance.md#132-returning-a-node-after-a-long-outage-days-to-weeks) procedure with the ordering enforced: rejoin-health gates → version alignment → replication catch-up → only then offers migration. Refuses to skip ahead | Attended, on the returning node, after any outage longer than a few hours. `--check` = report only |
| `restore-drill` | The monthly [14.9](../backup/14-backup-restore.md#149-restore-drills) drill: newest archive → spare VM ID, NIC down → boot → guest-agent proof → destroy, logging the measured RTO to `/var/log/restore-drill.log` | Attended, monthly on pve1, and after any storage/backup change. Rotates through the VMs by month; `restore-drill 1030` picks one explicitly |

The cron entries live in `/etc/cron.d/pve-helper-scripts` (written by `install-scripts.sh`) with `MAILTO=root`: the recurring checks run `--quiet`, printing only problems — so a healthy day sends no mail, and a bad one sends exactly what's wrong. Make sure root's mail actually reaches you — that's the same [notification target](../ha/12-ha.md#123-notifications) the backup and replication jobs depend on.

What is deliberately **not** here: anything that belongs to Ansible (in-VM state — [the ownership boundary](../operations/17-upgrades.md#175-the-same-pattern-applied-elsewhere)), and unattended versions of `node-return`/`restore-drill` — procedures that move VMs or create them deserve a human watching.
