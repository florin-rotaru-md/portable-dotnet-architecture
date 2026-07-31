# Quick troubleshooting

*Part of the [Proxmox homelab guide](README.md).*

- **An NVMe drive isn't visible at install** → VMD/RST in BIOS (Stage 0.1).
- **Replication fails** → does a pool with the same name exist on the target? Does it have space? (`zpool list`)
- **Migration is slow** → Migration Settings pointing at the wrong network (Stage 7).
- **"cluster not ready - no quorum"** → QDevice down/unreachable; emergency on the surviving node: `pvecm expected 1` (temporary!).
- **VM won't live-migrate** → ISO mounted in the CD drive (remove it) or non-migratable local resources attached.
- **VM crashed after migration** → someone set CPU type `host`; revert to `x86-64-v3`.
- **Migration fails after one node was updated and the other wasn't** → version skew. `pveversion -v` on both, `apt dist-upgrade` the lagging node, then migrate (Stage 16.2 / 20.5).
- **Replication says `no common base to restore the job state`** → the incremental chain is broken (long outage, pruned snapshots, or a `qm rollback`). Delete the job, remove the stale volumes on the target, recreate it — you get a full transfer.
- **A stopped VM keeps restarting itself** → it's an HA resource; `ha-manager set vm:<id> --state stopped` instead of `qm stop`.
- **`pg_upgradecluster` aborts on an extension** → the matching `postgresql-<newver>-postgis-3` package isn't installed. PostGIS is on `template1`, so *every* database needs it (Stage 20.3 step 1).
- **`pg_upgradecluster` says the target cluster already exists** → installing the package auto-created an empty one; `pg_dropcluster <newver> main --stop` first.
- **Postgres is up after a major upgrade but everything is slow** → statistics weren't carried over; `vacuumdb --all --analyze-in-stages`.
- **A playbook run reverts something you fixed by hand on a VM** → working as designed. `native/infra/ansible` owns everything inside the guests; change the role or the variable, not the file on the box.
- **Postgres minors aren't arriving automatically** → `postgres_auto_minor_upgrades` off, or unattended-upgrades broken. `sudo unattended-upgrade --dry-run -d | grep -i postgres` on 1030 and check `/var/log/unattended-upgrades/` (Stage 20.2).
- **Locked out of a VM over SSH** → Proxmox console + the `--cipassword` (Stage 21.4). No cipassword set → mount the VM disk from the hypervisor and edit `authorized_keys` by hand.
- **SSH accepts a password and it shouldn't** → `/etc/ssh/sshd_config.d/99-key-only.conf` missing (cloud-init flipped `ssh_pwauth` on) — re-run the playbook; the `common` role pins key-only (Stage 21.4).
- **pve1 died hard when the UPS ran dry** → NUT not installed or not answering; `upsc ups@localhost` should say `OL` (Stage 4).
- **A VM with an unexpected 19xx ID exists** → a restore drill that failed (kept for inspection) or ran with `--keep`; look, then `qm stop <id> && qm destroy <id>` (scripts/README).
- **No morning mail, ever, even when something's wrong** → root's mail isn't reaching you — the cron checks *and* backup/replication notifications all depend on it (Stage 15.3).
- **`backup-verify` says the WAL slot is inactive** → `pg-receivewal` on the QDevice is down — `systemctl status pg-receivewal` there; if it loops, it's `.pgpass`, `pg_hba`, or the network (Stage 13.3/13.5).
- **`pg_wal` growing on 1030** → the WAL receiver has been down a while; the slot retains WAL up to `max_slot_wal_keep_size` (10GB), then breaks the stream instead of the disk. Fix the receiver, then drop + recreate the slot (Stage 13.5).
- **After a Postgres major, the WAL stream won't reconnect** → the QDevice's client is the old major; install the matching `postgresql-client-NN` (Stage 13.5 / 20.3).
- **No app logs in Grafana** → check in order: `alloy` active on 1020 (`systemctl status alloy`), the `[monitoring]` group exists in `hosts.ini` (Alloy auto-discovers 1040 from it — no group, no target), `loki_bind_address`/`grafana_bind_address` actually set to 1040's IP and not left on the loopback default (Stage 11.4/11.7).
- **Grafana loads from the VM but not from my workstation** → `monitoring_allowed_cidr` unset or doesn't cover your subnet; the UFW rule on 1040 is what opens it beyond the VM itself (Stage 11.4).
- **Postgres (1030) logs don't show up in Grafana** → expected today, not a bug: Alloy only runs on the app host (Play 2); 1030's logs stay in the journal — `journalctl -u postgresql@18-main` (Stage 11.7).
- **`systemctl enable` says "the unit files have no installation config"** → that unit is *static* — it's meant to be started by something else (a udev rule, a timer, a target), not enabled. Use `systemctl start`; `qemu-guest-agent` is the one you'll meet here (Stage 9.4a). Beware `enable --now` on a static unit: the enable fails first, so it never starts either.

## Useful app debug commands
```bash
nginx -T | grep -A 10 -B 10 "upstream"
ss -lntp | grep 5000                      # blue slot; green is 5001
sudo lsof -i :5000
systemctl list-units --type=service | grep myapp
sudo systemctl restart myapp-blue.service # slots are <app>-blue / <app>-green
systemctl reload nginx
ps aux | grep myapp
readlink -f /proc/<PID>/exe

# which slot is live, and how to move between them
/opt/apps/myapp/scripts/current-slot.sh
/opt/apps/myapp/scripts/rollback.sh
```
