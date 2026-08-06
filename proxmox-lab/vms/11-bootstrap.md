# Stage 11 — First Ansible bootstrap (filling the VMs)

*Part of the [Proxmox lab guide](../README.md).*

Stages 9–10 produced four empty Ubuntu machines. Everything that makes them *useful* — Postgres + PostGIS, the .NET app with blue/green deploys, nginx, `cloudflared`, the nightly database dump, Loki + Grafana, SSH key management — is installed by the Ansible project in [`native/infra/ansible`](../../native/infra/ansible), run from control-ubuntu (1020). This stage is that first run.

It sits **before replication (Stage 12) on purpose**: finish the machines first, then wire redundancy around them. Replicating, HA-protecting and failover-testing VMs that don't run anything yet just means doing parts of Stages 12–18 twice.

The authoritative command-by-command walkthrough is [`native/example`](../../native/example) — a copy-paste file covering the control node, `vault.yml`, `main.yml`, inventory and the playbook run. **Follow it from the `on control vm:` section onward**, with the lab-specific differences below. Don't skim past them; two of these (the split-VM database variables) produce a broken app if left at their single-VM defaults.

## 11.1 What's different here vs `native/example`

| Topic | `native/example` (single VPS) | This lab |
|---|---|---|
| Topology | app + postgres on one VM | app = **1021** (.21), postgres = **1022** (.22), monitoring = **1023** (.23) |
| `hosts.ini` | one `[app]` host | `[app]`, `[postgres]` and `[monitoring]` groups — see 11.3 |
| `postgres_host` | `127.0.0.1` | **`192.168.0.22`** — the app's connection strings point here |
| `postgres_app_cidr` | empty (loopback only) | **`192.168.0.21/32`** — lets 1021 reach Postgres; the role writes it into `pg_hba.conf` and the firewall |
| `use_cloudflared` | `false` | `true` + `cloudflare_token` in `vault.yml` — the tunnel lives inside 1021 ([why](cloudflare-tunnel.md)) |
| `use_loki_grafana` / `monitoring_target` | `false` / — | `true` / **`monitoring`** — Loki + Grafana run on dedicated 1023 instead of alongside the app, see 11.7 |
| `grow_root_filesystem` | `true` (LVM layout, the role grows it) | **`false`** — cloud-image clones have no LVM; cloud-init already grew each root at first boot ([Stage 10](10-vms.md#grow-the-disk--per-vm)), and the role's LVM chain has nothing to act on |
| sudoers / `growpart` prep steps | needed (hand-installed VM) | **skip** — cloud-init created `devops` with passwordless sudo and grew the disks at first boot; nothing to prepare by hand |
| SSH keys | generated in the walkthrough, seeded with `ssh-copy-id` | already done in [Stage 10](10-vms.md#ssh-keys--control-ubuntu--the-other-three) — the `devops` pair from [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now), installed as `~/.ssh/id_ed25519_devops`. `ssh-copy-id` doesn't apply here: the cloud image has no password auth to bootstrap through, so every VM was born trusting the key via `vm_keys.pub` instead |

## 11.2 On control-ubuntu (1020)

Ansible and the SSH key exist since Stage 9. Clone the repo:

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/florin-rotaru-md/portable-dotnet-architecture
```

## 11.3 Inventory — the lab addresses

```bash
cat << 'EOF' > ~/src/portable-dotnet-architecture/native/infra/ansible/inventory/hosts.ini
[app]
192.168.0.21 ansible_user=devops ansible_private_key_file=~/.ssh/id_ed25519_devops

[postgres]
192.168.0.22 ansible_user=devops ansible_private_key_file=~/.ssh/id_ed25519_devops

[monitoring]
192.168.0.23 ansible_user=devops ansible_private_key_file=~/.ssh/id_ed25519_devops
EOF
```

The `[monitoring]` group is what turns on [Play 3](../../native/infra/ansible/playbooks/bootstrap.yml) — an empty or missing group makes that play match zero hosts and no-op, which is how `use_loki_grafana: false` behaves everywhere else in this repo. Defining it here is what makes 1023 real.

Sanity check before anything else — all three VMs reachable, passwordless sudo working:

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible all -m ping
ansible all -b -m command -a whoami        # expect: root, three times
```

> If the `-b` check prompts for a password, cloud-init didn't grant `devops` passwordless sudo on that clone. Fix it once, over SSH: `echo 'devops ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/devops && sudo chmod 440 /etc/sudoers.d/devops`.

## 11.4 `vault.yml` and `main.yml`

Create both exactly as `native/example` shows, then apply the lab deltas from the 11.1 table — in `main.yml`:

```yaml
postgres_host: "192.168.0.22"
postgres_app_cidr: "192.168.0.21/32"

# Optional — direct Postgres access from your workstation/LAN (pgAdmin, psql):
# see 11.8 before enabling.
# postgres_extra_cidrs: ["192.168.0.0/24"]

use_cloudflared: true

# Cloud-image clones (Stage 9): root on a plain partition, grown by cloud-init
# at every boot — the role's LVM growth chain would find nothing to grow.
# Set true only for the ISO-alternative template (9.8g).
grow_root_filesystem: false

# ── Loki + Grafana on the dedicated monitoring VM (1023) ──────────────────────
use_loki_grafana: true
monitoring_target: monitoring
loki_bind_address: "192.168.0.23"          # default is loopback-only — wrong for a split VM
grafana_bind_address: "192.168.0.23"       # same reason
monitoring_allowed_cidr: "192.168.0.0/24"  # who may reach Grafana through UFW
```

and in `vault.yml`, alongside the keys and `postgres_password`:

```yaml
cloudflare_token: "eyJhIjoi..."               # the tunnel token for the app
grafana_admin_password: "<strong password>"   # min. 12 chars — the role asserts on this
```

Two rules worth internalizing now, because they outlive this stage:

- **`vault.yml` is never committed** (it's gitignored); `postgres_password` and every token live only there and in the password manager — see the credential inventory in [Stage 21.1](../operations/21-credentials.md#211-inventory--what-exists-and-where-it-lives).
- **Any `group_vars` change you make here must be mirrored** into the example files (`native/example` and the hyper-v/docker counterparts) — they are full copies meant to stay in sync, per the [repo rule](../README.md#relationship-to-the-rest-of-the-repo).

## 11.5 Run it

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible-playbook playbooks/bootstrap.yml --diff
```

The first run takes a while: PGDG + PostGIS on 1022, the .NET SDK on 1021, Docker + Loki + Grafana on 1023, and — because `repo_url`/`project_path` are set — the **first application deploy**, straight into the blue slot. All three plays run from this one invocation; there's no separate command for the monitoring VM. `--diff` shows every file it writes; on a fresh VM that's a lot of output, and that's fine. (Don't use `--check` with this role set — [Stage 20.3 step 4](../operations/20-upgrades.md#step-4-bump-the-variable-run-the-playbook) explains why it breaks.)

Re-running it later is always safe — that's the point of it being the single owner of in-VM state.

One thing the run did without being asked: the postgres role rendered `/etc/postgresql/18/main/conf.d/10-tuning.conf` from the VM's RAM — 32 GiB → `shared_buffers = 8GB`, `effective_cache_size = 24GB`, `work_mem = 32MB` — plus `max_connections = 128`, sized from the per-app Npgsql pool budget rather than from memory. When 1022 later grows to 64 GiB (the planned upgrade alongside apps three and four), this same re-run *is* the whole tuning procedure: the sizes step up to 16GB / 48GB / 64MB on their own, and only `max_connections` deliberately stays put.

## 11.6 Verify before moving on

```bash
# Postgres up, PostGIS present, dump script installed (on 1022)
ssh devops@192.168.0.22 'systemctl is-active postgresql && ls -l /opt/postgres/scripts/pg-backup.sh'
ssh devops@192.168.0.22 'sudo -u postgres psql -tAc "select version(), postgis_version()"'

# Tuning followed the VM's RAM (conf.d/10-tuning.conf): 32 GiB → expect 8GB
ssh devops@192.168.0.22 'sudo -u postgres psql -tAc "show shared_buffers"'

# App slot up and healthy, nginx routing it (on 1021)
ssh devops@192.168.0.21 '/opt/apps/api.example.com/scripts/current-slot.sh'
curl -s -H "Host: api.example.com" http://192.168.0.21/.well-known/ready    # expect HTTP 200

# Tunnel up (on 1021), then the real test: the public URL in a browser
ssh devops@192.168.0.21 'systemctl is-active cloudflared'

# Loki + Grafana up (on 1023), and app logs already arriving
ssh devops@192.168.0.23 'cd /opt/monitoring && sudo docker compose ps'
ssh devops@192.168.0.21 'systemctl is-active alloy'
curl -s 'http://192.168.0.23:3100/loki/api/v1/label/service/values'
# expect {"status":"success","data":["api.example.com"]} — one entry per app in `applications[]`
```

**Every `docker` command on 1023 needs `sudo`** — this one, and any later `logs`/`restart` you run by hand. The playbook installs Docker and runs `docker compose up -d` as root, and nothing adds `devops` to the `docker` group: that group is root-equivalent on the machine (a container can mount `/`), which is a poor trade for saving four characters on a VM you visit to read logs. Without it you get `permission denied while trying to connect to the Docker daemon socket`.

All green → the machines are done. From here on, **change VM state via the playbook, not by hand** ([the ownership boundary, 20.5](../operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere)) — and continue with [Stage 12](../ha/12-replication.md), which replicates disks that now hold their real content.

## 11.7 The monitoring VM (1023) — Loki + Grafana

The Ansible side of this needed no new code: `monitoring` and `alloy` are existing, generic roles ([`roles/monitoring`](../../native/infra/ansible/roles/monitoring), [`roles/alloy`](../../native/infra/ansible/roles/alloy)) that already support exactly this split — a dedicated log-collection VM instead of running Loki alongside the app. Everything in 11.3/11.4 above is the lab-specific wiring; this section is what that wiring buys you and what it doesn't, yet.

**What happens automatically, from the one playbook run in 11.5:**

- 1023 gets Docker, Loki and Grafana (Play 3), bound to its own LAN IP so 1021 can reach it and your workstation can reach Grafana — the `monitoring_allowed_cidr` UFW rule is what makes the second part true; without it Grafana listens but nothing outside the VM can connect.
- 1021's Alloy config **auto-discovers** 1023: `config.alloy.j2` reads `groups['monitoring'][0]`'s address at render time, so defining the `[monitoring]` group in `hosts.ini` is the only wiring the app side needs. You do not set `alloy_loki_url` by hand — that variable exists only to *override* the discovery, for cases this lab doesn't have.
- Grafana ships with the Loki datasource pre-provisioned (`grafana-datasource-loki.yml.j2`) — open `http://192.168.0.23:3000`, log in as `admin` / the `grafana_admin_password` from vault, and the app's logs are already queryable under `{service="api.example.com"}` (or whatever `domain` you set per app in `applications[]`).

**What does *not* ship logs yet, and why that's a deliberate stop here rather than an oversight:** Play 1 (postgres) runs only `common` + `postgres` — the `alloy` role isn't in that play, so 1022's Postgres logs stay local (`journalctl -u postgresql@{{ postgres_version }}-main`) and don't reach Grafana. Wiring that up means teaching Alloy to scrape journald instead of files (Postgres on Ubuntu logs to the journal, not a file, unless `logging_collector` is turned on) — a real change to a role shared by every setup in this repo, not a lab-only tweak. Doing it well is worth its own change, reviewed on its own; bolting it on here to make 1023's job description technically complete would be exactly the kind of half-finished feature this guide tries to avoid. Until then, `journalctl` on 1022 (and `cluster-health`'s existing checks) remain how you look at database-side problems.

**Why 1023 stays out of HA:** see [Stage 15.1](../ha/15-ha.md#151-which-vms-get-ha). Short version — it's an observability tool, not something users depend on; losing dashboards for the few minutes a manual restart takes is a cost worth paying for one less moving part during an actual incident.

## 11.8 Optional — reaching Postgres from the rest of the LAN

The default above is deliberately tight: `postgres_app_cidr: "192.168.0.21/32"` means **only the app VM** can open a TCP connection to 1022. Your workstation can't — `psql`, pgAdmin or DBeaver pointed at `192.168.0.22` just time out on the firewall. That's the right default: the app needs nothing more, and a database reachable by every device on the LAN (phones, TVs, IoT) is added attack surface with no operational gain.

When you *do* want direct access from your desk — a GUI client, ad-hoc queries, inspecting what the app actually wrote — opt in with `postgres_extra_cidrs` in `main.yml`:

```yaml
postgres_extra_cidrs: ["192.168.0.0/24"]      # the whole LAN…
# postgres_extra_cidrs: ["192.168.0.50/32"]   # …or, tighter: just your workstation
```

then re-run the playbook (11.5). For each listed CIDR the postgres role adds a `pg_hba.conf` entry and a UFW allow for 5432/tcp — the same two things it already does for the app's `/32`. If your workstation has a stable address (DHCP reservation, [Stage 5](../setup/05-network.md)), prefer the `/32` form; the `/24` is the convenient-but-broad variant.

What this does **not** change:

- **Authentication.** Every TCP connection still authenticates with `scram-sha-256` — opening the network is useless without the `postgres_password` from `vault.yml`. Nobody connects just by being on the LAN.
- **Public exposure.** 5432 stays behind your router; the Cloudflare tunnel ([why it's app-only](cloudflare-tunnel.md)) publishes HTTP for the app, never the database.

Verify from your workstation (password: `postgres_password` from `vault.yml`):

```bash
psql "host=192.168.0.22 user=postgres dbname=postgres" -c 'select version()'
```

Tightening back later: remove the entry and re-run — the `pg_hba.conf` line disappears (the template owns the whole file), so Postgres refuses the connections again. The UFW rule however is only ever *added*; delete it by hand on 1022 (`sudo ufw status numbered`, then `sudo ufw delete <n>`). Until you do, the leftover rule is cosmetic — the port is open but Postgres rejects anything not in `pg_hba.conf`.
