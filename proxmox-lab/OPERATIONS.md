# Host operations

[Map](README.md) · [Build](BUILD.md) · [Recovery](RECOVERY.md) · [Application operations](../../platform/docs/OPERATIONS.md)

## First checks

On the relevant Proxmox node:

```bash
cluster-health
pvecm status
corosync-cfgtool -s
ha-manager status
pvesr status
zpool status
qm list
```

Expected baseline: quorum three votes/two required, LAN link connected, `apps`/`db` ONLINE,
HA 1021/1022 started on one owner, replication current. `SYNCING` is in-flight work; judge errors
and last successful sync. Check both nodes; a green local view is not proof the peer is ready.

## Quorum and network

LAN `.11`/`.12` is Link 0. Optional `10.10.10.1`/`.2` is Link 1 and normally disconnected. Read
addresses as well as link numbers when diagnosing a rebuilt node. On pve2 an unplugged Thunderbolt
dock can remove the interface entirely; pve1 can simply show no carrier.

With Link 1 absent, the LAN switch carries the peer path and QDevice. Losing it can leave both
nodes with one vote of three and fence both. Do not label this topology fully network-redundant.
The direct link's absence does not stop routine replication: both scheduled paths use LAN.

Before changing corosync/bridge config, obtain console access and verify peer/QDevice health.
Change a reviewed copy with the required config-version update. Do not turn a symptom into an
unplanned cluster topology change or disable fencing to keep a VM alive.

## Planned maintenance

1. Verify quorum, peer capacity, storage, current replication and an independently recoverable
   backup. Read [current backup gaps](RECOVERY.md#coverage) before assuming a checkpoint is enough.
2. Announce the application window if needed. List guest ownership and active background work.
3. Move app/database together to avoid long cross-node DB traffic; move non-HA guests explicitly
   if they are needed during maintenance. Respect HA management for HA-owned guests.
4. Verify application/API health, database connectivity and replication from the new owner.
5. Service/reboot one node only. On return, compare versions/kernel, quorum, pools and replication
   before moving any workload back. No automatic failback is expected.

Use `node-return --check` for the read-only return assessment. The attended `node-return` workflow
orders version alignment and replica catch-up before it offers migration; review its output.

## Migration

Default path is secure LAN, configured separately for migration and replication. The audited
datacenter had no `bwlimit`; a large transfer shares the wire with quorum traffic. Choose a
bandwidth cap for the planned operation and verify latency/replication rather than assuming no effect.

For a deliberate direct-link migration, connect/verify the 10G cable on both ends, then use the
supported migration command with `--migration_network 10.10.10.0/24` and an explicit bandwidth
choice. Check `qm help migrate` on the installed version. Return to normal cable state after the
operation; do not permanently repoint scheduled traffic at an optional link.

Never start a second copy of a guest to recover a migration. Check current HA/task ownership first.

## Updates and firmware

- Read the actual repository/package diff. Match host release and running kernel after reboot.
- Update one empty/drained node, verify it, then the other. Keep VM machine/CPU compatibility.
- Rehearse PostgreSQL major upgrades on an isolated restored VM; app/DP databases and extensions
  must all pass migration/restore checks. A new version is not a configuration-only change.
- `cloudflared` is pinned/managed by the native role; connector restart affects public routing.
  Verify both public APIs afterwards. Application release does not upgrade it automatically.
- Inspect firmware updates and reason for applying them. AC, battery, secure boot, storage mode,
  virtualization and power-on-after-loss settings need verification after a flash.

PostgreSQL config/package changes can restart the cluster. Scope Ansible so an app change does
not accidentally apply the postgres role. Do not merge host, database-major and application changes
into one unobservable maintenance step.

## Notification and probe health

Host scripts emit `[ OK ]`, `[WARN]`, `[FAIL]` and meaningful exit codes. Missing tools mean
"check did not run", never success. Cron needs `/usr/sbin:/usr/bin:/sbin:/bin`.

`infra-report` submits to Waa using `/etc/infra-report.conf`; absent config can leave local output
without remote evidence. Check timestamps in the admin dashboard. Prove notification delivery
at the operations mailbox when changing the channel.

Existing operational evidence records root-mail rejection by the recipient provider and missing
mail tooling on QDevice. Treat native PVE/SMART mail delivery as unverified until a received test
confirms it; an empty queue can mean a bounced/discarded message. Inspect:

```bash
journalctl -t postfix/smtp -t proxmox-mail-forward --since '2 days ago'
```

Script reports and PVE native notifications are separate paths; verify receipt for both.

## Symptoms

| Symptom | Inspect first |
|---|---|
| APIs unavailable, cluster healthy | `.21` Nginx/cloudflared/slot; [application runbook](../../platform/docs/OPERATIONS.md) |
| Both nodes lose quorum | LAN/QDevice reachability and fencing state; no forced quorum until peer isolated |
| Replication unavailable on peer | Pool names and storage node restriction; both pools must be available there |
| High pool use / deletion frees little | Snapshots, thin-volume reservation, discard and retention |
| Healthy pool, failed VM disk | Single-disk pool limitations; do not infer redundancy from ONLINE |
| Node returned after long outage | Version/kernel drift and incomplete replica catch-up |
| Missing morning report | Installed cron, PATH, required binary, ingest config and transport |
| Monitor fails `storage` on `<name>@<node> unavailable` | `pvesm status`: an inactive storage, often an installer default whose backing volume was removed (`local-lvm` without `pve/data`). Confirm no guest, job or replication names it (`grep -rl <name> /etc/pve`), then `pvesm remove <name>`; it edits `storage.cfg` only |
| Backup check fails | [Coverage and recovery](RECOVERY.md); never suppress merely because replication is green |

## Recurring work

Daily: fresh cluster/backup reports, last successful replication, dumps and alert delivery.
Monthly: pool scrub results/capacity and unresolved firmware/package findings.
Quarterly and after relevant changes: isolated VM + database/fiscal restoration, external copy
decryption, key recovery and actual notification delivery. Measure recovery duration/data loss
from the drill; do not turn an estimate into an SLA.
