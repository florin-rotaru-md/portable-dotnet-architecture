# Stage 23 — Drill book: pre-launch tests & the verification calendar

*Part of the [Proxmox lab guide](../README.md).*

The mechanics of every test live with their subject: the four failover tests in
[18.6](../ha/18-failover.md#186-pre-launch-test-plan), the restore drills in
[17.9](../backup/17-backup-restore.md#179-restore-drills), the first migration in
[Stage 14](../ha/14-live-migration.md). This stage is the **run order and the record**: the
sequence to execute before go-live, the calendar that repeats after it, the app-level checks
that close every drill — a VM that boots is not yet a site that works — and the log where the
measured numbers go. Nothing here replaces those sections; every row links back to its mechanics.

## 23.1 The gate — before any drill

Do not start a drill from an unknown state; a failed precondition turns a rehearsal into an
incident. All four, every time:

1. `cluster-health` exits clean on **both** nodes ([scripts](../scripts/README.md)).
2. `backup-verify` exits clean on **both** nodes — it checks the archiver on 1022 and every tier
   against Digi ([17.3](../backup/17-backup-restore.md#173-offsite--digi-storage)). Read its output
   line by line and know which failures you are choosing to drill through.
3. A fresh on-demand vzdump of the VM you are about to break — **Backup now** to storage `local`
   ([17.5](../backup/17-backup-restore.md#175-vm-images--quarterly-and-on-demand)).
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
| 6 | Database point-in-time recovery into a scratch VM, to a target time after drill 4's failover | [17.7 G](../backup/17-backup-restore.md#g-database-point-in-time-recovery-base--wal) | **Prerequisite, settled before drill 4:** a base on Digi older than the target (the weekly base runs on Sunday) and `backup-verify`'s `pg-archive`, `pg-wal-offsite` and `pg-base` lines `[ OK ]`. Pass = the scratch VM's Postgres reaches the chosen target and every database is there, so the replay has crossed the failover. The writes the replica never had (≤ 1 min) are gone by design, not by the drill ([17.4](../backup/17-backup-restore.md#174-postgres--continuous-wal-and-a-weekly-base)); `*.diverged-*` files in the spool afterwards are a warning to inspect, not a failure |
| 7 | Restore drill, scenario A | [`restore-drill`](../scripts/README.md) / [17.9](../backup/17-backup-restore.md#179-restore-drills) | boots on a spare ID, guest agent reports, RTO logged |
| 8 | Offsite restore, scenario E | [17.7 E](../backup/17-backup-restore.md#e-restore-from-offsite) | an archive pulled from Digi Storage restores — which proves the **crypt passwords**, the only proof that matters before you depend on them |
| 9 | *Optional:* forced-quorum rehearsal — stop the QDevice, hard-kill pve2, recover the survivor with `pvecm expected 1`, then restore all three votes | [18.5](../ha/18-failover.md#185-emergency-forcing-quorum) | you have typed the scariest command once on a cluster that held nothing, so the first real use is not also the first ever |

Drill 4 is the one to repeat after any significant infrastructure change, and drill 5 after
anything that touches the network, the kernel or the watchdog
([18.6](../ha/18-failover.md#186-pre-launch-test-plan)); the rest recur on the calendar below.

## 23.3 The calendar

| Cadence | What | Defined in |
|---|---|---|
| Daily, automatic | `cluster-health` **07:07** and `backup-verify` 07:30 (both nodes), `offsite-sync` 05:00, `pve-config-backup` 02:40, `pg-offsite` every minute — quiet when healthy. The seven minutes are cosmetic, and it matters that you know which half did the work: a check at 07:00:01 caught the `*:0` replication jobs mid-run and read a perfectly normal `SYNCING` as `[FAIL] replication: … your RPO is drifting right now` every morning, but moving off the hour cannot fix that — job 1022-0 runs `*/1` and fires 1440 times a day, so no cron minute dodges a sync. What fixed it is `cluster-health` no longer treating `SYNCING` as a fault; 07:07 is tidiness on top. If the alarm ever comes back, look at that rule, not at the clock. **The result reaches you through the app's infra ingest, not root mail** — see the proof below. `pg-offsite` is the exception: it writes only to `/var/log/pg-offsite.log`, and `backup-verify`'s `pg-archive` and `pg-wal-offsite` lines are how its failure reaches you | [scripts](../scripts/README.md), [17.4](../backup/17-backup-restore.md#174-postgres--continuous-wal-and-a-weekly-base) |
| Monthly | glance at `zpool status` — last scrub within a month (the shipped cron scrubs on the second Sunday) | [18.7](../ha/18-failover.md#187-health-checks-worth-running-periodically) |
| Quarterly, ~1 h | In the week after the image job (1 Jan/Apr/Jul/Oct), once its images are on Digi: `restore-drill` of one VM; database point-in-time recovery G into a scratch VM from base + WAL; **proof that the Digi copies decrypt** — fetch the image `restore-drill` uses from `digi-crypt:` first (scenario E), or open the newest `inventory/` copy with the crypt passwords from the password manager; firmware sweep across all three boxes; **root-mail proof** (below) | [17.9](../backup/17-backup-restore.md#179-restore-drills), [17.7 G](../backup/17-backup-restore.md#g-database-point-in-time-recovery-base--wal), [17.7 E](../backup/17-backup-restore.md#e-restore-from-offsite), [16.3](16-maintenance.md#163-firmware--detect-always-flash-rarely) |
| After any change to storage, backup config, the notification target, Proxmox major, network | repeat the drill that covers what changed — each section states its own rule | [18.6](../ha/18-failover.md#186-pre-launch-test-plan), [17.9](../backup/17-backup-restore.md#179-restore-drills) |

**The root-mail proof — and what it found.** Every automatic check on this list also mails root and
stays silent when healthy — which makes a healthy quarter indistinguishable from a dead mail path.
Once a quarter, from **each** node and the QDevice:

```bash
echo "mail path test $(hostname) $(date -Is)" | mail -s "pve mail test" root
```

One message from each = the silence means something; one missing = fix that node's mail before
anything else, because its failures have been invisible. **As of 2026-09-10 none arrive, and only
two of the three commands can even run.** On both nodes postfix hands the message to
`/usr/libexec/proxmox-mail-forward`, the upstream provider answers `550 5.7.1 … blocked using
Spamhaus` for this home IP, and postfix logs `status=bounced` and then removes it. That takes the
mail out from under every check in the daily row above, and for `pve-config-backup` it is the whole
reporting path: the installed cron wraps only `cluster-health` and `backup-verify` in `infra-report`
and runs the 02:40 archive bare. The repo's cron file wraps it, which is one more thing Stage 2.4
lands. **And** the bounce takes out PVE's own notifications entirely, vzdump, replication, HA,
fencing and package updates, because those have no second channel and all post to the same target.
The QDevice cannot run the test at all: it ships no MTA, `mail`, `sendmail` and postfix are all
absent, so it needs one installed first.

**Where to look when one does not arrive, because nothing else will tell you.** There is no bounce
and nothing is retained, so the obvious places are all empty and prove nothing: `/var/mail/root` is
never created, `mailq` stays empty, and a PVE 9 host has no `/var/log/mail.log` — postfix logs to
the journal and only there:

```bash
journalctl -t postfix/smtp -t proxmox-mail-forward --since '2 days ago'
```

Two shapes of failure show up in those lines. If `/etc/pve/notifications.cfg` does not exist, no
SMTP target was ever added and `proxmox-mail-forward` falls back to the built-in `mail-to-root` —
the node is then speaking SMTP to your mailbox provider from its own WAN address, which is exactly
the case [15.3](../ha/15-ha.md#153-notifications) says does not work, and it comes back as the `550`
blocklist refusal naming your home IP. If a target *does* exist, read the same lines for an auth or
TLS failure against the submission host. Either way the fix is 15.3's step 1, not a retry.

What still delivers is the infra-report POST to the app
(`platform/docs/adr/0015-infrastructure-verification.md`; `/etc/infra-report.conf` is present on
both nodes), so until this proof passes, read the daily outcome in the app's admin view and treat an
empty inbox as meaning nothing at all. The cost of not knowing that is wider than this drill: a
target that cannot send takes the mail half of the first row of
[23.6](#236-division-of-labour--what-watches-what) with it, and everything that reports *only* by
mail — PVE's own vzdump, replication, HA and fencing notices, plus `pve-config-backup` for as long
as the installed cron runs it unwrapped — goes with it too, silently,
while the jobs keep looking green. Until a test message has actually landed in a human's inbox, the
app-side ingest is not the backstop; it is the only channel you have, and it carries only what
`infra-report` wraps. Repeat this proof the day anything about the mail target changes, not only at
the quarter mark.

## 23.4 The app checklist

After any drill that restarted, moved or restored the app or the database — drills 3, 4, 5, 7, 8 —
the VM booting is half the story. The other half, in order:

1. **Ready endpoint** — from inside 1021: `curl -fsS http://127.0.0.1/.well-known/ready`, then
   the same path through the public origin. Both must answer 200.
2. **The two-minute human pass** — log in, open an event, edit something small. This catches the
   class of failure no probe does: app up, dependency down.
3. **Media** — an R2-served image renders on a public page (media does not live in any VM, so a
   VM restore proves nothing about it). Nothing in this estate backs R2 up: the buckets exist only
   in Cloudflare ([17.1](../backup/17-backup-restore.md#171-the-tiers)).
4. **Email** — trigger one transactional mail (a login code) and see it arrive.
5. **Background work** — the scheduler drained what came due during the outage (the app's admin
   log view; announcements/reminders queued during the window should show as sent, not stuck).
6. **Postgres** — `journalctl -u postgresql` on 1022 shows crash recovery completed cleanly;
   the Proxmox UI shows no replication or HA errors left behind.

If the drill involved a restore, the [17.8 post-restore
checklist](../backup/17-backup-restore.md#178-post-restore-checklist) (replication job, HA
membership, guest agent) comes **first**, then this list.

## 23.5 The drill log

`restore-drill` keeps per-run detail in `/var/log/restore-drill.log` on the node that ran it — a
file that dies with that node's OS disk. The summary that matters lives here, in git, off the cluster. One row per
drill, appended at the time, not from memory:

| Date | Drill (23.2 #) | Measured RTO | Data window lost | Notes |
|---|---|---|---|---|
| 2026-09-13 | — (not a drill: an interim copy, before the [offsite tier](../backup/17-backup-restore.md#173-offsite--digi-storage) existed) | — | — | No vzdump job yet. Ad-hoc `vzdump 1022 --storage local --mode snapshot --compress zstd` on pve1: `/var/lib/vz/dump/vzdump-qemu-1022-2026_09_13-08_02_34.vma.zst`, 1.25 GB from a 1 TiB zvol that is 99 % zero, 3 min 11 s, `/` 77 → 75 G free. `/opt/postgres/backups` (68 dumps + globals) copied off the cluster to the operator workstation as `D:/backups/postgres-1022/backups-20260912.tar` |

Those measured numbers are the build's real RTO/RPO — quote them, not the design targets, when
deciding whether the replication schedule or the backup cadence needs tightening.

## 23.6 Division of labour — what watches what

| Observer | Sees | Blind to |
|---|---|---|
| Host cron + root mail (daily scripts) | everything on and between the nodes, in detail | its own death — dead cron and dead mail look identical to healthy |
| App-side monitor (in the app repo: scheduled checks against the Proxmox API + script ingest, on-demand run from the admin UI, alerts through the app's own mailer) | cluster degradation from inside the workload: a node gone, replication stale, backups aging, quorum at 2/3 — and, via freshness, the death of the cron layer above | total cluster loss — it runs on the thing it watches — **and whatever a long run's detail does not fit.** `InfraStatusMath` clips the `" \| "`-joined lines at ingest and only the clipped string is persisted in the report payload; the raw lines are kept nowhere. Since 2026-09-10 the cap is 2000 characters rather than 300 and `[FAIL]` lines are sorted ahead of `[WARN]` ones before joining, so the reason a report went red now survives — but the clip has not gone away. The verdict always survives it (pass/warn/fail is graded over every line before anything is truncated); the *evidence* is best-effort. Trust this layer for the colour, and read the host for the reason |
| External uptime probe on the public ready endpoint | total loss — the only observer that does not live on the cluster | everything subtler than "down" |

Three layers, each covering the one above it — but layers one and two overlap more than they look.
`infra-report` wraps the helper inside the same cron entry, so the *content* the app ingests is not
a second opinion: it is that run's own output, clipped. What layer two adds independently is
**arrival** — a report that does not land at all is a signal the host cannot send about itself, and
it is how a dead cron gets noticed, up to 26 hours later. So read the colour in the UI and the
reason on the host (`cluster-health` interactively) rather than acting on the excerpt; and after
changing a script or the cron file, check that a report still lands, because a wrapper that silently
stops reporting looks exactly like a healthy quiet night until that freshness check fires.

The first layer exists since Stage 2.4; the second is specified in the app repository
(`platform/docs/adr/0015-infrastructure-verification.md`); the third is a five-minute setup with any
external uptime service, using the same `/.well-known/ready` URL the deploy script already trusts.
