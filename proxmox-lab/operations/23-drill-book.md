# Stage 23 — Drill book: pre-launch tests & the verification calendar

*Part of the [Proxmox lab guide](../README.md).*

The mechanics of every test live with their subject: the four failover tests in
[18.6](../ha/18-failover.md#186-pre-launch-test-plan), the restore drills in
[17.9](../backup/17-backup-restore.md#179-restore-drills), the R2 proofs in
[22.2](22-r2-mirror.md#222-proving-it-works), the first migration in
[Stage 14](../ha/14-live-migration.md). This stage is the **run order and the record**: the
sequence to execute before go-live, the calendar that repeats after it, the app-level checks
that close every drill — a VM that boots is not yet a site that works — and the log where the
measured numbers go. Nothing here replaces those sections; every row links back to its mechanics.

## 23.1 The gate — before any drill

Do not start a drill from an unknown state; a failed precondition turns a rehearsal into an
incident. All four, every time:

1. `cluster-health` exits clean on **both** nodes ([scripts](../scripts/README.md)).
2. `backup-verify` exits clean on pve1.
3. A fresh on-demand vzdump of the VM you are about to break
   ([17.4](../backup/17-backup-restore.md#174-on-demand-backup-before-anything-risky)).
4. `pvesr status` — all replication jobs current, then note which node currently holds which VM.

## 23.2 The pre-launch sequence

Run top to bottom — the order is easiest-to-undo first, and each drill assumes the previous one
passed. An afternoon covers 1–6; 7–9 fit in another. Time everything and write it into the
[drill log](#235-the-drill-log).

| # | Drill | Mechanics | Pass looks like |
|---|---|---|---|
| 1 | Live migration, idle, both directions | [Stage 14](../ha/14-live-migration.md) | ≤1 lost ping each way |
| 2 | Live migration **under load** — keep `load-drill.sh steady` running against the app while you migrate 1021, then 1022 | [Stage 14](../ha/14-live-migration.md) + [`perf/`](../../perf/README.md) | drill exits 0; no error spike or connection-pool exhaustion during the cutover |
| 3 | Clean shutdown of pve2, then power back on | [18.6 #2](../ha/18-failover.md#186-pre-launch-test-plan) | VMs **migrate**, not restart (zero downtime); after power-on, 1023 returns by itself, the HA pair stays put — no failback |
| 4 | Hard kill of pve2 (pull the plug) | [18.6 #3](../ha/18-failover.md#186-pre-launch-test-plan) | app answers again in ~2–3 min (measure it); Postgres crash recovery completes on its own; [app checklist](#234-the-app-checklist) passes; after pve2 returns, replication reverses without help |
| 5 | **Isolation of pve2** — migrate the HA pair onto it, then pull both corosync links at once. The only drill that tests *fencing* rather than recovery | [18.6 #4](../ha/18-failover.md#186-pre-launch-test-plan) / [15.4](../ha/15-ha.md#154-the-watchdog--what-fencing-actually-rests-on) | pve2 resets **itself** ~60 s after going inquorate; pve1 has the pair started before it finishes rebooting; both rings OK again after reconnecting. A pve2 that just sits there = fencing is broken, stop and fix it |
| 6 | WAL replay of the window drill 4 lost | [17.7 G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) | the spare VM's Postgres reaches seconds before the plug was pulled. **First check the guard fired**: `journalctl -u pg-receivewal \| grep wal-archive-guard` on the QDevice, and `ls -1d /var/lib/wal-archive*` shows a `.diverged-*` directory — that is the drill's real subject, because without it the reconnect would have overwritten the very window you are replaying ([13.5](../ha/13-wal-stream.md#135-failure-modes-stated-plainly)) |
| 7 | Restore drill, scenario A | [`restore-drill`](../scripts/README.md) / [17.9](../backup/17-backup-restore.md#179-restore-drills) | boots on a spare ID, guest agent reports, RTO logged |
| 8 | Offsite restore, scenario E | [17.7 E](../backup/17-backup-restore.md#e-restore-from-offsite) | an archive pulled from Digi Storage restores — which proves the **crypt passwords**, the only proof that matters before you depend on them |
| 9 | R2 media proof | [22.2](22-r2-mirror.md#222-proving-it-works) | one mirrored image opens from the USB copy **and** one from `digi-crypt:` |
| 10 | *Optional:* forced-quorum rehearsal — stop the QDevice, hard-kill pve2, recover the survivor with `pvecm expected 1`, then restore all three votes | [18.5](../ha/18-failover.md#185-emergency-forcing-quorum) | you have typed the scariest command once on a cluster that held nothing, so the first real use is not also the first ever |

Drill 4 is the one to repeat after any significant infrastructure change, and drill 5 after
anything that touches the network, the kernel or the watchdog
([18.6](../ha/18-failover.md#186-pre-launch-test-plan)); the rest recur on the calendar below.

## 23.3 The calendar

| Cadence | What | Defined in |
|---|---|---|
| Daily, automatic | `cluster-health` 07:00 (both nodes), `backup-verify` 07:30, `r2-backup` 03:30, `pve-config-backup` 02:40 — quiet when healthy, mails root when not | [scripts](../scripts/README.md) |
| Monthly, ~10 min | `restore-drill` on pve1 (rotates through the VMs); glance at `zpool status` — last scrub within a month (the shipped cron scrubs on the second Sunday) | [17.9](../backup/17-backup-restore.md#179-restore-drills), [18.7](../ha/18-failover.md#187-health-checks-worth-running-periodically) |
| Quarterly, ~1 h | Offsite restore E + WAL replay G against the drill VM + open one offsite R2 object; firmware sweep across all three boxes; **root-mail proof** (below) | [17.9](../backup/17-backup-restore.md#179-restore-drills), [16.3](16-maintenance.md#163-firmware--detect-always-flash-rarely), [22.2](22-r2-mirror.md#222-proving-it-works) |
| After any change to storage, backup config, Proxmox major, network | repeat the drill that covers what changed — each section states its own rule | [18.6](../ha/18-failover.md#186-pre-launch-test-plan), [17.9](../backup/17-backup-restore.md#179-restore-drills), [22.2](22-r2-mirror.md#222-proving-it-works) |

**The root-mail proof.** Every automatic check on this list reports by mail and stays silent when
healthy — which makes a healthy quarter indistinguishable from a dead mail path. Once a quarter,
from **each** node and the QDevice:

```bash
echo "mail path test $(hostname) $(date -Is)" | mail -s "pve mail test" root
```

Three messages arrive = the silence means something. One missing = fix that node's mail before
anything else; its failures have been invisible. (The app-side monitor in
[23.6](#236-division-of-labour--what-watches-what) exists precisely because this channel fails
silently.)

## 23.4 The app checklist

After any drill that restarted, moved or restored the app or the database — drills 3, 4, 5, 7, 8 —
the VM booting is half the story. The other half, in order:

1. **Ready endpoint** — from inside 1021: `curl -fsS http://127.0.0.1/.well-known/ready`, then
   the same path through the public origin. Both must answer 200.
2. **The two-minute human pass** — log in, open an event, edit something small. This catches the
   class of failure no probe does: app up, dependency down.
3. **Media** — an R2-served image renders on a public page (media does not live in any VM, so a
   VM restore proves nothing about it).
4. **Email** — trigger one transactional mail (a login code) and see it arrive.
5. **Background work** — the scheduler drained what came due during the outage (the app's admin
   log view; announcements/reminders queued during the window should show as sent, not stuck).
6. **Postgres** — `journalctl -u postgresql` on 1022 shows crash recovery completed cleanly;
   the Proxmox UI shows no replication or HA errors left behind.

If the drill involved a restore, the [17.8 post-restore
checklist](../backup/17-backup-restore.md#178-post-restore-checklist) (replication job, HA
membership, guest agent) comes **first**, then this list.

## 23.5 The drill log

`restore-drill` keeps per-run detail in `/var/log/restore-drill.log` on pve1 — a file that dies
with pve1's OS disk. The summary that matters lives here, in git, off the cluster. One row per
drill, appended at the time, not from memory:

| Date | Drill (23.2 #) | Measured RTO | Data window lost | Notes |
|---|---|---|---|---|
| | | | | |

Those measured numbers are the build's real RTO/RPO — quote them, not the design targets, when
deciding whether the replication schedule or the backup cadence needs tightening.

## 23.6 Division of labour — what watches what

| Observer | Sees | Blind to |
|---|---|---|
| Host cron + root mail (daily scripts) | everything on and between the nodes, in detail | its own death — dead cron and dead mail look identical to healthy |
| App-side monitor (in the app repo: scheduled checks against the Proxmox API + script ingest, on-demand run from the admin UI, alerts through the app's own mailer) | cluster degradation from inside the workload: a node gone, replication stale, backups aging, quorum at 2/3 — and, via freshness, the death of the cron layer above | total cluster loss — it runs on the thing it watches |
| External uptime probe on the public ready endpoint | total loss — the only observer that does not live on the cluster | everything subtler than "down" |

Three layers, each covering the one above it. The first exists since Stage 2.4; the second is
specified in the app repository (`statics/docs/adr/0015-infrastructure-verification.md`); the
third is a five-minute setup with any external uptime service, using the same
`/.well-known/ready` URL the deploy script already trusts.
