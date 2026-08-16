# Quick troubleshooting

*Part of the [Proxmox lab guide](README.md).*

- **An NVMe drive isn't visible at install** → VMD/RST in BIOS (Stage 0.1).
- **A node stopped seeing its NVMe drives, or won't boot, right after a BIOS update** → the flash reset the settings to defaults and VMD/RST came back on. Redo Stage 0.1 in full — VT-x/VT-d and "restore on AC" are gone too, and the last one fails silently until the next power cut (16.3, "After every flash").
- **A node is unreachable after a BIOS update, both corosync rings down** → the NICs were renamed, so `/etc/network/interfaces` now configures nothing. Physical console, then the same fix as a disk transplant: new names in, `ifreload -a` (19.3 step 5 / 16.3).
- **Replication fails** → does a pool with the same name exist on the target? Does it have space? (`zpool list`)
- **Replication says `storage 'apps' is not available on node 'pve2'`, but the pool is right there in Disks → ZFS** → the pool exists, the *storage definition* is pinned to pve1 — Stage 6's *Add Storage* checkbox writes `nodes <that node>`, and the join discarded pve2's own copy of `storage.cfg`. `pvesm set apps --delete nodes` (same for `db`), then re-run the job (Stage 6).
- **Migration is slow** → Migration Settings pointing at the wrong network (Stage 7).
- **"cluster not ready - no quorum"** → QDevice down/unreachable; emergency on the surviving node: `pvecm expected 1` (temporary!).
- **VM won't live-migrate** → ISO mounted in the CD drive (remove it) or non-migratable local resources attached.
- **VM crashed after migration** → someone set CPU type `host`; revert to `x86-64-v3`.
- **Migration fails after one node was updated and the other wasn't** → version skew. `pveversion -v` on both, `apt dist-upgrade` the lagging node, then migrate (Stage 16.2 / 20.5).
- **Replication says `no common base to restore the job state`** → the incremental chain is broken (long outage, pruned snapshots, or a `qm rollback`). Delete the job, remove the stale volumes on the target, recreate it — you get a full transfer.
- **A stopped VM keeps restarting itself** → it's an HA resource; `ha-manager set vm:<id> --state stopped` instead of `qm stop`.
- **A node was shut down and rebooted, and its VMs didn't come back** → two causes, in this order. (1) `onboot` is 0 — Proxmox's default for every new VM; only HA guests (1021/1022) start on their own, so 1023 needs the flag: `qm set <id> --onboot 1 --startup order=N` (Stage 10, "Start at boot"). (2) The node booted **inquorate** — other node *and* QDevice down — so `/etc/pve` is read-only and nothing starts at all, HA included; `pvecm status` first, then 18.5. And after a clean shutdown with `shutdown_policy=migrate`, HA VMs are running on the *other* node by design — they don't fail back (16.2).
- **`pg_upgradecluster` aborts on an extension** → the matching `postgresql-<newver>-postgis-3` package isn't installed. PostGIS is on `template1`, so *every* database needs it (Stage 20.3 step 1).
- **`pg_upgradecluster` says the target cluster already exists** → installing the package auto-created an empty one; `pg_dropcluster <newver> main --stop` first.
- **Postgres is up after a major upgrade but everything is slow** → statistics weren't carried over; `vacuumdb --all --analyze-in-stages`.
- **A playbook run reverts something you fixed by hand on a VM** → working as designed. `native/infra/ansible` owns everything inside the guests; change the role or the variable, not the file on the box.
- **Postgres minors aren't arriving automatically** → `postgres_auto_minor_upgrades` off, or unattended-upgrades broken. `sudo unattended-upgrade --dry-run -d | grep -i postgres` on 1022 and check `/var/log/unattended-upgrades/` (Stage 20.2).
- **A VM answers on a DHCP address, not the one in its Cloud-Init tab** → that tab shows what the hypervisor offers, never what the guest took. Almost always: the VM booted once *before* the IP was set, and cloud-init applies network config per *instance*, not per boot — a plain reboot won't fix it. `qm agent <id> network-get-interfaces` for the truth, then Stage 10 ("First boot"): destroy + `create-vms` if it's still empty, otherwise `cloud-init clean --logs` inside the guest.
- **A VM took its static IP but is unreachable** → your LAN isn't `192.168.0.0/24` (the guide hard-codes it — vmbr0, the gateway, the `create-vms` table), or `.20–.23` sit inside the router's DHCP pool and something else claimed the address (Stage 10, "First boot").
- **SSH asks for no password and refuses the cipassword** → working as designed: Canonical's cloud image ships `PasswordAuthentication no` in `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`, from the first boot. The cipassword is the *console* login. Get in with a key, from pve1 (Stage 10, "SSH access").
- **`ssh-copy-id` can't seed a key on a new VM** → it needs password auth to install the key, and there is none (above). Deliver it from something already trusted instead — from pve1: `ssh devops@<ip> 'cat >> ~/.ssh/authorized_keys' < key.pub` — or add it to `vm_keys.pub` and re-apply `--sshkeys` (next bullet). After Stage 11, the right place is `ansible_ssh_extra_public_keys` (21.6).
- **`Permission denied (publickey)` from my workstation, but pve1 gets in fine** → only the keys in the template's `--sshkeys` file exist on a fresh clone. Add yours to `/root/.ssh/vm_keys.pub`, `qm set <id> --sshkeys` + reboot (Stage 10, "From your workstation"). `ssh -J` does not help — it still authenticates *you* to the VM.
- **`ssh devops@<vm>` from pve1 stopped working after a playbook run** → `ssh_authorized_keys_exclusive: true` with the node root keys missing from `ansible_ssh_extra_public_keys` — the run deleted them from every VM. Add both nodes' `id_ed25519.pub` to the list and re-run; until then get in from your workstation or the console (Stage 21.6).
- **Locked out of a VM over SSH** → Proxmox console + the `--cipassword` (Stage 21.4). No cipassword set → mount the VM disk from the hypervisor and edit `authorized_keys` by hand.
- **SSH accepts a password and it shouldn't** → `/etc/ssh/sshd_config.d/99-key-only.conf` missing (cloud-init flipped `ssh_pwauth` on) — re-run the playbook; the `common` role pins key-only (Stage 21.4).
- **pve1 died hard when the UPS ran dry** → NUT not installed or not answering; `upsc ups@localhost` should say `OL` (Stage 4).
- **A VM with an unexpected 19xx ID exists** → a restore drill that failed (kept for inspection) or ran with `--keep`; look, then `qm stop <id> && qm destroy <id>` ([`restore-drill`](scripts/README.md)).
- **No morning mail, ever, even when something's wrong** → root's mail isn't reaching you — the cron checks *and* backup/replication notifications all depend on it (Stage 15.3).
- **[`backup-verify`](scripts/README.md) says the WAL slot is inactive** → `pg-receivewal` on the QDevice is down — `systemctl status pg-receivewal` there; if it loops, it's `.pgpass`, `pg_hba`, or the network (Stage 13.3/13.5).
- **`pg_wal` growing on 1022** → the WAL receiver has been down a while; the slot retains WAL up to `max_slot_wal_keep_size` (10GB), then breaks the stream instead of the disk. Fix the receiver, then drop + recreate the slot (Stage 13.5).
- **After a Postgres major, the WAL stream won't reconnect** → the QDevice's client is the old major; install the matching `postgresql-client-NN` (Stage 13.5 / 20.3).
- **No app logs in Grafana** → check in order: `alloy` active on 1021 (`systemctl status alloy`), the `[monitoring]` group exists in `hosts.ini` (Alloy auto-discovers 1023 from it — no group, no target), `loki_bind_address`/`grafana_bind_address` actually set to 1023's IP and not left on the loopback default (Stage 11.4/11.7).
- **`docker compose ps` on 1023 says `permission denied ... /var/run/docker.sock`** → `devops` is not in the `docker` group and deliberately stays out (that group is root-equivalent on the VM). Prefix every `docker` command there with `sudo` (Stage 11.6).
- **Grafana loads from the VM but not from my workstation** → `monitoring_allowed_cidr` unset or doesn't cover your subnet; the UFW rule on 1023 is what opens it beyond the VM itself (Stage 11.4).
- **Postgres (1022) logs don't show up in Grafana** → expected today, not a bug: Alloy only runs on the app host (Play 2); 1022's logs stay in the journal — `journalctl -u postgresql@18-main` (Stage 11.7).
- **`psql`/pgAdmin from my workstation to 1022 times out** → working as designed: `postgres_app_cidr` is the app VM's `/32`, so only 1021 gets through UFW/`pg_hba.conf`. Opt in with `postgres_extra_cidrs` and re-run the playbook (Stage 11.8).
- **Proxmox shows a VM at ~80% memory but nothing on it is working hard** → the summary panel counts page cache as used, and Linux fills free RAM with cache deliberately, reclaiming it the moment anything asks. The guest has the truth: `free -h` — read the **`available`** column, not `free` — plus `/proc/pressure/memory`. A non-zero PSI `full` average is real pressure; a large `buff/cache` is not. These guests run without swap, so `si`/`so` in `vmstat` stay at zero whatever happens and prove nothing on their own. A healthy 1021 sits near 800 MiB of its 8 GiB with ~6 GiB cached, which the panel reports as ~80%.
- **`systemctl enable` says "the unit files have no installation config"** → that unit is *static* — it's meant to be started by something else (a udev rule, a timer, a target), not enabled. Use `systemctl start`; `qemu-guest-agent` is the one you'll meet here, on the ISO template route (Stage 9.8d — the primary route injects it without ever running systemctl). Beware `enable --now` on a static unit: the enable fails first, so it never starts either.

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
