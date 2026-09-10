# Stage 13 — WAL streaming to the QDevice (RPO: from ~1 minute to seconds)

*Part of the [Proxmox lab guide](../README.md).*

[Stage 12](12-replication.md)'s `*/1` schedule is the floor for VM-level replication: an unplanned failover loses up to ~a minute of writes, and [18.4](18-failover.md#184-what-failover-does-not-cover) says so honestly. This stage shrinks that window to **seconds** without touching the failover model: Postgres streams its write-ahead log to a receiver on the QDevice, continuously. When a node dies, HA still restarts 1022 from the ZFS replica exactly as before — but the seconds the replica is missing now exist on a third machine, where [scenario G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) can replay them. *Surviving* is what this stage delivers; recovering them is G's half, and on this build G stops at its own first step — replaying WAL needs a physical base to replay onto and no vzdump has ever run ([13.4](#134-what-this-buys-beyond-the-failover-minute)). Read every RPO number below as the seconds you keep, not yet the seconds you get back.

Why this variant and not a hot standby or synchronous replication: the stream is **event-driven and one-directional** — no writes means nothing flows (a few keepalive bytes), so it adds no pressure to either node, day or night. There's no promote/failback machinery to operate, no second database to keep in your head, and a receiver outage degrades you back to exactly today's RPO instead of blocking writes. The QDevice — a Dell Pro 14 with a Core Ultra 5 225U, 16GB DDR5 and a 2TB NVMe ([8.1](../cluster/08-qdevice.md#81-the-box-and-its-os)) — takes the entire cost, and barely notices: WAL at this scale is megabytes per day against two terabytes of disk.

## 13.1 Enable it on the database side

The `postgres` role owns everything on 1022 ([the ownership boundary](../operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere)) and already knows how to do this — it's one switch plus the receiver's address. In `group_vars/all/main.yml`:

```yaml
postgres_wal_stream_enabled: true
postgres_wal_stream_cidr: "192.168.0.10/32"     # the QDevice, same IP as in Stage 8
```

and in `vault.yml` (generate something long; it also goes in the password manager — it's now part of the [21.1 inventory](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives)):

```yaml
postgres_wal_stream_password: "<strong password>"
```

Then, from control-ubuntu:

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible-playbook playbooks/bootstrap.yml --limit postgres --diff
```

The run creates a replication-only user (`walreceiver` — no database access, it can only read the log stream), a physical replication slot (`wal_archive` — the server's bookmark of what the receiver has confirmed, so nothing is lost across receiver restarts), opens `pg_hba`/UFW for the QDevice's IP only, and sets `max_slot_wal_keep_size` from `postgres_max_slot_wal_keep_size` — the safety valve that makes a long-dead receiver break the stream instead of filling the `db` disk. **On this build that is 8GB**, and the arithmetic in [13.5](#135-failure-modes-stated-plainly) assumes it. Ask the server rather than a file, because the files currently disagree:

```bash
ssh devops@192.168.0.22 "sudo -u postgres psql -tAc 'show max_slot_wal_keep_size'"
```

The tune-down to 8GB was made in the operator inventory and mirrored nowhere: the role's own fallback (`| default('10GB')` in [`roles/postgres/tasks/main.yml`](../../native/infra/ansible/roles/postgres/tasks/main.yml)), all four example copies — `native/example`, `native/infra/ansible/inventory/group_vars/all/main.yml.example`, `hyper-v/example`, `hyper-v/files/main.yml` — and the `[FAIL]` line [`backup-verify`](../scripts/README.md) prints when the slot goes inactive (*accumulating toward the 10GB cap*) all still say 10GB. That is exactly the drift the [repo rule](../README.md#relationship-to-the-rest-of-the-repo) exists to prevent, and it is not cosmetic: this number is how you estimate how many hours a dead receiver can be left alone before the slot is invalidated, so being 25 % out is the difference between fixing it tomorrow and finding the slot gone — and the script's copy is the one an operator meets at 07:30 on the morning it matters. `grep -rn 10GB` across the repo is the check when you tune it — six of the files it names still assert the old value, and none of them is the inventory that decides.

Verify the slot exists:

```bash
ssh devops@192.168.0.22 "sudo -u postgres psql -tAc \"select slot_name, active from pg_replication_slots\""
# wal_archive | f        ← inactive until the receiver connects (13.3)
```

## 13.2 The receiver on the QDevice

The QDevice is hand-managed, like the Proxmox hosts — this section *is* its documentation (it joins `/etc/pve` in no backup, so [`pve-config-backup`](../scripts/README.md)'s philosophy applies: keep this reproducible from the guide). PGDG's client must match the server's major version — today `postgresql-client-18`, and bumping it is part of any [Stage 20.3](../operations/20-upgrades.md#203-major-upgrade--the-procedure) major upgrade.

```bash
# PGDG repo (same as the role configures on 1022), then the matching client
apt install -y curl ca-certificates
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/keyrings/postgresql.asc
echo "deb [signed-by=/usr/share/keyrings/postgresql.asc] http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt update && apt install -y postgresql-client-18

# A dedicated user, the archive directory on the NVMe, and the credentials
useradd --system --home-dir /var/lib/wal-archive --create-home --shell /usr/sbin/nologin walarchive
install -o walarchive -g walarchive -m 600 /dev/null /var/lib/wal-archive/.pgpass
# fields are host:port:database:user:password — see the character warning below
echo '192.168.0.22:5432:replication:walreceiver:<the password from vault.yml>' > /var/lib/wal-archive/.pgpass

# The divergence guard (13.5). It runs before every start of the receiver — including the automatic
# restarts — and is the only thing standing between a failover and the archive overwriting the very
# seconds that failover lost.
cat << 'EOF' > /usr/local/sbin/wal-archive-guard
#!/bin/bash
# Refuse to stream into an archive that is AHEAD of the server.
#
# After an unplanned failover 1022 comes back from a ZFS replica, behind its own archive, on the same
# timeline (crash recovery never bumps it). pg_receivewal then restarts the newest .partial from that
# segment's start and the walsender accepts — rewriting exactly the window the failover lost. So:
# compare first, and if the archive is ahead, move it aside and stream into an empty directory. The
# moved copy is the input for scenario G; losing it is the one outcome this stage exists to prevent.
set -u
ARCHIVE=/var/lib/wal-archive
HOST=192.168.0.22
export PGPASSFILE="$ARCHIVE/.pgpass"

newest="$(ls -1 "$ARCHIVE" 2>/dev/null \
  | sed -n 's/^\([0-9A-F]\{24\}\)\(\.partial\)\?$/\1/p' | sort | tail -1)"
[ -z "$newest" ] && exit 0          # empty archive — nothing to protect

server="$(psql -qtAX -h "$HOST" -U walreceiver -d postgres \
  -c 'select pg_walfile_name(pg_current_wal_lsn())' 2>/dev/null | tr -d '[:space:]')"
[ -z "$server" ] && exit 0          # server unreachable — never destructive on no answer

# WAL filenames are timeline+position in hex, so lexical order IS WAL order. Archive strictly
# greater than the server means the server went backwards (or onto another timeline): divergence.
if [[ "$newest" > "$server" ]]; then
  aside="$ARCHIVE.diverged-$(date +%Y%m%dT%H%M%S)"
  mv "$ARCHIVE" "$aside"
  install -d -o walarchive -g walarchive -m 700 "$ARCHIVE"
  cp -p "$aside/.pgpass" "$ARCHIVE/.pgpass" 2>/dev/null || true
  echo "wal-archive-guard: archive ($newest) is ahead of the server ($server) — 1022 was rewound." >&2
  echo "wal-archive-guard: moved to $aside; it holds the window scenario G replays. Streaming fresh." >&2
fi
exit 0
EOF
chmod 0755 /usr/local/sbin/wal-archive-guard

cat << 'EOF' > /etc/systemd/system/pg-receivewal.service
[Unit]
Description=Stream Postgres WAL from 1022 (RPO in seconds — lab guide 11)
After=network-online.target
Wants=network-online.target

[Service]
User=walarchive
# `+` runs it as root: it has to be able to rename a directory under /var/lib, which walarchive
# cannot. Everything it creates is handed back to walarchive.
ExecStartPre=+/usr/local/sbin/wal-archive-guard
# --synchronous: flush each write and report back, so "received" means "on this disk"
ExecStart=/usr/lib/postgresql/18/bin/pg_receivewal \
    --directory=/var/lib/wal-archive \
    --slot=wal_archive --synchronous \
    --host=192.168.0.22 --username=walreceiver --no-password
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pg-receivewal

# Retention: 7 days. Not for space (2TB yawns at this) — it's the PITR window (13.4).
# The regex matches a COMPLETE 24-hex-character segment and nothing else: not the `.partial`
# being written right now, not a `.history` file, and — see the warning below — not `.pgpass`,
# which lives in this directory because the useradd above made it walarchive's home.
cat << 'EOF' > /etc/cron.d/wal-archive-prune
30 5 * * * walarchive find /var/lib/wal-archive -type f -regextype posix-extended -regex '.*/[0-9A-F]{24}' -mtime +7 -delete
EOF
chmod 0644 /etc/cron.d/wal-archive-prune     # not optional — see the warning below
```

> **The `-regex` form and the `chmod` are both repairs to what is on the QDevice today, and applying only the `chmod` is a landmine.** Checked 2026-09-10: `/etc/cron.d/wal-archive-prune` is mode `0664`, because the heredoc inherited the umask of whoever typed it, and cron refuses any file in `/etc/cron.d` that group or other can write. It says so once a minute — `(*system*wal-archive-prune) INSECURE MODE (group/other writable)` in `journalctl -u cron` — and runs nothing. Nothing has ever been pruned: 19 segments, 305 MB, the oldest dated 2026-08-16, a 25-day archive where this stage and [13.4](#134-what-this-buys-beyond-the-failover-minute) both promise 7 days.
>
> Harmless at this size. What is not harmless is what the original `! -name '*.partial'` sweep deletes the day someone fixes the mode. `useradd --create-home` put `walarchive`'s home *inside* the archive, so `.pgpass` sits there — 79 bytes, written once when the stream was built, therefore permanently older than 7 days — and `find … -type f ! -name '*.partial' -mtime +7 -delete` matches it, running as the user that owns it. The stream does not die that night: `pg_receivewal` keeps the connection it already authenticated. It dies at the next restart, reboot or client upgrade, looping on `password authentication failed for user "walreceiver"` with a `.pgpass` that is *gone* rather than wrong — the one variant of that failure the rotation ordering in [13.5](#135-failure-modes-stated-plainly) cannot explain, days or weeks after the change that caused it. Fix both together on the box: rewrite the cron line in the `-regex` form, `chmod 0644`, then `journalctl -u cron -n 5` to watch the complaint stop. Its first working run deletes the 12 segments older than a week, leaving six complete ones and the `.partial`; with no base backup ([13.4](#134-what-this-buys-beyond-the-failover-minute)) that costs nothing replayable, but take the base first if you would rather not test that sentence.

> **Keep this password alphanumeric.** It passes through two parsers that both treat punctuation as structure, and neither failure is legible. `.pgpass` splits fields on `:`, so a colon or backslash in the password has to be escaped (`\:`, `\\`) or libpq silently sends a truncated string. And the role interpolates it straight into SQL — `PASSWORD '{{ … }}'` in [`roles/postgres/tasks/main.yml`](../../native/infra/ansible/roles/postgres/tasks/main.yml) — so an apostrophe breaks the statement, with `no_log: true` hiding the detail. A long alphanumeric secret sidesteps both and costs nothing in strength.
>
> The symptom when they disagree is `password authentication failed for user "walreceiver"` in `journalctl -u pg-receivewal`, looping every 10 seconds. The database side is not the one to fix: the role runs `ALTER ROLE … PASSWORD` on *every* playbook run, so Postgres always holds whatever `vault.yml` says — align `.pgpass` to that, not the reverse.

## 13.3 Verify — both ends, then end to end

```bash
# QDevice: service up, a .partial segment present
systemctl status pg-receivewal --no-pager | head -3
ls -lh /var/lib/wal-archive | tail -3

# QDevice: the divergence guard exists AND is wired into the unit — both, or it is not armed
ls -l /usr/local/sbin/wal-archive-guard          # -rwxr-xr-x … root root
systemctl cat pg-receivewal | grep ExecStartPre  # ExecStartPre=+/usr/local/sbin/wal-archive-guard

# 1022: the stream is live and confirmed
ssh devops@192.168.0.22 "sudo -u postgres psql -xc \
  \"select application_name, state, write_lsn, flush_lsn, sync_state from pg_stat_replication\""
# state = streaming — and pg_replication_slots.active is now t

# End to end: make a write, watch it land within seconds
ssh devops@192.168.0.22 "sudo -u postgres psql -c 'checkpoint'"   # forces WAL traffic
ls -l --time-style=full-iso /var/lib/wal-archive | tail -2         # mtime just moved
```

**A receiver with no guard streams exactly as well as one with it.** `systemctl status`, the archive listing, the slot's `active` flag and `pg_stat_replication` read identically either way — the guard's absence has no symptom at all until a failover, and its first symptom then is the overwritten window it existed to save ([13.5](#135-failure-modes-stated-plainly)). That is why these are checks and not something to remember. The `+` is part of what is being checked: without it `ExecStartPre` runs as `walarchive`, which cannot rename a directory under root-owned `/var/lib`, so the guard detects the divergence, fails the `mv`, exits 0 — and the receiver starts and rewrites the archive anyway. Re-run the pair after every reinstall or reimage of the QDevice; it is hand-managed and nothing reconciles it ([13.2](#132-the-receiver-on-the-qdevice)). *Checked 2026-09-10: this build was streaming happily — service `active`, `00000001000000000000002C.partial` growing, slot `active = t`, `state = streaming` — with `/usr/local/sbin/wal-archive-guard` absent and no `ExecStartPre` in the unit at all, so every word of [13.5](#135-failure-modes-stated-plainly)'s clobbering applies to it today. Install the guard per 13.2 and delete this note when both lines above answer.*

> **`write_lsn`/`flush_lsn`, not `replay_lsn`.** `replay_lsn` is a *standby* concept — the position a replica has applied. `pg_receivewal` applies nothing, it writes and flushes, so it reports those two and leaves `replay_lsn` NULL on a perfectly healthy stream. Judge this by `state = 'streaming'` and by the two positions advancing.

**Zero rows from that query means no walsender is attached at all** — not a column to interpret. The receiver itself says why, on the QDevice:

```bash
journalctl -u pg-receivewal -n 30 --no-pager
```

`no pg_hba.conf entry for replication connection from host "…"` is the common one, and it means 13.1's two variables don't match this QDevice: either `postgres_wal_stream_enabled` is still false (so the `pg_hba` block never rendered) or `postgres_wal_stream_cidr` carries an address the box no longer has. Fix them in `group_vars/all/main.yml` and re-run the playbook — at no cost in downtime: the `pg_hba` template notifies a **reload**, deliberately, and the role's handler performs it as `SELECT pg_reload_conf()` rather than `service: reloaded`, because on Debian `postgresql.service`'s `ExecReload` is `/bin/true` and would have reported success while changing nothing. Only the first enable bounces 1022, and for a different reason: `max_slot_wal_keep_size` takes effect at startup, so the line the role adds notifies a restart.

From here, [`backup-verify`](../scripts/README.md) checks the stream daily — slot active, lag bounded — and does so on a node with no USB drive: the drive gate covers only the tiers that actually live on the drive, and the WAL-slot and in-VM `pg-dump` checks below it reach 1022 over the network and run unconditionally on both nodes. It also keeps the SSH exit status apart from the query result, so *I could not ask* prints `[FAIL] wal-stream: … the slot state is UNKNOWN, not absent` instead of the `[ OK ] … Stage 13 not enabled (fine if that's intentional)` that a mere connection failure used to manufacture.

> **All of that is true of the copy in this repo, not of the copy that runs tonight.** Both nodes still carry the 2026-09-04 build in `/usr/local/sbin`, whose USB block ends in a bare `exit 0` on a node without the drive — and on 2026-09-10 neither node had one ([17.2](../backup/17-backup-restore.md#172-backup-storage--the-usb-drive)) — so no `wal-stream:` line has ever been printed on either node, and the app recorded "exit 0, no output" as a pass over an unwatched stream. The scripts change only when [Stage 2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes)'s `install-scripts.sh` is re-run there after a `git pull`. **Until it is, every sentence in this stage about what the check reports describes the repo, and the stream is watched by nobody** — read this once and carry it through 13.4 and [13.5](#135-failure-modes-stated-plainly).

The separation will earn itself the first time the repaired copy runs: from pve1 the `ssh` to 1022 fails closed today — the VM answers on the network, but it was rebuilt during the 2026-09-05..07 database reset and pve1's `/root/.ssh/known_hosts` still pins the old key, so `ssh` refuses with `REMOTE HOST IDENTIFICATION HAS CHANGED` before any query runs ([21.7](../operations/21-credentials.md#217-the-fourth-kind-the-pins-nobody-inventories)). Until the repaired copy is installed on both nodes and that pin is replaced, **the two queries above are the check, and a human runs them** — which is why the failure modes in [13.5](#135-failure-modes-stated-plainly) promise you no warning about any of them.

## 13.4 What this buys beyond the failover minute

The same archive is a **general point-in-time recovery window**: the nightly 03:00 vzdump of 1022 is a base, and the QDevice holds every WAL byte since. Restore last night's archive to a spare VM ID ([17.7 A](../backup/17-backup-restore.md#a-restore-into-a-new-vm-id-safest--start-here)), point `restore_command` at the archive with a `recovery_target_time`, and you can stand the database up **as of any second the archive still holds** — 7 days once [13.2](#132-the-receiver-on-the-qdevice)'s prune is running, everything back to 2026-08-16 while it is not — "undo the bad migration that ran at 14:32" territory, which no amount of replication gives you. The mechanics are the same as scenario G with one extra line; G documents both.

> **Not true on this build (checked 2026-09-10): there is no base.** `/etc/pve/jobs.cfg` does not exist, `/etc/pve/vzdump.cron` holds only its generated header and `PATH` line, `/var/log/pve/tasks/index` records zero `vzdump` runs, and `pvesm status` lists no `usb-backup` storage — the job in [17.3](../backup/17-backup-restore.md#173-the-scheduled-job) was never created, so no hypervisor-level backup of 1022 has ever been taken. Without a base this archive is not a recovery window; it is every change since 2026-08-16 to a database nobody kept a copy of. The one tier that *does* run does not fill the gap: the nightly in-VM dumps ([17.5](../backup/17-backup-restore.md#175-a-fourth-tier-for-the-database)) are `-Fc` logical dumps, and a `pg_restore` has no LSN to replay onto — PITR needs a physical copy of the data directory, which only the vzdump provides here. [Scenario G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) fails at its own first step for the same reason, and nothing said so out loud for 25 days, because the copy of the backup check installed on both nodes returns at its USB block and never reaches a word about this tier ([13.3](#133-verify--both-ends-then-end-to-end)). Create the job before quoting a seven-day recovery window to anyone, including yourself.

## 13.5 Failure modes, stated plainly

- **Receiver down (QDevice off, service dead, network):** nothing breaks. Postgres holds WAL for it, up to 8GB; the receiver reconnects and resumes from the slot's bookmark. Your RPO is back to Stage 12's ~1 minute while it lasts — and today nothing tells you it is happening: the repaired `backup-verify` would, and the copy installed on both nodes exits before it reaches this tier ([13.3](#133-verify--both-ends-then-end-to-end)). Nothing speaks at the cap either; the slot is simply invalidated, so the first symptom is the next bullet's recovery rather than a warning before it. Run 13.3's slot query by hand until Stage 2.4 has been re-run on both nodes.
- **Receiver down past the 8GB cap:** the slot is invalidated — the deliberate trade (a broken stream over a full `db` disk). Recover: fix the receiver, then on 1022 drop and recreate the slot (`select pg_drop_replication_slot('wal_archive'); select pg_create_physical_replication_slot('wal_archive')` — or just re-run the playbook after dropping) and restart `pg-receivewal`.
- **The password is rotated in `vault.yml`:** the stream dies, silently, and the cause is structural rather than accidental. The database side is Ansible-owned — the role runs `ALTER ROLE … PASSWORD` on *every* playbook run — while `.pgpass` on the QDevice is written once by hand in [13.2](#132-the-receiver-on-the-qdevice) and reconciled by nothing, ever. So the run updates Postgres, the receiver keeps presenting the old secret, and `journalctl -u pg-receivewal` loops on `password authentication failed` every 10 seconds while the slot pins WAL toward the 8GB cap. Nothing in the application notices, and until Stage 2.4 is re-run nothing outside it does either: `backup-verify` holds the only check, and the copy on the nodes exits before reaching it ([13.3](#133-verify--both-ends-then-end-to-end)). That turns a rotation done out of order into a silent countdown — the stream is dead from the moment the playbook runs, WAL piles against the cap with no one watching, and you find out when the slot has already been invalidated and the fix is no longer "rewrite `.pgpass`" but "drop and recreate the slot", which discards every second the archive was holding. **Rotate in this order:**

  1. new value into `vault.yml` (keep it alphanumeric — [13.2](#132-the-receiver-on-the-qdevice))
  2. `ansible-playbook playbooks/bootstrap.yml --limit postgres --diff` — Postgres now holds the new one
  3. rewrite `/var/lib/wal-archive/.pgpass` on the QDevice with the same value, `chown walarchive:walarchive`, `chmod 600`
  4. `systemctl restart pg-receivewal`, then confirm `state = streaming` and the slot back to `active = t` ([13.3](#133-verify--both-ends-then-end-to-end))

  The stream is down between steps 2 and 3, which is why they belong in one sitting. Reversing them doesn't help: the database is the authority, and a `.pgpass` written first is simply wrong until the playbook catches up. And the password is not recoverable from Postgres — it is stored as a SCRAM verifier — so if the two ever drift beyond repair, the only path is to set a new one on both ends. And if the loop starts with no rotation behind it, suspect the file rather than the value: [13.2](#132-the-receiver-on-the-qdevice)'s prune deletes `.pgpass` along with the old segments unless its `find` expression has been narrowed.
- **After an unplanned failover, the stream does not resume by itself — and that is the archive's protection.** HA restarts 1022 from a ZFS replica, so the database comes back *behind* its own archive, on the same timeline (crash recovery never bumps it). `pg_receivewal` computes its start position from the newest complete segment on disk, asks for a position the server hasn't reached, and the walsender refuses:

  ```
  ERROR:  requested starting point 0/31000000 is ahead of the WAL flush position of this server 0/1B050560
  pg_receivewal: disconnected; waiting 5 seconds to try again
  ```

  **That refusal is real but conditional, and the condition usually does not hold.** It was observed on this build by planting a *complete* segment with a future name — which forces the receiver to request a position past a segment boundary. A real failover does not look like that. `pg_receivewal` derives its start position from the beginning of the newest segment on disk, and restarts a `.partial` from that segment's start. With a one-minute replication interval at a few MiB of WAL per minute, the rewind is **smaller than one 16 MiB segment**, so the requested position lands *behind* the server's flush position, the walsender accepts, and the `.partial` is rewritten with post-failover WAL under the same name on the same timeline (crash recovery never bumps the timeline). The tail of that `.partial` is precisely the lost window.

  So: assume the archive **can** be clobbered, and that the seconds you failed over through are the first thing destroyed.

  **`wal-archive-guard` is what prevents it — where it was actually installed, and on this build it is not** ([13.3](#133-verify--both-ends-then-end-to-end) carries the dated check and what it found: no guard, no `ExecStartPre`, and a receiver streaming happily regardless). This is [13.2](#132-the-receiver-on-the-qdevice)'s hand-management showing its teeth: nothing in `native/infra/ansible` reaches this machine, so a block skipped once at build time exists nowhere but in this guide, and no run will ever put it back. Its absence also inverts [scenario G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice)'s rule: *no `wal-archive.diverged-*` directory means the failover clobbered nothing* only holds if the guard was there to create one — without it, that same emptiness is what a clobbered archive looks like, and G would send you to read the overwritten copy as though it were the saved one. So prove it rather than assume it:

  ```bash
  ssh root@192.168.0.10 'ls -l /usr/local/sbin/wal-archive-guard; systemctl cat pg-receivewal | grep ExecStartPre'
  ```

  If it answers as it does today, re-run 13.2's guard and unit blocks, then `systemctl daemon-reload && systemctl restart pg-receivewal` — the guard's first run compares against a server that is ahead, so it is a no-op — and delete [13.3](#133-verify--both-ends-then-end-to-end)'s dated note once the check comes back with both lines.

  It runs as `ExecStartPre` on every start of the receiver, including the automatic restarts, and does one comparison: the newest segment name in the archive against `pg_walfile_name(pg_current_wal_lsn())` on 1022. WAL filenames are timeline plus position in hex, so lexical order is WAL order — an archive strictly greater than the server means the server went backwards. When it does, the guard renames the archive to `/var/lib/wal-archive.diverged-<timestamp>` and lets the receiver stream into a fresh directory. Nothing is deleted, the stream comes back on its own, and the window scenario G needs is sitting in the renamed directory instead of being overwritten by the reconnect.

  Two properties it was written to have: **it is never destructive on no answer** — an unreachable server exits 0 and the receiver simply retries, because "cannot ask" must not look like "diverged" — and it moves rather than deletes, so a false positive costs disk, not data. Its verdict lands in `journalctl -u pg-receivewal`.

  It is not a substitute for the real fix, which is not letting the rewound server take writes at all: recover it by rolling forward from the archive and promoting *before* the application starts, which bumps the timeline so post-recovery segments get new filenames and can no longer collide. The guard buys the time to do that.

  **Recovery, in this order:** move the diverged archive aside *first* — it is the input for [scenario G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice), including the `.partial` — then let the receiver start against an empty directory and re-establish the stream. Doing it the other way round throws away the only copy of the window you failed over through.
- **Postgres major upgrade:** install the new `postgresql-client-NN` on the QDevice as part of the Stage 20 rehearsal, not after.
- **Turning it off:** `postgres_wal_stream_enabled: false`, run the playbook, then drop the slot by hand — a slot nobody reads is the one thing the playbook won't remove for you.
