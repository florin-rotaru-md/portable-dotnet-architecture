# Stage 13 — WAL streaming to the QDevice (RPO: from ~1 minute to seconds)

*Part of the [Proxmox lab guide](../README.md).*

[Stage 12](12-replication.md)'s `*/1` schedule is the floor for VM-level replication: an unplanned failover loses up to ~a minute of writes, and [18.4](18-failover.md#184-what-failover-does-not-cover) says so honestly. This stage shrinks that window to **seconds** without touching the failover model: Postgres streams its write-ahead log to a receiver on the QDevice, continuously. When a node dies, HA still restarts 1022 from the ZFS replica exactly as before — but the seconds the replica is missing now exist on a third machine, and [scenario G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) replays them.

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

The run creates a replication-only user (`walreceiver` — no database access, it can only read the log stream), a physical replication slot (`wal_archive` — the server's bookmark of what the receiver has confirmed, so nothing is lost across receiver restarts), opens `pg_hba`/UFW for the QDevice's IP only, and sets `max_slot_wal_keep_size = 10GB` — the safety valve that makes a long-dead receiver break the stream instead of filling the `db` disk. Remember the [repo rule](../README.md#relationship-to-the-rest-of-the-repo): this `group_vars` change is already mirrored in the example files; keep it that way if you tune it.

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
# -name '*.partial' is the segment being written right now; never touch it.
cat << 'EOF' > /etc/cron.d/wal-archive-prune
30 5 * * * walarchive find /var/lib/wal-archive -type f ! -name '*.partial' -mtime +7 -delete
EOF
```

> **Keep this password alphanumeric.** It passes through two parsers that both treat punctuation as structure, and neither failure is legible. `.pgpass` splits fields on `:`, so a colon or backslash in the password has to be escaped (`\:`, `\\`) or libpq silently sends a truncated string. And the role interpolates it straight into SQL — `PASSWORD '{{ … }}'` in [`roles/postgres/tasks/main.yml`](../../native/infra/ansible/roles/postgres/tasks/main.yml) — so an apostrophe breaks the statement, with `no_log: true` hiding the detail. A long alphanumeric secret sidesteps both and costs nothing in strength.
>
> The symptom when they disagree is `password authentication failed for user "walreceiver"` in `journalctl -u pg-receivewal`, looping every 10 seconds. The database side is not the one to fix: the role runs `ALTER ROLE … PASSWORD` on *every* playbook run, so Postgres always holds whatever `vault.yml` says — align `.pgpass` to that, not the reverse.

## 13.3 Verify — both ends, then end to end

```bash
# QDevice: service up, a .partial segment present
systemctl status pg-receivewal --no-pager | head -3
ls -lh /var/lib/wal-archive | tail -3

# 1022: the stream is live and confirmed
ssh devops@192.168.0.22 "sudo -u postgres psql -xc \
  \"select application_name, state, write_lsn, flush_lsn, sync_state from pg_stat_replication\""
# state = streaming — and pg_replication_slots.active is now t

# End to end: make a write, watch it land within seconds
ssh devops@192.168.0.22 "sudo -u postgres psql -c 'checkpoint'"   # forces WAL traffic
ls -l --time-style=full-iso /var/lib/wal-archive | tail -2         # mtime just moved
```

> **`write_lsn`/`flush_lsn`, not `replay_lsn`.** `replay_lsn` is a *standby* concept — the position a replica has applied. `pg_receivewal` applies nothing, it writes and flushes, so it reports those two and leaves `replay_lsn` NULL on a perfectly healthy stream. Judge this by `state = 'streaming'` and by the two positions advancing.

**Zero rows from that query means no walsender is attached at all** — not a column to interpret. The receiver itself says why, on the QDevice:

```bash
journalctl -u pg-receivewal -n 30 --no-pager
```

`no pg_hba.conf entry for replication connection from host "…"` is the common one, and it means 13.1's two variables don't match this QDevice: either `postgres_wal_stream_enabled` is still false (so the `pg_hba` block never rendered) or `postgres_wal_stream_cidr` carries an address the box no longer has. Fix them in `group_vars/all/main.yml` and re-run the playbook — note that the `pg_hba` template notifies a **restart**, not a reload, so 1022 blinks for a few seconds.

From here, [`backup-verify`](../scripts/README.md) checks the stream daily: slot active, lag bounded — silence-proof, like every other tier.

## 13.4 What this buys beyond the failover minute

The same archive is a **general point-in-time recovery window**: the nightly 03:00 vzdump of 1022 is a base, and the QDevice holds every WAL byte since. Restore last night's archive to a spare VM ID ([17.7 A](../backup/17-backup-restore.md#a-restore-into-a-new-vm-id-safest--start-here)), point `restore_command` at the archive with a `recovery_target_time`, and you can stand the database up **as of any second in the last 7 days** — "undo the bad migration that ran at 14:32" territory, which no amount of replication gives you. The mechanics are the same as scenario G with one extra line; G documents both.

## 13.5 Failure modes, stated plainly

- **Receiver down (QDevice off, service dead, network):** nothing breaks. Postgres holds WAL for it, up to 10GB; the receiver reconnects and resumes from the slot's bookmark. Your RPO is back to Stage 12's ~1 minute while it lasts — `backup-verify` flags it the next morning.
- **Receiver down past the 10GB cap:** the slot is invalidated — the deliberate trade (a broken stream over a full `db` disk). Recover: fix the receiver, then on 1022 drop and recreate the slot (`select pg_drop_replication_slot('wal_archive'); select pg_create_physical_replication_slot('wal_archive')` — or just re-run the playbook after dropping) and restart `pg-receivewal`.
- **The password is rotated in `vault.yml`:** the stream dies, silently, and the cause is structural rather than accidental. The database side is Ansible-owned — the role runs `ALTER ROLE … PASSWORD` on *every* playbook run — while `.pgpass` on the QDevice is written once by hand in [13.2](#132-the-receiver-on-the-qdevice) and reconciled by nothing, ever. So the run updates Postgres, the receiver keeps presenting the old secret, and `journalctl -u pg-receivewal` loops on `password authentication failed` every 10 seconds while the slot pins WAL toward the 10GB cap. Nothing in the application notices; `backup-verify` is the only thing that will tell you. **Rotate in this order:**

  1. new value into `vault.yml` (keep it alphanumeric — [13.2](#132-the-receiver-on-the-qdevice))
  2. `ansible-playbook playbooks/bootstrap.yml --limit postgres --diff` — Postgres now holds the new one
  3. rewrite `/var/lib/wal-archive/.pgpass` on the QDevice with the same value, `chown walarchive:walarchive`, `chmod 600`
  4. `systemctl restart pg-receivewal`, then confirm `state = streaming` and the slot back to `active = t` ([13.3](#133-verify--both-ends-then-end-to-end))

  The stream is down between steps 2 and 3, which is why they belong in one sitting. Reversing them doesn't help: the database is the authority, and a `.pgpass` written first is simply wrong until the playbook catches up. And the password is not recoverable from Postgres — it is stored as a SCRAM verifier — so if the two ever drift beyond repair, the only path is to set a new one on both ends.
- **After an unplanned failover, the stream does not resume by itself — and that is the archive's protection.** HA restarts 1022 from a ZFS replica, so the database comes back *behind* its own archive, on the same timeline (crash recovery never bumps it). `pg_receivewal` computes its start position from the newest complete segment on disk, asks for a position the server hasn't reached, and the walsender refuses:

  ```
  ERROR:  requested starting point 0/31000000 is ahead of the WAL flush position of this server 0/1B050560
  pg_receivewal: disconnected; waiting 5 seconds to try again
  ```

  **That refusal is real but conditional, and the condition usually does not hold.** It was observed on this build by planting a *complete* segment with a future name — which forces the receiver to request a position past a segment boundary. A real failover does not look like that. `pg_receivewal` derives its start position from the beginning of the newest segment on disk, and restarts a `.partial` from that segment's start. With a one-minute replication interval at a few MiB of WAL per minute, the rewind is **smaller than one 16 MiB segment**, so the requested position lands *behind* the server's flush position, the walsender accepts, and the `.partial` is rewritten with post-failover WAL under the same name on the same timeline (crash recovery never bumps the timeline). The tail of that `.partial` is precisely the lost window.

  So: assume the archive **can** be clobbered, and that the seconds you failed over through are the first thing destroyed.

  **`wal-archive-guard` is what now prevents it** ([13.2](#132-the-receiver-on-the-qdevice)). It runs as `ExecStartPre` on every start of the receiver, including the automatic restarts, and does one comparison: the newest segment name in the archive against `pg_walfile_name(pg_current_wal_lsn())` on 1022. WAL filenames are timeline plus position in hex, so lexical order is WAL order — an archive strictly greater than the server means the server went backwards. When it does, the guard renames the archive to `/var/lib/wal-archive.diverged-<timestamp>` and lets the receiver stream into a fresh directory. Nothing is deleted, the stream comes back on its own, and the window scenario G needs is sitting in the renamed directory instead of being overwritten by the reconnect.

  Two properties it was written to have: **it is never destructive on no answer** — an unreachable server exits 0 and the receiver simply retries, because "cannot ask" must not look like "diverged" — and it moves rather than deletes, so a false positive costs disk, not data. Its verdict lands in `journalctl -u pg-receivewal`.

  It is not a substitute for the real fix, which is not letting the rewound server take writes at all: recover it by rolling forward from the archive and promoting *before* the application starts, which bumps the timeline so post-recovery segments get new filenames and can no longer collide. The guard buys the time to do that.

  **Recovery, in this order:** move the diverged archive aside *first* — it is the input for [scenario G](../backup/17-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice), including the `.partial` — then let the receiver start against an empty directory and re-establish the stream. Doing it the other way round throws away the only copy of the window you failed over through.
- **Postgres major upgrade:** install the new `postgresql-client-NN` on the QDevice as part of the Stage 20 rehearsal, not after.
- **Turning it off:** `postgres_wal_stream_enabled: false`, run the playbook, then drop the slot by hand — a slot nobody reads is the one thing the playbook won't remove for you.
