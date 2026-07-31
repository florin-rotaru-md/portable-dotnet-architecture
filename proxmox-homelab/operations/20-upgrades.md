# Stage 20 — Upgrading Postgres (and the pattern for any in-VM upgrade)

*Part of the [Proxmox homelab guide](../README.md).*

Everything up to here protects you from hardware failing. This stage is about the other half of the risk: **planned changes you make yourself**. A botched database upgrade takes the app down just as effectively as a dead node, and unlike a dead node it has no automatic recovery — HA can't fail over from a bad schema.

**Nothing is installed on these VMs by hand.** Postgres, PostGIS, `pg_hba.conf`, the firewall rule, the app DB user and the nightly dump job all come from the `postgres` role in [`native/infra/ansible`](../../native/infra/ansible/roles/postgres/tasks/main.yml), driven from control-ubuntu (1010). That constrains the procedure below in a specific way: **Ansible owns packages and configuration, but it does not own the data directory.** A major upgrade is therefore a hybrid — the playbook installs the new version and converges the config, and `pg_upgradecluster` does the one thing the playbook can't. Doing it by hand instead means the next `bootstrap.yml` run silently disagrees with reality.

## 20.1 Minor and major upgrades are different operations

Current version is set in one place — `postgres_version` in [`inventory/group_vars/all/main.yml`](../../native/infra/ansible/inventory/group_vars/all/main.yml), today `"18"`, with `postgis_major_version: "3"`.

| | Minor (18.1 → 18.4) | Major (18 → 19) |
|---|---|---|
| On-disk format | Unchanged | **Changes** — the data directory is rewritten |
| `postgres_version` | Unchanged | Bumped, and the change is committed to git |
| Mechanism | **Automatic** — `unattended-upgrades` with the PGDG origin (see 20.2) | Playbook installs the new version → `pg_upgradecluster` → playbook again |
| Downtime | Seconds (service restart) | Minutes, dominated by database size |
| Rollback | Reinstall the old package | Keep the old cluster until you're sure, and revert the variable |
| Risk | Low — but read the release notes; a minor release occasionally requires a `REINDEX` | Real. PostGIS, removed config settings, deprecated syntax |
| Cadence | Within ~24h of publication, unattended | Once a year at most, deliberately, never during a peak-traffic window |

Do not conflate them. Minor upgrades are routine hygiene the machine handles itself; major upgrades are a project with a rehearsal.

## 20.2 Minor upgrades — automatic, by design

Minors are the quarterly security fixes: you want them promptly and there is nothing version-specific to decide, which makes them the one database change worth automating. The `postgres` role does it with two mechanisms, switched by one variable in group_vars:

```yaml
# native/infra/ansible/inventory/group_vars/all/main.yml
postgres_auto_minor_upgrades: true
```

| Mechanism | When it acts | What it does |
|---|---|---|
| `state: latest` on the install task | Every `bootstrap.yml` run | Converges to the current minor while it's touching the host anyway |
| `unattended-upgrades` + PGDG origin | Daily, via `apt-daily-upgrade.timer` (~06:00) | Installs new minors within ~24h of publication — no playbook run needed |

The second one carries the weight; the first just keeps rehearsal clones and fresh bootstraps from starting life a few patches behind. The role installs `unattended-upgrades`, drops `/etc/apt/apt.conf.d/51pgdg-unattended-upgrades` adding `origin=apt.postgresql.org` to the allowed origins, and enables the daily timer. Ubuntu's own security updates ride the same mechanism.

**Why this is safe to automate — and why majors never are:** the package name embeds the major version. 18.1 → 18.2 is an upgrade of the *same* package, `postgresql-18`; PostgreSQL 19 is a *different package* that no automatic mechanism will ever pull in. The blast radius of automation is structurally bounded to minors. A major happens exactly one way: you bump `postgres_version` and run the playbook (20.3).

**The cost, stated honestly:** installing a minor restarts the cluster — a few seconds, at whatever moment the apt timer fires. In-flight requests during those seconds fail; at ~06:00 against the app's traffic that's a non-event, and Npgsql's pool recovers on the next request. If a deterministic window ever matters, pin it (`systemctl edit apt-daily-upgrade.timer` → `OnCalendar=*-*-* 06:00`) rather than turning automation off.

**Verify it's actually working** — do this once after bootstrap, then whenever release notes make you curious:

```bash
# on 1030: what unattended-upgrades would do right now
sudo unattended-upgrade --dry-run -d 2>&1 | grep -i postgres

# what it has done — the dpkg log is the definitive record
grep -i postgres /var/log/unattended-upgrades/unattended-upgrades.log | tail
zgrep " upgrade postgresql-18" /var/log/dpkg.log* | tail

sudo -u postgres psql -tAc 'select version()'
```

A silently broken unattended-upgrades has the same failure shape as a silently failing replication job ([15.3](../ha/15-ha.md#153-notifications)): everything looks fine until the day it matters. The `--dry-run` check belongs in the same periodic sweep as [18.7](../ha/18-failover.md#187-health-checks-worth-running-periodically).

**Opting out:** set `postgres_auto_minor_upgrades: false` and re-run the playbook — it removes the PGDG origin file (Ubuntu's own security updates keep flowing). Minors then become your job, quarterly, from control-ubuntu:

```bash
ansible postgres -b --become-user postgres -m command -a '/opt/postgres/scripts/pg-backup.sh'
ansible postgres -b -m apt -a 'name=postgresql-18,postgresql-18-postgis-3 state=latest update_cache=true'
ansible postgres -b -m shell -a 'runuser -u postgres -- psql -tAc "select version()"'
```

## 20.3 Major upgrade — the procedure

### Step 0. Rehearse on a restored copy. Do not skip this.

This is the single highest-value step in the whole stage, and the architecture already supports it — it's [17.7 scenario A](../backup/17-backup-restore.md#a-restore-into-a-new-vm-id-safest--start-here) with a different purpose. You hit every extension error, every removed config setting, and every surprise on a throwaway VM instead of on production, and you come out with a measured duration rather than a guess.

```bash
# on the node holding the archive
qmrestore /mnt/usb-backup/dump/vzdump-qemu-1030-<date>.vma.zst 1130 \
  --storage apps --unique
```

⚠️ **The clone must not keep `192.168.0.30`.** Cloud-init gave 1030 a static address; a second VM claiming it takes the real database offline. Either uncheck Hardware → Network Device → *Connected* and work entirely through the console, or — better — set a spare IP via Cloud-init (say `192.168.0.130`) before first boot and point a scratch inventory entry at it:

```ini
# native/infra/ansible/inventory/hosts.ini — temporary, do not commit
[pgrehearsal]
192.168.0.130 ansible_user=devops ansible_private_key_file=~/.ssh/id_ed25519_devops
```

The second option is worth the extra five minutes: it rehearses the *Ansible* path, not just the `pg_upgradecluster` invocation, which is where the surprises actually live. Run the whole procedure below against `--limit pgrehearsal`, write down how long each step took, then `qm stop 1130 && qm destroy 1130` and delete the inventory entry.

### Step 1. Pre-flight

```bash
ansible postgres -m shell -a 'pg_lsclusters' -b
```

**Extensions are the number one cause of a failed `pg_upgrade`**, and in this setup you already know you have one: the role runs `CREATE EXTENSION postgis` on `template1`, so **every database inherits PostGIS**. The new major version needs `postgresql-19-postgis-3` present before the upgrade or it aborts partway.

The good news is that the role parameterises exactly this — `postgresql-{{ postgres_version }}-postgis-{{ postgis_major_version }}` — so bumping one variable pulls the right package. The thing to verify first is that PGDG has actually published PostGIS for the target version, which lags a new Postgres major by weeks:

```bash
ansible postgres -m shell -a 'apt-cache policy postgresql-19-postgis-3' -b
```

Confirm nothing else has crept in. Nested quoting makes this miserable through `ansible -a`, so run it over SSH on 1030 — it's read-only:

```bash
sudo -u postgres psql -Atc \
  "select datname from pg_database where datallowconn" |
while read db; do
  echo "== $db"
  sudo -u postgres psql -d "$db" -Atc "select extname, extversion from pg_extension"
done
```

**Disk space** — `pg_upgradecluster` in copy mode writes a second full copy of the data directory:

```bash
ansible postgres -b -m shell -a 'du -sh /var/lib/postgresql/18/main; df -h /var/lib/postgresql'
```

Want ≥ 2× the data directory free. The 640GB disk from [Stage 10](../vms/10-vms.md#grow-the-disk--per-vm) makes this a formality at this app's size, but check rather than assume.

### Step 2. The safety net — three layers, take all three

| Layer | Command | Recovers from | Cost |
|---|---|---|---|
| **Logical dump** | `ansible postgres -b --become-user postgres -m command -a '/opt/postgres/scripts/pg-backup.sh'` | Anything, including "PG19 starts fine but the data is wrong". Version-independent — the per-database `-Fc` dumps restore into any Postgres | Minutes |
| **VM backup** | `vzdump 1030 --storage usb-backup --mode snapshot --compress zstd` | The whole VM being unrecoverable. Survives the VM being destroyed | Minutes, off-VM |
| **VM snapshot** | see below | Everything else — this is your actual undo button | Seconds to take, seconds to roll back |

The logical dump is the role's own nightly script from [17.5](../backup/17-backup-restore.md#175-a-fourth-tier-for-the-database), run on demand — don't hand-roll a `pg_dumpall` next to it. It writes globals plus one custom-format dump per database into `/opt/postgres/backups`, which lives on the VM disk and is therefore captured by the `vzdump` in the next row.

The snapshot has cluster interactions, so take it deliberately:

```bash
# a cleanly stopped database removes all ambiguity
ansible postgres -m service -a 'name=postgresql state=stopped' -b

# on the Proxmox node holding 1030
qm snapshot 1030 pre-pg19 --description "postgres 18 -> 19, before pg_upgradecluster"

ansible postgres -m service -a 'name=postgresql state=started' -b
```

`qemu-guest-agent` ([9.4](../vms/09-ubuntu-template.md#94-prepare-the-guest)) freezes the filesystem for a live snapshot, so a running snapshot would be consistent too — but stopping the service costs thirty seconds and makes the recovery path unambiguous. Do the cheap thing.

> **HA will fight you if you stop the *VM*.** 1030 is an HA resource with desired state `started`; a `qm stop` gets undone by the HA manager within seconds. Before anything that stops the VM (including a rollback), tell HA first:
> ```bash
> ha-manager set vm:1030 --state stopped
> # ... do the work ...
> ha-manager set vm:1030 --state started
> ```
> Stopping the *postgres service* inside the VM never involves HA — it only watches the VM.

### Step 3. Preconditions before you start

- **Both nodes up, `pvesr status` all OK.** Never run a major upgrade while the peer is down — that's removing the safety net at the exact moment you're most likely to need it.
- **No migration in flight**, and don't start one during the upgrade.
- **A quiet window.** The database is down for the duration: writes and edits fail, the frontend keeps serving from Cloudflare ([18.4](../ha/18-failover.md#184-what-failover-does-not-cover)). Announce accordingly.
- **An abort deadline.** Decide up front: *"if it isn't verified good in 45 minutes, I roll back and reschedule."* Debugging a half-migrated database at 1am is how a 20-minute maintenance becomes a four-hour outage.

### Step 4. Bump the variable, run the playbook

The role already adds the PGDG repository and signing key, so there is nothing to configure — the version is data:

```yaml
# native/infra/ansible/inventory/group_vars/all/main.yml
postgres_version: "19"        # was "18"
```

Commit it. The whole point of the variable is that the git history records when the database changed major version.

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible-playbook playbooks/bootstrap.yml --limit postgres --diff
```

This installs `postgresql-19` and `postgresql-19-postgis-3` and writes `pg_hba.conf` and `listen_addresses` into `/etc/postgresql/19/main/`. The data-level tasks — creating the app role, `CREATE EXTENSION postgis` — connect over port 5432, which is **still the old cluster**, so they're no-ops against live data. Nothing has moved yet.

> Don't reach for `--check` here. The role uses `command` tasks that Ansible skips in check mode, which leaves `pg_user_check` undefined and blows up the `when` clause on the next task. `--diff` without `--check` is the useful dry-run signal for this role.

Installing the package **auto-creates an empty `19/main` cluster on port 5433**. It must go, or `pg_upgradecluster` refuses to run:

```bash
ansible postgres -b -m shell -a 'pg_dropcluster 19 main --stop; pg_lsclusters'
```

### Step 5. Upgrade the data

Stop the app slots first, so nothing writes to a database that's about to be frozen:

```bash
ansible app -m service -a 'name=myapp-blue.service state=stopped' -b
```

Then, on 1030 — this one is interactive enough to be worth doing over SSH rather than through Ansible, because you want to read its output as it goes:

```bash
sudo pg_upgradecluster -m upgrade 18 main
```

`pg_upgradecluster` stops the old cluster, runs `pg_upgrade`, copies `postgresql.conf` and `pg_hba.conf` forward, gives the new cluster the old one's port, and leaves `18/main` stopped and disabled from autostart. The old data directory is **left intact** — that's what makes rollback and step 9 possible.

> `-m link` uses hard links instead of copying and is dramatically faster on a large database, **but it destroys the rollback path**: the two data directories share blocks, and once the new cluster starts the old one is unusable. Only choose it if copy time is genuinely prohibitive, and understand that you're then relying entirely on the VM snapshot.

### Step 6. Run the playbook again — this is the step that's easy to skip

`pg_upgradecluster` carried the *old* cluster's config into `/etc/postgresql/19/main/`. That config is a copy, not the source of truth; Ansible's templates are. Converge them:

```bash
ansible-playbook playbooks/bootstrap.yml --limit postgres --diff
```

Now port 5432 belongs to PG19, so this run also re-asserts the app role, its password, and the PostGIS extension against the *new* cluster — and reinstalls the backup cron pointing at the right binaries. Skipping it leaves you with a database whose configuration nobody owns, which surfaces months later as a mystery diff on an unrelated playbook run.

### Step 7. Post-upgrade database work

Two things `pg_upgrade` deliberately does not do. Both on 1030, over SSH:

```bash
# 1. Statistics are NOT carried forward. Without this, the first queries hit
#    the planner with no data and performance looks catastrophic.
sudo -u postgres vacuumdb --all --analyze-in-stages

# 2. The PostGIS binaries are new, but each database still records the old
#    extension version. Update it per database.
#    (datallowconn already excludes template0.)
sudo -u postgres psql -Atc \
  "select datname from pg_database where datallowconn" |
while read db; do
  sudo -u postgres psql -d "$db" -c "ALTER EXTENSION postgis UPDATE"
done
```

The `--analyze-in-stages` step is the classic post-upgrade trap: everything looks fine, then the site is unusably slow under load because the planner is flying blind. Run it before you declare success, not after someone complains.

### Step 8. Verify, then let traffic back in

On 1030:

```bash
pg_lsclusters                                   # 19/main online on 5432, 18/main down
sudo -u postgres psql -tAc "select version(), postgis_version()"
sudo journalctl -u postgresql@19-main --since '30 min ago' | grep -iE 'error|fatal'

# settings renamed or removed between majors
diff <(grep -vE '^\s*#|^\s*$' /etc/postgresql/18/main/postgresql.conf) \
     <(grep -vE '^\s*#|^\s*$' /etc/postgresql/19/main/postgresql.conf)
```

> **Rule of thumb for this whole stage:** state changes go through the playbook, diagnostics go over SSH. Ansible's `shell` module runs under `/bin/sh`, so process substitution and nested quoting turn read-only checks into debugging exercises about quoting rather than about Postgres.

Then start the app and do the checks that actually matter — application-level, not server-level:

```bash
ansible app -m service -a 'name=myapp-blue.service state=started' -b
```

Load the site, exercise the app's main write path, confirm the row lands. A Postgres that starts is not the same as a Postgres your application works against — and with `Pooling=true` in the connection string, a stale pool produces failures that look like database problems but aren't.

### Step 9. Soak, then clean up

Leave `18/main` and the snapshot in place for **at least a few days of real traffic** — long enough for a slow query or a rarely-hit code path to surface. Then:

```bash
ansible postgres -b -m shell -a 'pg_dropcluster 18 main'
ansible postgres -b -m apt -a 'name=postgresql-18,postgresql-18-postgis-3 state=absent purge=true'
```

```bash
# on the Proxmox node — snapshots are not free, and this one blocks nothing but disk
qm delsnapshot 1030 pre-pg19
```

> **Don't leave the snapshot forever.** A VM snapshot on ZFS pins blocks the same way a replication snapshot does ([Stage 12](../ha/12-replication.md#stage-12--zfs-replication)) — space consumption grows with everything the database writes afterward. Deleting it is the last step of the upgrade, not an optional tidy-up.

## 20.4 Rollback

⚠️ **Revert `postgres_version` in `group_vars` as the first move, whichever path you take.** Otherwise the next `bootstrap.yml` run — possibly weeks later, for an unrelated reason — reinstalls PG19 and rewrites config into a cluster you abandoned. The variable and reality must agree at all times; that's the price of Ansible owning the config.

**Within the maintenance window, before any new writes** — the snapshot, and it's near-instant:

```bash
ha-manager set vm:1030 --state stopped
qm rollback 1030 pre-pg19
ha-manager set vm:1030 --state started
pvesr status            # expect the next run to be a full transfer, see below
```

**If you've already dropped the snapshot but kept `18/main`** — put the old cluster back on the port:

```bash
sudo pg_ctlcluster 19 main stop
sudo nano /etc/postgresql/18/main/postgresql.conf     # port = 5432
echo auto | sudo tee /etc/postgresql/18/main/start.conf
sudo pg_ctlcluster 18 main start
```
Then re-run the playbook with the reverted variable so config, the app role and the backup cron converge back onto 18.

**Last resort** — restore the VM backup to a new VM ID and reload from `/opt/postgres/backups`: `globals_*.sql.gz` first, then `pg_restore` each `<db>_*.dump`. This path works across major versions, which is exactly why the role dumps in custom format rather than relying on the VM image alone.

⚠️ **Every rollback path discards writes made against the new cluster.** This is why step 3 keeps the application stopped until step 6 passes: while nothing has written, rollback is free. Once writes have landed in PG17, rolling back means losing them, and you're into reconciling by hand.

> **`qm rollback` diverges the local dataset from the last replicated snapshot,** so the next replication run needs a full transfer instead of a delta. Not a problem — just don't be alarmed by `pvesr status` showing a long-running job, and don't schedule the rollback expecting replication to be caught up two minutes later.

## 20.5 The same pattern, applied elsewhere

The shape generalizes: *rehearse on a restored copy → snapshot → change → verify at the application level → soak → delete the snapshot*. What varies is the mechanism — and, importantly, **who owns the change.**

> **The ownership boundary.** The two Proxmox hosts are managed by hand; everything inside the VMs comes from `native/infra/ansible`. That's why Stages 16 and 19 are shell procedures on the node while Stage 20 is a variable bump plus a playbook run. Keep the boundary clean: don't hand-edit `/etc/postgresql/*` on 1030, and don't try to bring the hypervisors under Ansible for the sake of symmetry — two nodes configured twice a decade is not a fleet.

**Ubuntu release upgrade inside a VM** (26.04 → nn.nn): same procedure, `do-release-upgrade` in place of `pg_upgradecluster`. Upgrade the app VM and the database VM in separate windows, never together — with two changes in flight you can't tell which one broke. There's one interaction specific to this role: the PGDG apt line is templated from `ansible_facts['distribution_release']`, so it still says `noble` after the OS moves on. Re-run `bootstrap.yml --limit postgres` afterwards to rewrite `/etc/apt/sources.list.d/pgdg.list` for the new release, before the next `apt update` starts resolving against a stale suite.

**.NET runtime upgrades** follow the identical pattern one variable over — `dotnet_version` in the same `group_vars` file, then `bootstrap.yml --limit app`. Bump one thing per window.

**Proxmox host upgrades** are where the two-node design pays off properly — rolling, zero downtime, but **the order matters and it's the reverse of what feels natural**:

1. Evacuate pve2 (Bulk Migrate → pve1), upgrade pve2, reboot.
2. Migrate the VMs **from pve1 onto the freshly upgraded pve2**. Older QEMU → newer QEMU migrates cleanly; newer → older is what fails.
3. Upgrade pve1, reboot, rebalance.

Doing it the other way — upgrading pve1 first and then trying to migrate onto the un-upgraded pve2 — strands the VMs on one node. Same root cause as the version-skew warning in [16.2](16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks). For a major PVE release, read the official upgrade notes first; for point releases this is all it takes.

**Application deploys** need none of this. The app role already ships blue/green: `deploy.sh` builds into the idle slot, `health-check.sh` gates it, `switch-nginx.sh` flips the upstream, and `rollback.sh` flips it back. Rolling back a bad release is a script on 1020, not a hypervisor operation — and if it ever isn't, the problem is in the deploy pipeline, not in Proxmox.
