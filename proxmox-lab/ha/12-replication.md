# Stage 12 — ZFS replication

*Part of the [Proxmox lab guide](../README.md).*

For each VM: select the VM → **Replication → Add** → Target: the other node → Schedule.

The replication interval **is** your data-loss window on an unplanned failover, so it is set per VM rather than once for the cluster:

| VM | Schedule | Why |
|---|---|---|
| 1022 postgres | `*/1` (every minute) | Live application writes — the data you actually can't afford to lose. [Stage 13](13-wal-stream.md) then streams the WAL to the QDevice so those seconds exist off the node — though replaying them needs a base backup this build does not have ([13.4](13-wal-stream.md#134-what-this-buys-beyond-the-failover-minute)) |
| 1021 app | `*:0` (hourly, on the hour) | Mostly stateless: the code and both deployment slots come back from one playbook run, so what's actually at risk is the log tail and whatever a deploy wrote since the last full hour |
| 1023 monitoring | `*:0` (hourly, on the hour) | Logs, not source data — an hour of missing history is a non-event, and at 320G it is the largest of the three guests on this schedule ([Stage 10](../vms/10-vms.md)), so a long interval keeps its replication traffic proportionate |
| 1020 control-ubuntu | `*:0` (hourly, on the hour) | Tooling only, and genuinely reproducible: the repo checkout comes from git, the `devops` key from the password manager ([0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now)). It is also the quietest guest of the four — between playbook runs almost nothing lands on it, since the `common` role installs at `state: present` rather than `latest` and never runs a `full-upgrade`. That quietness is the argument *for* the short interval, not against it: an idle guest costs seconds of delta traffic an hour, so hourly buys the same window as 1021 and 1023 for nothing, while a weekly slot would save nothing measurable and leave a six-day tail nobody is tracking |

Two values rather than four, and the split is deliberate: a minute for 1022, an hour for everything else. It tracks how each guest is *recreated*, not how important it feels: 1022's rows exist nowhere else, while 1020 is a `git clone` and a restored key away from being itself again ([Stage 11](../vms/11-bootstrap.md)).

Keep reading the last row as a judgement rather than a number, though. Nothing here is more than an hour behind its replica, which is cheap *because* 1020 holds only things that exist elsewhere — the moment you keep something on it that isn't in git or the password manager (an unpushed branch, a vault file edited in place, a one-off script), this is the first row to revisit. An hour of lost tooling state costs nothing only for as long as the tooling is rebuildable.

> **Schedule syntax.** These are PVE calendar events, not cron. Bare `*/N` is *minutes*, so `*/60` is not the way to say hourly — the minute field only runs 0–59. `*:0` is: every hour, at minute zero. Weekday forms take the day first (`sun 05:00`, `mon..fri 22:00`).

The first run copies the whole disk (takes a while); after that only deltas (seconds).

> **Replication does not use the 10G link.** `/etc/pve/datacenter.cfg` pins it — like migration — to `network=192.168.0.0/24`, the 1G LAN, and that pinning is deliberate: the 10G cable is plugged in on demand and unplugged again ([5.2](../setup/05-network.md#52-the-10g-direct-link--plugged-in-on-demand-not-left-connected)), so nothing scheduled is allowed to depend on it being there. A minute's worth of Postgres deltas is comfortably within 1G; the whole-disk first run is the part that is slow, and it is a one-off. If you want a bulk copy to go fast, that is what the per-migration override in [5.4](../setup/05-network.md#54-using-the-10g-link-for-a-migration) is for.
>
> **And it is replication's own setting, not migration's.** `datacenter.cfg` carries two keys here — `migration: secure,network=192.168.0.0/24` and `replication: network=192.168.0.0/24,type=secure` — and where both apply, `replication:` wins; PVE falls back to the migration network only when no replication key is set. So [Stage 7](../cluster/07-cluster.md)'s Migration Settings stop answering for both the moment anything writes a `replication:` key, and the two can disagree without saying so. Read the file rather than assuming, and don't guess afterwards either: every run records the network it actually used — `using secure transmission over <CIDR>` in `/var/log/pve/replicate/<jobid>`. Any instruction that repoints a link failure with `--migration` alone is half a fix for the same reason; if a `replication:` key still names a subnet with no address left on the target, the job dies with `could not get migration ip: no IP address configured on local node for network 10.10.10.0/24`.

> After a failover or migration, replication jobs **reverse direction automatically** — you don't reconfigure anything. The cluster knows the VM now lives on the other node and replicates back toward the recovered one.

> While the target node is unreachable, the job keeps retrying and the source **holds on to its last successful replication snapshot** — which pins every block written since. Over hours that's invisible; over weeks it grows without bound. See [16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) for what to watch and how to bring a long-absent node back.
