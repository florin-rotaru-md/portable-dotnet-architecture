# Setup 1 — Native .NET multi-app on a VPS

Single Ubuntu VPS. Applications are compiled and run directly as systemd services.
Blue/green deployment via source build (`dotnet publish`) and Nginx upstream swap.
Optionally, Loki + Grafana can run in Docker for logs and dashboards.

## What gets installed

| Component  | Method           |
|------------|------------------|
| .NET SDK   | Microsoft apt    |
| PostgreSQL | PGDG apt         |
| Nginx      | Ubuntu apt       |
| Docker     | Ubuntu apt *(only when Loki/Grafana is enabled)* |
| Loki       | Docker container *(optional)* |
| Grafana    | Docker container *(optional)* |
| cloudflared| Cloudflare apt *(optional)* |
| Chrome + fonts | Google apt *(optional — `use_headless_browser: true`)* |

### Headless browser

Applications that render HTML to PNG or PDF (PuppeteerSharp, Playwright) need a browser on the
host; nothing is downloaded at runtime. Set `use_headless_browser: true`, and `headless_browser:
true` on the application entry so its service gets a writable `HOME` for the browser profile —
`ProtectSystem=strict` leaves the service user's real home read-only. The binary lands at
`/usr/bin/google-chrome-stable`; point the app's configuration at that path
(.NET/PuppeteerSharp: `Render:BrowserExecutablePath`).

Google's `.deb` is used rather than Ubuntu's `chromium` package, which is a snap shim that cannot
be launched from a hardened systemd unit. The role smoke-tests the browser during provisioning, so
that failure surfaces in the playbook run rather than on a customer's first download.

## Minimal bootstrap commands

```bash
# 1. On the VPS (or your laptop targeting the VPS):
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl python3 python3-pip python3-venv pipx openssh-client
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
pipx ensurepath && pipx install --include-deps ansible

# 2. Clone this repo
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/portable-dotnet-architecture.git
cd ~/src/portable-dotnet-architecture/native
```

## *(Optional)* Ansible service account — SSH key setup

The `common` role creates a dedicated `devops` user on the VPS with passwordless sudo.
All playbook runs connect as this user after the initial bootstrap.

**1. Generate a key pair on your control machine** (skip if you already have one):

Linux / WSL / macOS:
```bash
test -f ~/.ssh/id_ed25519_devops || \
  ssh-keygen -t ed25519 -C "devops" -f ~/.ssh/id_ed25519_devops -N ""
```

Windows (PowerShell — OpenSSH built-in, Windows 10 1809+):
```powershell
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519_devops")) {
  ssh-keygen -t ed25519 -C "devops" -f "$env:USERPROFILE/.ssh/id_ed25519_devops" -N '""'
}
```

**Backup the key** (once, after generation — store in a password manager, encrypted USB, or vault):
```bash
cp ~/.ssh/id_ed25519_devops     ~/id_ed25519_devops.bak
cp ~/.ssh/id_ed25519_devops.pub ~/id_ed25519_devops.pub.bak
```

**Restore on a new / recovered control VM** (reusing the key avoids re-running `ssh-copy-id` on every target):
```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp id_ed25519_devops     ~/.ssh/id_ed25519_devops
cp id_ed25519_devops.pub ~/.ssh/id_ed25519_devops.pub
chmod 600 ~/.ssh/id_ed25519_devops
chmod 644 ~/.ssh/id_ed25519_devops.pub
```

**Copy the public key to the target VPS** (so Ansible can connect):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub root@<vps-ip>
```

**2. Add the public key to `vault.yml`** (see Configure below):

```bash
mkdir -p ~/app-inventory/group_vars/all
cp --update=none \
  ~/src/portable-dotnet-architecture/native/infra/ansible/inventory/group_vars/all/vault.yml.example \
  ~/app-inventory/group_vars/all/vault.yml
vim ~/app-inventory/group_vars/all/vault.yml
```

```yaml
ansible_ssh_public_key: "ssh-ed25519 AAAA...  control-ubuntu"
# or use an Ansible lookup ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_devops.pub') }}"
```

**3. More than one key, and rotation.** One key is a single point of failure — the `common` role manages `authorized_keys` declaratively and takes a list:

```yaml
# vault.yml — optional additional keys (workstation, break-glass kept offline)
ansible_ssh_extra_public_keys:
  - "ssh-ed25519 AAAA... workstation"
  - "ssh-ed25519 AAAA... break-glass"
  - "ssh-ed25519 AAAA... pve1-root"        # if a hypervisor seeded a key — see below
  - "ssh-ed25519 AAAA... pve2-root"
```

Once every key you rely on is listed, set `ssh_authorized_keys_exclusive: true` in `main.yml`: keys **not** in the list are removed on the next run, so rotating a compromised key is *delete the line, run the playbook* — across every host at once. Don't edit `~/.ssh/authorized_keys` by hand; the next run reconciles it.

> **The keys people leave out of that list are the ones seeded outside Ansible** — a hypervisor's root key injected at VM creation, a key the OS installer imported. They don't read as "someone's identity", so they're forgotten, and then the first `exclusive: true` run deletes them from every host and takes the log-in-from-the-host recovery path with it. On the Proxmox build that's both nodes' `/root/.ssh/id_ed25519.pub` ([proxmox-lab 21.6](../proxmox-lab/operations/21-credentials.md#216-two-habits-that-make-key-loss-boring)). Before flipping the flag: `ansible all -m command -a 'cat ~/.ssh/authorized_keys' -b --become-user devops`, and reconcile against the list.

> **Credentials that must live outside this environment** (password manager, ideally plus a paper copy kept physically separate): your workstation's private key, the break-glass key, any hypervisor root key, every password in `vault.yml`, and the vault password itself if you encrypt the file. Recovery credentials must never exist only inside the thing they recover. `id_ed25519_devops` is the deliberate exception — generate it *on* the controller and leave it there: its recovery is a restore of that host or a re-issue pushed from the hypervisor, so it never needs a second copy ([proxmox-lab 0.5](../proxmox-lab/setup/00-preparation.md#05-keys--generate-all-of-them-now)). The role also pins SSH to key-only (`PasswordAuthentication no` drop-in), so a provider/console password can never open password auth over SSH.

## Configure

**Keep your inventory outside the clone.** Nothing in `inventory/` is committed except the three
`.example` files — copy them somewhere of your own and point Ansible at that directory. Ansible
resolves `group_vars/` relative to the inventory file, so the layout is the only thing that has to
match:

```bash
mkdir -p ~/app-inventory/group_vars/all
cd ~/src/portable-dotnet-architecture/native/infra/ansible
cp inventory/hosts.ini.example                    ~/app-inventory/hosts.ini
cp inventory/group_vars/all/main.yml.example      ~/app-inventory/group_vars/all/main.yml
cp inventory/group_vars/all/vault.yml.example     ~/app-inventory/group_vars/all/vault.yml

# Point every ansible command at it, once
echo 'export ANSIBLE_INVENTORY=~/app-inventory/hosts.ini' >> ~/.bashrc && . ~/.bashrc
#   ...or pass -i ~/app-inventory/hosts.ini per command.
```

Keeping it out of the clone is what makes `git pull --ff-only` on a control node boring: an
inventory that lives on a tracked path is a modified working tree for ever, so every pull is a
conflict against your own edits — and the reflex that clears it (`git checkout -- .`) deletes the
description of your hosts. The paths are also in `.gitignore`, so an inventory left inside the
clone cannot be committed by accident; that layout still works, it just gives up the clean pull.

Then fill in the three files:

```bash
vim ~/app-inventory/hosts.ini                   # your VPS IPs
vim ~/app-inventory/group_vars/all/main.yml     # apps: name, domain, ports, .NET version…
vim ~/app-inventory/group_vars/all/vault.yml    # secrets
# required values:
# postgres_password: "replace-me"
# cloudflare_token: "replace-me"         # only when use_cloudflared: true
# grafana_admin_password: "replace-me"   # only when use_loki_grafana: true
# Optionally encrypt: ansible-vault encrypt ~/app-inventory/group_vars/all/vault.yml
```

`main.yml.example` is the reference copy — every variable, commented, including the ones left off
by default. Diff your file against it after a pull to see what a new version added:

```bash
diff -u ~/app-inventory/group_vars/all/main.yml \
        infra/ansible/inventory/group_vars/all/main.yml.example
```

Key variables in `group_vars/all/main.yml`:

| Variable                  | Description                                 
|---------------------------|---------------------------------------------
| `applications`            | List of native apps (required)
| `name`                    | App identifier (systemd/nginx/runtime paths)
| `assembly`                | .NET assembly name (DLL without extension)
| `domain`                  | Nginx `server_name`
| `port_blue`               | Port for blue slot
| `port_green`              | Port for green slot
| `drain_seconds`           | Nginx drain before stopping old slot
| `log_dir_name`            | Optional log folder name under `/var/log` (default: app `name`)
| `repo_url`                | Git repo URL used for initial deploy
| `project_path`            | Path to the `.csproj` used for first deploy
| `appsettings_override`    | Per-app `appsettings.override.json` merge values
| `app_log_root`            | Root folder for app logs (default `/var/log`)
| `use_cloudflared`         | `true` to install Cloudflare Tunnel
| `use_loki_grafana`        | `true` to install Dockerized Loki + Grafana
| `monitoring_target`       | `app` (default) or `monitoring` (`[monitoring]` host group)
| `monitoring_bind_address` | Bind IP for Loki/Grafana ports (`127.0.0.1` by default)
| `loki_bind_address`       | Loki bind IP (set `0.0.0.0` when target is dedicated `monitoring`)
| `grafana_port`            | Host port for Grafana (default `3000`)
| `loki_port`               | Host port for Loki API (default `3100`)
| `alloy_http_port`         | Alloy HTTP server port, bound to loopback (default `12345`)
| `alloy_logs_root`         | Root searched by Alloy (default follows `app_log_root`)
| `alloy_log_glob`          | Log filename glob matched by Alloy (default `*.log`)
| `alloy_loki_url`          | Optional explicit Loki push endpoint override

`applications` example:

```yaml
applications:
  - name: myapp
    assembly: MyApp
    domain: myapp.example.com
    port_blue: 5000
    port_green: 5001
    drain_seconds: 30
    repo_url: "https://github.com/your-org/myapp.git"
    repo_branch: "master"
    project_path: "src/MyApp/MyApp.csproj"
    appsettings_override:
      ConnectionStrings:
        Main: "Host=127.0.0.1;Port=5432;Database=myapp_db;Username={{ postgres_user }};Password={{ postgres_password }};Pooling=true;Keepalive=60;Maximum Pool Size=64;Timeout=5;Command Timeout=30;Connection Idle Lifetime=60"

  - name: anotherapp
    assembly: AnotherApp
    domain: anotherapp.example.com
    port_blue: 5010
    port_green: 5011
    repo_url: "https://github.com/your-org/anotherapp.git"
    project_path: "src/AnotherApp/AnotherApp.csproj"
    appsettings_override:
      ConnectionStrings:
        Main: "Host=127.0.0.1;Port=5432;Database=anotherapp_db;Username={{ postgres_user }};Password={{ postgres_password }};Pooling=true;Keepalive=60;Maximum Pool Size=16;Timeout=5;Command Timeout=30;Connection Idle Lifetime=60"
```

> Npgsql keeps one pool per unique connection string. `Maximum Pool Size` caps each
> pool, and the window that sizes the server is a deploy, not rush hour: for the
> length of `drain_seconds` both slots hold their own pools, so the budget doubles.
> Server-side, the postgres role matches this with `postgres_max_connections` and
> renders `conf.d/10-tuning.conf` from the host's RAM (shared_buffers 25%,
> effective_cache_size 75%, tiered work_mem) — a RAM upgrade plus a playbook re-run
> re-tunes everything, and deliberately leaves the connection ceiling alone; see the
> tuning block in `group_vars/all/main.yml`. `Keepalive=60` lets each pool detect and
> evict connections killed by a Postgres restart (auto minor upgrades, failover)
> before requests trip over them; `Timeout=5`, `Command Timeout=30` and
> `Connection Idle Lifetime=60` replace three defaults that bite under load — see
> [`perf/README.md`](../perf/README.md#connection-string-settings-worth-fixing-first).

**3. First bootstrap** — the `devops` user doesn't exist yet, so connect as the initial root/admin user:

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml -u root --ask-pass --ask-vault-pass
```

> If the VPS was provisioned with your SSH key for root already, omit `--ask-pass`.

**4. All subsequent runs** — `ansible.cfg` and `group_vars` set `ansible_user: devops` automatically:

```bash
ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

## Bootstrap

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml
# With vault: ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

The full run is right the first time and after adding an app. For everything after that, scope it
to what you changed — see [Applying a change](#applying-a-change).

Bootstrap also performs the initial deploy automatically for each entry in `applications` where `repo_url` and `project_path` are configured. For private repositories, set `repo_token` (for that app) and store the secret in `vault.yml` — use a fine-grained PAT scoped to the deployed repositories with *Contents: Read-only*. Bootstrap also renders that token to `/opt/apps/<app>/config/repo-token` (mode 0600, owned by the app user), which is what lets every later deploy run without retyping it.

Database creation is not performed by Ansible. Applications are expected to create/update their own schemas through migrations at startup or deploy time.
PostGIS is enabled on `template1`, so newly created databases inherit the extension.

## Deploy

After bootstrap, each app has its own deploy script at `/opt/apps/<app_name>/scripts/deploy.sh`.

**First deploy** is performed automatically by bootstrap when the repository variables are configured.

**Manual first deploy** (only needed if you intentionally leave those variables empty):
```bash
sudo -u devops /opt/apps/myapp/scripts/deploy.sh \
  --repo-url     "https://github.com/your-org/your-repo.git" \
  --branch       "master" \
  --token        "ghp_xxx"   # omit for public repos \
  --project-path "src/MyApp/MyApp.csproj"
```

**Subsequent deploys — on the VM**, nothing to type: the token resolves as `--token` → `APP_REPO_TOKEN` → `/opt/apps/<app>/config/repo-token` (rendered from `vault.yml` by the playbook):
```bash
sudo -u devops /opt/apps/myapp/scripts/deploy.sh
```

**Subsequent deploys — from the control node**, token straight from `vault.yml`:
```bash
cd infra/ansible
ansible-playbook playbooks/deploy.yml -e app=myapp    # one app
ansible-playbook playbooks/deploy.yml                 # every repo-based app
# encrypted vault: add --ask-vault-pass
```

**Token rotation:** change `app_repo_token` in `vault.yml`, then `ansible-playbook playbooks/bootstrap.yml --limit app` — the per-app `config/repo-token` files are re-rendered (and removed for apps whose `repo_token` is unset).

**Rollback** (switches Nginx back instantly):
```bash
sudo -u devops /opt/apps/myapp/scripts/rollback.sh
```

## Applying a change

There are two channels and they are not interchangeable. **`bootstrap.yml` applies changes to the
host** — this repository's roles, and your inventory. **`deploy.yml` applies changes to the
application** — a new commit in the app's own repository, built into the idle slot. A change to
`appsettings_override` or an env var is the first; a change to a `.cs` file is the second. When a
release needs both, run bootstrap first: it is the one that can fix a host that is currently down.

```bash
cd ~/src/portable-dotnet-architecture
git pull --ff-only

# 1. Read what arrived. The step everyone skips, and the only one that tells you the blast radius.
git diff HEAD@{1}..HEAD --stat -- native/infra
git log  HEAD@{1}..HEAD --oneline -- native/infra

cd native/infra/ansible
ansible-playbook playbooks/bootstrap.yml --syntax-check

# 2. Dry run. --diff prints the new content of every file that would change; the two tasks that
#    write secrets are no_log, so those report "changed" without showing it.
ansible-playbook playbooks/bootstrap.yml --check --diff --limit app --tags app

# 3. For real, one host group at a time.
ansible-playbook playbooks/bootstrap.yml --limit app --tags app

# 4. Verify on the host, not in Ansible's output.
ssh devops@<app-vm> 'systemctl is-active myapp-$(cat /opt/apps/myapp/runtime/active-slot)'
curl -fsS https://myapp.example.com/.well-known/ready
```

Add `--ask-vault-pass` throughout if `vault.yml` is encrypted.

**Scope the run to what changed.** `--limit` picks hosts, `--tags` picks roles; `--list-tags`
prints what is available:

| Change | Run |
|---|---|
| App definition, `appsettings_override`, `env` | `--limit app --tags app` |
| A slot port (`port_blue`/`port_green`) | `--limit app --tags app,nginx` |
| Domain, TLS, Nginx site config | `--limit app --tags nginx` |
| Postgres tuning, `pg_hba`, backups | `--tags postgres` |
| Loki/Grafana/Alloy | `--tags logging` |
| SSH keys, firewall, unattended upgrades | `--tags common` |
| A new app added to `applications` | full run, no `--tags` |

The pre-tasks are tagged `always`, so a tagged run still validates the inventory. The initial
deploy at the end of the play is tagged `initial-deploy` and is skipped by any `--tags` selection
that does not name it — it is a no-op on a host that has deployed before, but a tagged run is what
you reach for during an incident and it should not build anything.

**Why `--tags postgres` is worth the discipline:** the postgres role installs with `state: latest`,
so a full run can pick up a minor release and restart the cluster. Every app on the host drops its
connections while it does. A change to the app role has no business touching the database VM.

**A changed env file restarts the active slot.** `common.env`, `blue.env`, `green.env` and
`appsettings.override.json` are generated in full from the inventory and rewritten on every run
(`force: true`), and the app role restarts the live slot when any of them actually changes — systemd
reads `EnvironmentFile` only at start, so nothing else would apply it. That restart is a real one,
not a blue/green swap: a few seconds of downtime for that app. It fires only on a genuine content
change, which is why the dry run in step 2 is the thing to read — with `check_mode: false` on the two
read-only probes, `--check` reports the restart it would perform.

The corollary: **hand-edits to those files on the host do not survive a run.** An env var belongs in
`applications[].env` in your inventory, a setting in `appsettings_override`. Only runtime state
(`runtime/active-slot`, `runtime/active-image`, the active Nginx upstream) is written once and left
alone — those belong to `deploy.sh` and `switch-nginx.sh`, not to the inventory.

**Rolling back an infrastructure change** is `git revert` plus another run — the roles are
declarative, so the previous commit puts the host back. `rollback.sh` is a different thing: it
switches Nginx to the other slot and is about application code.

## Deployment sequence

```
clone/pull repo
  ↓
dotnet publish → idle slot dir
  ↓
systemctl start <app>-<idle>.service
  ↓
poll /.well-known/ready (max 90s)
  ↓
cp upstream-<idle>.conf → nginx conf.d
nginx -t && systemctl reload nginx
  ↓
systemctl enable  <app>-<idle>.service     # the one now serving may start at boot
  ↓
sleep drain_seconds
  ↓
systemctl stop    <app>-<active>.service
systemctl disable <app>-<active>.service   # the one drained may not
```

**Exactly one slot per app is enabled, and `deploy.sh` owns which.** Ansible registers both units and
deliberately declares no enablement: which slot may start at boot is a property of which one is live,
and only the deploy knows that. Both used to be enabled, so rebooting the host started *both* slots of
*every* app — two different builds draining the same queues and holding two pools against a budget the
blue/green overlap already strains. Nothing failed; it ran twice, quietly.

Two consequences worth knowing:

- A freshly provisioned host has **neither** slot enabled until its first deploy. That is correct —
  there is nothing published to serve.
- A host that predates this change still has both enabled. The state converges after one deploy per
  app; until then, `systemctl is-enabled <app>-{blue,green}` is the check, and disabling the idle one
  by hand is safe.

## Directory layout on VPS

```
/opt/apps/<app>/
  slots/
    blue/       ← dotnet publish output for blue
    green/      ← dotnet publish output for green
  build/        ← git clone lives here
  env/
    common.env  ← shared runtime env (DOTNET_ENVIRONMENT, APP_NAME, custom vars)
    blue.env    ← SLOT_NAME + ASPNETCORE_URLS for blue
    green.env   ← SLOT_NAME + ASPNETCORE_URLS for green
  config/
    appsettings.override.json  ← rendered from appsettings_override and copied on deploy
  nginx/
    upstream-blue.conf
    upstream-green.conf
  runtime/
    active-slot         ← current live slot name
    deploy-history.log
  scripts/
    deploy.sh
    rollback.sh
    health-check.sh
    switch-nginx.sh
    current-slot.sh
```

## Cloudflare Tunnel (optional)

Set `use_cloudflared: true` in `group_vars/all/main.yml` and provide `cloudflare_token` in `vault.yml`.
The tunnel is installed as a systemd service and starts automatically.
With a tunnel active, you can remove ports 80/443 from `ufw_allowed_tcp_ports`.

## Loki + Grafana (optional, Docker)

Set `use_loki_grafana: true` in `group_vars/all/main.yml` and provide `grafana_admin_password` in `vault.yml`.

Default behavior:

- Loki listens on `127.0.0.1:3100`
- Grafana listens on `127.0.0.1:3000`
- Data persists under `/opt/monitoring/loki/data` and `/opt/monitoring/grafana/data`
- Grafana Alloy is installed on app hosts and ships `/var/log/<app-name>/*.log` to Loki

Because the default bind address is loopback, services are not internet-exposed.
If you need remote access, prefer SSH tunneling or put Grafana behind your existing reverse proxy/tunnel setup.

When `monitoring_target: monitoring` is used, set `loki_bind_address: "0.0.0.0"` so app hosts can push logs.
The monitoring role allows TCP `loki_port` from hosts in the `[app]` inventory group.
