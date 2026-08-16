# Stage 12 — ZFS replication

*Part of the [Proxmox lab guide](../README.md).*

For each VM: select the VM → **Replication → Add** → Target: the other node → Schedule.

The replication interval **is** your data-loss window on an unplanned failover, so differentiate it per VM:

| VM | Schedule | Why |
|---|---|---|
| 1022 postgres | `*/1` (every minute) | Live application writes — the data you actually can't afford to lose. [Stage 13](13-wal-stream.md) then shrinks even this minute down to seconds |
| 1021 app | `*:0` (hourly, on the hour) | Mostly stateless: the code and both deployment slots come back from one playbook run, so what's actually at risk is the log tail and whatever a deploy wrote since the last full hour |
| 1023 monitoring | `*:0` (hourly, on the hour) | Logs, not source data — an hour of missing history is a non-event, and it's the largest disk of the four (Stage 10), so a long interval keeps its replication traffic proportionate |
| 1020 control-ubuntu | `sun 05:00` (weekly) | Tooling only, and genuinely reproducible: the repo checkout comes from git, the `devops` key from the password manager ([0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now)). It is also the quietest guest of the four — between playbook runs almost nothing lands on it, since the `common` role installs at `state: present` rather than `latest` and never runs a `full-upgrade`. 05:00 Sunday sits clear of the nightly chain too — 02:15 dump, 03:00 vzdump, 03:30 verify, 04:00 offsite ([17.3](../backup/17-backup-restore.md#173-the-scheduled-job)) |

The spread is deliberate and it is wide — one minute to one week. It tracks how each guest is *recreated*, not how important it feels: 1022's rows exist nowhere else, while 1020 is a `git clone` and a restored key away from being itself again ([Stage 11](../vms/11-bootstrap.md)).

Be clear-eyed about the last row, though: **a Saturday failover takes up to seven days of 1020 with it.** That is the price being paid for it, not an oversight — but the moment you start keeping something on 1020 that isn't in git or the password manager, this is the first row to revisit.

> **Schedule syntax.** These are PVE calendar events, not cron. Bare `*/N` is *minutes*, so `*/60` is not the way to say hourly — the minute field only runs 0–59. `*:0` is: every hour, at minute zero. Weekday forms take the day first (`sun 05:00`, `mon..fri 22:00`).

The first run copies the whole disk (takes a while); after that only deltas (seconds). On the 10G link a minute's worth of Postgres writes is nothing.

> After a failover or migration, replication jobs **reverse direction automatically** — you don't reconfigure anything. The cluster knows the VM now lives on the other node and replicates back toward the recovered one.

> While the target node is unreachable, the job keeps retrying and the source **holds on to its last successful replication snapshot** — which pins every block written since. Over hours that's invisible; over weeks it grows without bound. See [16.2](../operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) for what to watch and how to bring a long-absent node back.
