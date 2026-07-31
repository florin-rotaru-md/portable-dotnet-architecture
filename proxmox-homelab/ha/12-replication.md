# Stage 12 — ZFS replication

*Part of the [Proxmox homelab guide](../README.md).*

For each VM: select the VM → **Replication → Add** → Target: the other node → Schedule.

The replication interval **is** your data-loss window on an unplanned failover, so differentiate it per VM:

| VM | Schedule | Why |
|---|---|---|
| 1030 postgres | `*/1` (every minute) | Live application writes — the data you actually can't afford to lose |
| 1020 app | `*/5` | Mostly stateless; holds little unique state |
| 1010 control | `*/15` or `*/30` | Tooling only, rebuildable |

The first run copies the whole disk (takes a while); after that only deltas (seconds). On the 10G link a minute's worth of Postgres writes is nothing.

> After a failover or migration, replication jobs **reverse direction automatically** — you don't reconfigure anything. The cluster knows the VM now lives on the other node and replicates back toward the recovered one.

> While the target node is unreachable, the job keeps retrying and the source **holds on to its last successful replication snapshot** — which pins every block written since. Over hours that's invisible; over weeks it grows without bound. See [16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) for what to watch and how to bring a long-absent node back.
