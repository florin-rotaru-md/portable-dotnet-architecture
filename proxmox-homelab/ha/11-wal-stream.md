# Stage 11 — WAL streaming to the QDevice (RPO: from ~1 minute to seconds)

*Part of the [waa Proxmox homelab guide](../README.md).*

[Stage 10](10-replication.md)'s `*/1` schedule is the floor for VM-level replication: an unplanned failover loses up to ~a minute of writes, and [16.4](16-failover.md#164-what-failover-does-not-cover) says so honestly. This stage shrinks that window to **seconds** without touching the failover model: Postgres streams its write-ahead log to a receiver on the QDevice, continuously. When a node dies, HA still restarts 1030 from the ZFS replica exactly as before — but the seconds the replica is missing now exist on a third machine, and [scenario G](../backup/15-backup-restore.md#g-replaying-the-last-seconds-after-a-failover-wal-from-the-qdevice) replays them.

Why this variant and not a hot standby or synchronous replication: the stream is **event-driven and one-directional** — no writes means nothing flows (a few keepalive bytes), so it adds no pressure to either node, day or night. There's no promote/failback machinery to operate, no second database to keep in your head, and a receiver outage degrades you back to exactly today's RPO instead of blocking writes. The QDevice — a mini PC with a Core Ultra 5 225U, 16GB DDR5 and a 2TB NVMe — takes the entire cost, and barely notices: WAL at waa's scale is megabytes per day against two terabytes of disk.

## 11.1 Enable it on the database side

The `postgres` role owns everything on 1030 ([the ownership boundary](../operations/18-upgrades.md#185-the-same-pattern-applied-elsewhere)) and already knows how to do this — it's one switch plus the receiver's address. In `group_vars/all/main.yml`:

```yaml
postgres_wal_stream_enabled: true
postgres_wal_stream_cidr: "<qdevice-ip>/32"     # same IP as in Stage 7
```

and in `vault.yml` (generate something long; it also goes in the password manager — it's now part of the [19.1 inventory](../operations/19-credentials.md#191-inventory--what-exists-and-where-it-lives)):

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
ssh devops@192.168.0.30 "sudo -u postgres psql -tAc \"select slot_name, active from pg_replication_slots\""
# wal_archive | f        ← inactive until the receiver connects (11.3)
```

## 11.2 The receiver on the QDevice

The QDevice is hand-managed, like the Proxmox hosts — this section *is* its documentation (it joins `/etc/pve` in no backup, so [`pve-config-backup`](../scripts/README.md)'s philosophy applies: keep this reproducible from the guide). PGDG's client must match the server's major version — today `postgresql-client-18`, and bumping it is part of any [Stage 18.3](../operations/18-upgrades.md#183-major-upgrade--the-procedure) major upgrade.

```bash
# PGDG repo (same as the role configures on 1030), then the matching client
apt install -y curl ca-certificates
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/keyrings/postgresql.asc
echo "deb [signed-by=/usr/share/keyrings/postgresql.asc] http://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt update && apt install -y postgresql-client-18

# A dedicated user, the archive directory on the NVMe, and the credentials
useradd --system --home-dir /var/lib/wal-archive --create-home --shell /usr/sbin/nologin walarchive
install -o walarchive -g walarchive -m 600 /dev/null /var/lib/wal-archive/.pgpass
echo '192.168.0.30:5432:replication:walreceiver:<the password from vault.yml>' > /var/lib/wal-archive/.pgpass

cat << 'EOF' > /etc/systemd/system/pg-receivewal.service
[Unit]
Description=Stream Postgres WAL from 1030 (RPO in seconds — homelab guide 11)
After=network-online.target
Wants=network-online.target

[Service]
User=walarchive
# --synchronous: flush each write and report back, so "received" means "on this disk"
ExecStart=/usr/lib/postgresql/18/bin/pg_receivewal \
    --directory=/var/lib/wal-archive \
    --slot=wal_archive --synchronous \
    --host=192.168.0.30 --username=walreceiver --no-password
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pg-receivewal

# Retention: 7 days. Not for space (2TB yawns at this) — it's the PITR window (11.4).
# -name '*.partial' is the segment being written right now; never touch it.
cat << 'EOF' > /etc/cron.d/wal-archive-prune
30 5 * * * walarchive find /var/lib/wal-archive -type f ! -name '*.partial' -mtime +7 -delete
EOF
```

## 11.3 Verify — both ends, then end to end

```bash
# QDevice: service up, a .partial segment present
systemctl status pg-receivewal --no-pager | head -3
ls -lh /var/lib/wal-archive | tail -3

# 1030: the stream is live and confirmed
ssh devops@192.168.0.30 "sudo -u postgres psql -xc \
  \"select application_name, state, replay_lsn is not null as receiving, sync_state from pg_stat_replication\""
# state = streaming — and pg_replication_slots.active is now t

# End to end: make a write, watch it land within seconds
ssh devops@192.168.0.30 "sudo -u postgres psql -c 'checkpoint'"   # forces WAL traffic
ls -l --time-style=full-iso /var/lib/wal-archive | tail -2         # mtime just moved
```

From here, [`backup-verify`](../scripts/README.md) checks the stream daily: slot active, lag bounded — silence-proof, like every other tier.

## 11.4 What this buys beyond the failover minute

The same archive is a **general point-in-time recovery window**: the nightly 03:00 vzdump of 1030 is a base, and the QDevice holds every WAL byte since. Restore last night's archive to a spare VM ID ([15.7 A](../backup/15-backup-restore.md#a-restore-into-a-new-vm-id-safest--start-here)), point `restore_command` at the archive with a `recovery_target_time`, and you can stand the database up **as of any second in the last 7 days** — "undo the bad migration that ran at 14:32" territory, which no amount of replication gives you. The mechanics are the same as scenario G with one extra line; G documents both.

## 11.5 Failure modes, stated plainly

- **Receiver down (QDevice off, service dead, network):** nothing breaks. Postgres holds WAL for it, up to 10GB; the receiver reconnects and resumes from the slot's bookmark. Your RPO is back to Stage 10's ~1 minute while it lasts — `backup-verify` flags it the next morning.
- **Receiver down past the 10GB cap:** the slot is invalidated — the deliberate trade (a broken stream over a full `db` disk). Recover: fix the receiver, then on 1030 drop and recreate the slot (`select pg_drop_replication_slot('wal_archive'); select pg_create_physical_replication_slot('wal_archive')` — or just re-run the playbook after dropping) and restart `pg-receivewal`.
- **Postgres major upgrade:** install the new `postgresql-client-NN` on the QDevice as part of the Stage 18 rehearsal, not after.
- **Turning it off:** `postgres_wal_stream_enabled: false`, run the playbook, then drop the slot by hand — a slot nobody reads is the one thing the playbook won't remove for you.
