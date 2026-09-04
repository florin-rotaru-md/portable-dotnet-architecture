# Quick troubleshooting

*Part of the [Proxmox lab guide](README.md).*

- **An NVMe drive isn't visible at install** → VMD/RST in BIOS (Stage 0.1).
- **A node stopped seeing its NVMe drives, or won't boot, right after a BIOS update** → the flash reset the settings to defaults and VMD/RST came back on. Redo Stage 0.1 in full — VT-x/VT-d and "restore on AC" are gone too, and the last one fails silently until the next power cut (16.3, "After every flash").
- **A node is unreachable after a BIOS update, both corosync rings down** → the NICs were renamed, so `/etc/network/interfaces` now configures nothing. Physical console, then the same fix as a disk transplant: new names in, `ifreload -a` (19.3 step 5 / 16.3).
- **Replication fails** → does a pool with the same name exist on the target? Does it have space? (`zpool list`)
- **Replication says `storage 'apps' is not available on node 'pve2'`, but the pool is right there in Disks → ZFS** → the pool exists, the *storage definition* is pinned to pve1 — Stage 6's *Add Storage* checkbox writes `nodes <that node>`, and the join discarded pve2's own copy of `storage.cfg`. `pvesm set apps --delete nodes` (same for `db`), then re-run the job (Stage 6).
- **Migration is slow** → Migration Settings pointing at the wrong network (Stage 7).
- **Migration and replication both stop after the 10G link dies** → corosync fails over to Link 1 on its own; these two don't — they read the migration network out of `datacenter.cfg`, which pins them to `10.10.10.0/24`. Cable out ⇒ the address is still configured on the interface, so the transfer hangs until it times out; NIC gone entirely ⇒ `could not get migration ip: no IP address configured on local node for network 10.10.10.0/24`. Runbook below.
- **The QDevice answers `ping` but refuses SSH** → `openssh-server` isn't installed — the *SSH server* checkbox at Debian's Software selection was missed, and nothing says so until you try. At the console: `ss -lntp | grep ':22'` (empty ⇒ confirmed), then `apt install -y openssh-server && systemctl enable --now ssh` (Stage 8.2). Don't diagnose this with `systemctl status ssh`: trixie socket-activates sshd, so a healthy box reports `inactive (dead)` for the service while `ssh.socket` holds the port.
- **`ssh root@` the QDevice says `Permission denied (publickey)`** → working as designed, and *not* the same fault as the line above: sshd is fine, Debian just ships `PermitRootLogin prohibit-password`. Go in as the normal user and install root's keys (Stage 8.4) — never by flipping `PermitRootLogin yes`.
- **`pvecm qdevice setup` dies with `corosync-qdevice-net-certutil: command not found`** → the `corosync-qdevice` package is missing on the *nodes* (it's the one that ships that tool; `corosync-qnetd` on the QDevice is the other half). The message names no package and arrives only after a page of `INFO` lines that look like success. `apt install -y corosync-qdevice` on **both** nodes, then retry with `--force` — the qnetd database survives the failed run and a plain re-run stops at `nssdb already exists` (Stage 8.5).
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
- **pve1 died hard when the UPS ran dry** → expected on this build: the UPS has no data path to pve1, so NUT is disabled and nothing can signal the shutdown ([4.6](setup/04-ups.md#46-disabled-on-this-build)). Confirm Postgres finished crash recovery, then decide whether a cable is worth it. If you *have* since wired the UPS up, then it's NUT not running or not answering — `upsc ups@localhost` should say `OL` (Stage 4).
- **A VM with an unexpected 19xx ID exists** → a restore drill that failed (kept for inspection) or ran with `--keep`; look, then `qm stop <id> && qm destroy <id>` ([`restore-drill`](scripts/README.md)).
- **No morning mail, ever, even when something's wrong** → root's mail isn't reaching you — the cron checks *and* backup/replication notifications all depend on it. Two separate halves fail here, so test both: the target's **Test** button proves SMTP, and `echo test | mail -s test root` proves the `system-mail` path the cron scripts actually use (Stage 15.3). A matcher narrowed to `vzdump`+`replication` silences every script in `scripts/` without looking broken.
- **A node lost quorum but never rebooted itself** → fencing isn't armed, and every automatic-recovery row in 18.3 is void until it is. `systemctl is-active watchdog-mux` on that node; if it's dead, or `softdog` was blacklisted/unloaded, or a second `watchdog` daemon is holding `/dev/watchdog`, that's the cause (Stage 15.4). Prove the fix with the isolation drill, not by reasoning about it.
- **An HA resource sits in `error` and won't start** → `max_restart` and `max_relocate` are both exhausted, which means it failed to start on *both* nodes — the disk image or the guest is the problem, not HA. Fix the cause, then `ha-manager set vm:<id> --state started` to clear it (Stage 15.1).
- **[`backup-verify`](scripts/README.md) says the WAL slot is inactive** → `pg-receivewal` on the QDevice is down — `systemctl status pg-receivewal` there; if it loops, it's `.pgpass`, `pg_hba`, or the network (Stage 13.3/13.5).
- **`pg_receivewal: password authentication failed for user "walreceiver"`, looping every 10s** → `.pgpass` on the QDevice disagrees with `postgres_wal_stream_password`. Fix the *file*, not the database: the role re-runs `ALTER ROLE … PASSWORD` on every playbook run, so Postgres always matches `vault.yml`. Usual cause is punctuation — `.pgpass` splits on `:` (escape as `\:`) and the role interpolates the value into SQL, so `'` breaks it too. Keep that secret alphanumeric (Stage 13.2).
- **`pg_stat_replication` returns 0 rows / `pg_receivewal: no pg_hba.conf entry for replication connection from host`** → 1022 doesn't trust the QDevice's address. `postgres_wal_stream_enabled` is false (the `pg_hba` block never rendered) or `postgres_wal_stream_cidr` still holds an old IP — the `/32` has to equal the QDevice's *current* address. Fix both in `group_vars/all/main.yml`, re-run `--limit postgres`, and expect a short Postgres restart: the template notifies a restart, not a reload (Stage 13.1/13.3).
- **`pg_wal` growing on 1022** → the WAL receiver has been down a while; the slot retains WAL up to `max_slot_wal_keep_size` (10GB), then breaks the stream instead of the disk. Fix the receiver, then drop + recreate the slot (Stage 13.5).
- **After a Postgres major, the WAL stream won't reconnect** → the QDevice's client is the old major; install the matching `postgresql-client-NN` (Stage 13.5 / 20.3).
- **No app logs in Grafana** → check in order: `alloy` active on 1021 (`systemctl status alloy`), the `[monitoring]` group exists in `hosts.ini` (Alloy auto-discovers 1023 from it — no group, no target), `loki_bind_address`/`grafana_bind_address` actually set to 1023's IP and not left on the loopback default (Stage 11.4/11.7).
- **`docker compose ps` on 1023 says `permission denied ... /var/run/docker.sock`** → `devops` is not in the `docker` group and deliberately stays out (that group is root-equivalent on the VM). Prefix every `docker` command there with `sudo` (Stage 11.6).
- **Grafana loads from the VM but not from my workstation** → `monitoring_allowed_cidr` unset or doesn't cover your subnet; the UFW rule on 1023 is what opens it beyond the VM itself (Stage 11.4).
- **Postgres (1022) logs don't show up in Grafana** → expected today, not a bug: Alloy only runs on the app host (Play 2); 1022's logs stay in the journal — `journalctl -u postgresql@18-main` (Stage 11.7).
- **`psql`/pgAdmin from my workstation to 1022 times out** → working as designed: `postgres_app_cidr` is the app VM's `/32`, so only 1021 gets through UFW/`pg_hba.conf`. Opt in with `postgres_extra_cidrs` and re-run the playbook (Stage 11.8).
- **Proxmox shows a VM at ~80% memory but nothing on it is working hard** → the summary panel counts page cache as used, and Linux fills free RAM with cache deliberately, reclaiming it the moment anything asks. The guest has the truth: `free -h` — read the **`available`** column, not `free` — plus `/proc/pressure/memory`. A non-zero PSI `full` average is real pressure; a large `buff/cache` is not. These guests run without swap, so `si`/`so` in `vmstat` stay at zero whatever happens and prove nothing on their own. A healthy 1021 sits near 800 MiB of its 8 GiB with ~6 GiB cached, which the panel reports as ~80%.
- **`systemctl enable` says "the unit files have no installation config"** → that unit is *static* — it's meant to be started by something else (a udev rule, a timer, a target), not enabled. Use `systemctl start`; `qemu-guest-agent` is the one you'll meet here, on the ISO template route (Stage 9.8d — the primary route injects it without ever running systemctl). Beware `enable --now` on a static unit: the enable fails first, so it never starts either.

## Runbook — the 10G link is down

Cable pulled, NIC dead, Thunderbolt adapter dropped off. **corosync takes care of itself** — Link 1 (`192.168.0.x`) picks up instantly and the cluster stays quorate, so `/etc/pve`, HA and quorum are untouched. Migration and replication do not: both read the migration network from `datacenter.cfg`, and [Stage 7](cluster/07-cluster.md) pins it to `10.10.10.0/24`. Everything below needs quorum, which you have — Link 1 plus the QDevice.

**1. Point migration and replication at the LAN.** Datacenter → Options → Migration Settings → Network `192.168.0.0/24`, or from a shell on either node:

```bash
pvesh set /cluster/options --migration type=secure,network=192.168.0.0/24
```

Applies immediately, no service restart, and only *new* migrations and replication runs pick it up. Keep `type=secure`: at 1G, SSH isn't the bottleneck, and this traffic now crosses a shared LAN instead of a private cable. (The property string replaces the whole line, which is why `type=` is repeated.) Clearing the Network field works too — the default is the address the node's own hostname resolves to, which is `192.168.0.x` anyway — but being explicit keeps the next person from wondering.

**2. Lower the bandwidth limit. This is the part that bites.** Stage 7 sets ~800 MB/s for a dedicated 10G link; 1G tops out around 118 MB/s, so that limit is now inert. Worse, the LAN is the *only* corosync ring left, and it already carries VM traffic plus the nightly offsite sync ([Stage 17](backup/17-backup-restore.md)) — saturating it means token jitter on the one remaining ring, and in the bad case a node fencing itself in the middle of a large replication.

```bash
pvesh set /cluster/options --bwlimit migration=60000    # KiB/s ≈ 60 MB/s
```

Leave roughly half the link free. Check the per-job rate limits in each VM's Replication panel too, and keep in mind the same string-replacement caveat if you already have `restore=`/`clone=` values set.

**3. Verify.**

```bash
cat /etc/pve/datacenter.cfg      # migration: type=secure,network=192.168.0.0/24
corosync-cfgtool -s              # LINK 0 faulty, LINK 1 status = OK
pvesr status                     # jobs return to OK on their next cycle
ha-manager status
```

Then run the [Stage 14](ha/14-live-migration.md) ping test. It works, about 10× slower: an 8 GiB guest moves in 2–3 minutes rather than ~20 seconds, and a write-heavy 1022 needs more dirty-page iterations to converge.

**Do not remove Link 0 from `corosync.conf`.** It stays configured, corosync marks it faulty, and it comes back by itself when the hardware does. Editing corosync while one ring is already down is how you lose the second one.

**Going back**, once the cable or NIC is replaced: `ping 10.10.10.x` → `corosync-cfgtool -s` with both links OK → *then* restore `network=10.10.10.0/24` and the 800 MB/s limit. In that order; repointing migration at a link you haven't proved is exactly the [16.2](operations/16-maintenance.md#162-returning-a-node-after-a-long-outage-days-to-weeks) mistake in miniature.

If the 10G hardware isn't coming back soon, a cheap USB 2.5G NIC at each end restores the direct link — and with it the second ring — without touching the design. corosync wants latency, not throughput.

### Optional — collapsing everything onto one network

If the 10G link isn't worth repairing and you'd rather run the whole cluster on `192.168.0.0/24`, this is the full sequence. Read the trade-off at the end before starting; it is not a small one. Do it with both nodes up and physical console access available.

**1. Migration and replication** — steps 1 and 2 above, kept permanently, lower bandwidth limit included.

**2. Back up the cluster config**, on both nodes:

```bash
cp /etc/pve/corosync.conf /root/corosync.conf.bak
cp /etc/corosync/corosync.conf /root/corosync.local.bak
```

[`pve-config-backup`](scripts/README.md) already covers these, but take the copy anyway — you're about to edit the one file that can lock you out of your own cluster.

**3. Rewrite corosync to a single link.** On **one** node only; `/etc/pve` propagates it. Proxmox's procedure is edit-a-copy-then-move, so a half-written file is never live:

```bash
cp /etc/pve/corosync.conf /etc/pve/corosync.conf.new
nano /etc/pve/corosync.conf.new
```

In each `node { }` block: set `ring0_addr` to that node's `192.168.0.x` and delete its `ring1_addr` line. In `totem { }`: delete the `interface { linknumber: 1 }` block. Then **increment `config_version`** — corosync ignores the file otherwise, and the symptom is nothing happening at all. Finally:

```bash
mv /etc/pve/corosync.conf.new /etc/pve/corosync.conf
```

corosync reloads on its own. Watch `journalctl -u corosync -f` on both nodes, then `pvecm status` (Quorate: Yes) and `corosync-cfgtool -s` — a single LINK 0, on `192.168.0.x`.

If it goes inquorate instead, on each node: `systemctl stop pve-cluster corosync`, then `pmxcfs -l` — local mode makes `/etc/pve` writable again — restore both backups, `systemctl start corosync pve-cluster`.

**4. Re-seat the QDevice.** Its membership is bound to the ring addresses you just changed, so remove and re-add rather than hoping:

```bash
pvecm qdevice remove
pvecm qdevice setup 192.168.0.10 -f
pvecm status        # Total votes: 3
```

**5. Clean up the 10G interface** — delete its stanza from `/etc/network/interfaces` on each node, `ifreload -a`, and confirm `ip route | grep default` is still exactly one line ([5.3](setup/05-network.md#53-verify)).

**6. Update the guide to match the cabling**: [5.2](setup/05-network.md#52-the-10g-direct-link), Stage 7's two links and migration network, and the two 10G rows in [18.3](ha/18-failover.md#183-scenario-table). A network description that no longer matches reality is worse than none, and this one gets read on the day something is on fire.

**What you give up.** Today a dead switch or router is survivable: the nodes still see each other over the direct cable, hold 2 of 3 votes, stay quorate, and the VMs keep running — you lose client access, nothing more ([18.3](ha/18-failover.md#183-scenario-table)). On a single network that same failure isolates both nodes *and* the QDevice from each other. Each node is left holding 1 vote of 3, both go inquorate, and both self-fence: one switch failure turns into a full cluster reset, and the VMs only come back when the switch does. You also give up the guarantee that corosync's ring never competes with a replication burst.

That is the price of the simpler diagram, and it's why the two-network design is the default here — the second ring is worth more than the 10 Gbit that happens to share the cable with it.

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
