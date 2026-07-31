# Quick troubleshooting

*Part of the [waa Proxmox homelab guide](README.md).*

- **An NVMe drive isn't visible at install** → VMD/RST in BIOS (Stage 0.1).
- **Replication fails** → does a pool with the same name exist on the target? Does it have space? (`zpool list`)
- **Migration is slow** → Migration Settings pointing at the wrong network (Stage 6).
- **"cluster not ready - no quorum"** → QDevice down/unreachable; emergency on the surviving node: `pvecm expected 1` (temporary!).
- **VM won't live-migrate** → ISO mounted in the CD drive (remove it) or non-migratable local resources attached.
- **VM crashed after migration** → someone set CPU type `host`; revert to `x86-64-v3`.
- **Migration fails after one node was updated and the other wasn't** → version skew. `pveversion -v` on both, `apt dist-upgrade` the lagging node, then migrate (Stage 13.2 / 17.5).
- **Replication says `no common base to restore the job state`** → the incremental chain is broken (long outage, pruned snapshots, or a `qm rollback`). Delete the job, remove the stale volumes on the target, recreate it — you get a full transfer.
- **A stopped VM keeps restarting itself** → it's an HA resource; `ha-manager set vm:<id> --state stopped` instead of `qm stop`.
- **`pg_upgradecluster` aborts on an extension** → the matching `postgresql-<newver>-postgis-3` package isn't installed. PostGIS is on `template1`, so *every* database needs it (Stage 17.3 step 1).
- **`pg_upgradecluster` says the target cluster already exists** → installing the package auto-created an empty one; `pg_dropcluster <newver> main --stop` first.
- **Postgres is up after a major upgrade but everything is slow** → statistics weren't carried over; `vacuumdb --all --analyze-in-stages`.
- **A playbook run reverts something you fixed by hand on a VM** → working as designed. `native/infra/ansible` owns everything inside the guests; change the role or the variable, not the file on the box.
- **Postgres minors aren't arriving automatically** → `postgres_auto_minor_upgrades` off, or unattended-upgrades broken. `sudo unattended-upgrade --dry-run -d | grep -i postgres` on 1030 and check `/var/log/unattended-upgrades/` (Stage 17.2).
- **Locked out of a VM over SSH** → Proxmox console + the `--cipassword` (Stage 18.4). No cipassword set → mount the VM disk from the hypervisor and edit `authorized_keys` by hand.
- **SSH accepts a password and it shouldn't** → `/etc/ssh/sshd_config.d/99-key-only.conf` missing (cloud-init flipped `ssh_pwauth` on) — re-run the playbook; the `common` role pins key-only (Stage 18.4).

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
