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
cd ~/src/portable-dotnet-architecture/native/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
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

> **The keys people leave out of that list are the ones seeded outside Ansible** — a hypervisor's root key injected at VM creation, a key the OS installer imported. They don't read as "someone's identity", so they're forgotten, and then the first `exclusive: true` run deletes them from every host and takes the log-in-from-the-host recovery path with it. On the Proxmox build that's both nodes' `/root/.ssh/id_ed25519.pub` ([proxmox-homelab 21.6](../proxmox-homelab/operations/21-credentials.md#216-two-habits-that-make-key-loss-boring)). Before flipping the flag: `ansible all -m command -a 'cat ~/.ssh/authorized_keys' -b --become-user devops`, and reconcile against the list.

> **Credentials that must live outside this environment** (password manager, ideally plus a paper copy kept physically separate): your workstation's private key, the break-glass key, any hypervisor root key, every password in `vault.yml`, and the vault password itself if you encrypt the file. Recovery credentials must never exist only inside the thing they recover. `id_ed25519_devops` is the deliberate exception — generate it *on* the controller and leave it there: its recovery is a restore of that host or a re-issue pushed from the hypervisor, so it never needs a second copy ([proxmox-homelab 0.5](../proxmox-homelab/setup/00-preparation.md#05-keys--generate-all-of-them-now)). The role also pins SSH to key-only (`PasswordAuthentication no` drop-in), so a provider/console password can never open password auth over SSH.

## Configure

```bash
cd ~/src/portable-dotnet-architecture/native
# Edit inventory with your VPS IP:
vim infra/ansible/inventory/hosts.ini

# Edit app settings (name, domain, ports, .NET version…):
vim infra/ansible/inventory/group_vars/all/main.yml

# Fill in secrets:
cd ~/src/portable-dotnet-architecture/native/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
# required values:
# postgres_password: "replace-me"
# cloudflare_token: "replace-me"   # only when use_cloudflared: true
# grafana_admin_password: "replace-me"   # only when use_loki_grafana: true
# Optionally encrypt: ansible-vault encrypt inventory/group_vars/all/vault.yml
```

Key variables in `inventory/group_vars/all/main.yml`:

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
        Main: "Host=127.0.0.1;Port=5432;Database=myapp_db;Username={{ postgres_user }};Password={{ postgres_password }};Pooling=true"

  - name: anotherapp
    assembly: AnotherApp
    domain: anotherapp.example.com
    port_blue: 5010
    port_green: 5011
    repo_url: "https://github.com/your-org/anotherapp.git"
    project_path: "src/AnotherApp/AnotherApp.csproj"
    appsettings_override:
      ConnectionStrings:
        Main: "Host=127.0.0.1;Port=5432;Database=anotherapp_db;Username={{ postgres_user }};Password={{ postgres_password }};Pooling=true"
```

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

Bootstrap also performs the initial deploy automatically for each entry in `applications` where `repo_url` and `project_path` are configured. For private repositories, set `repo_token` (for that app) and store the secret in `vault.yml`.

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

**Subsequent deploys:**
```bash
sudo -u devops /opt/apps/myapp/scripts/deploy.sh
```

**Rollback** (switches Nginx back instantly):
```bash
sudo -u devops /opt/apps/myapp/scripts/rollback.sh
```

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
sleep drain_seconds
  ↓
systemctl stop <app>-<active>.service
```

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

Set `use_cloudflared: true` in `inventory/group_vars/all/main.yml` and provide `cloudflare_token` in `vault.yml`.
The tunnel is installed as a systemd service and starts automatically.
With a tunnel active, you can remove ports 80/443 from `ufw_allowed_tcp_ports`.

## Loki + Grafana (optional, Docker)

Set `use_loki_grafana: true` in `inventory/group_vars/all/main.yml` and provide `grafana_admin_password` in `vault.yml`.

Default behavior:

- Loki listens on `127.0.0.1:3100`
- Grafana listens on `127.0.0.1:3000`
- Data persists under `/opt/monitoring/loki/data` and `/opt/monitoring/grafana/data`
- Grafana Alloy is installed on app hosts and ships `/var/log/<app-name>/*.log` to Loki

Because the default bind address is loopback, services are not internet-exposed.
If you need remote access, prefer SSH tunneling or put Grafana behind your existing reverse proxy/tunnel setup.

When `monitoring_target: monitoring` is used, set `loki_bind_address: "0.0.0.0"` so app hosts can push logs.
The monitoring role allows TCP `loki_port` from hosts in the `[app]` inventory group.
