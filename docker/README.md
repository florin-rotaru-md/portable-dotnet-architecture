# Setup 2 — Docker Compose, multi-app VPS

Single Ubuntu VPS. Multiple apps each running as two Docker containers (blue/green).
Postgres runs as a Docker container on the same host with a named volume for persistence.

## What gets installed

| Component   | Method                     |
|-------------|----------------------------|
| Docker      | Ubuntu apt (`docker.io`)   |
| Nginx       | Ubuntu apt                 |
| Postgres    | Docker container           |
| cloudflared | Cloudflare apt *(optional)*|

## Minimal bootstrap commands

```bash
# 1. On your laptop / control machine:
sudo apt update && \
sudo apt upgrade -y && \
sudo apt install -y git curl python3 python3-pip python3-venv pipx openssh-client && \
mkdir -p ~/.local/bin && \
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && \
export PATH="$HOME/.local/bin:$PATH" && \
pipx ensurepath && \
pipx install --include-deps ansible && \
~/.local/bin/ansible-galaxy collection install community.docker

# 2. Clone this repo
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/portable-dotnet-architecture.git
cd ~/src/portable-dotnet-architecture/docker

```

## SSH key setup

The `common` role ensures the controller's public key is in `devops`'s `authorized_keys`.
For a brand-new VPS, the first run should connect as your initial admin/root user;
subsequent runs can connect as `devops`.

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
cd ~/src/portable-dotnet-architecture/docker/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
# set postgres_root_password and postgres_password before bootstrap
```

```yaml
ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_devops.pub') }}"
```

**More than one key, and rotation.** One key is a single point of failure — the `common` role manages `authorized_keys` declaratively and takes a list:

```yaml
# vault.yml — optional additional keys (workstation, break-glass kept offline)
ansible_ssh_extra_public_keys:
  - "ssh-ed25519 AAAA... workstation"
  - "ssh-ed25519 AAAA... break-glass"
```

Once every key you rely on is listed, set `ssh_authorized_keys_exclusive: true` in `main.yml`: keys **not** in the list are removed on the next run, so rotating a compromised key is *delete the line, run the playbook*. Don't edit `~/.ssh/authorized_keys` by hand; the next run reconciles it.

> **The keys people leave out are the ones seeded outside Ansible** — a hypervisor's root key injected at VM creation, a key the OS installer imported. They don't read as "someone's identity", so they're forgotten, and the first `exclusive: true` run deletes them from every host along with the log-in-from-the-host recovery path. Before flipping the flag: `ansible all -m command -a 'cat ~/.ssh/authorized_keys' -b --become-user devops`, and reconcile against the list.

> **Credentials that must live outside this environment** (password manager, ideally plus a paper copy kept physically separate): the private keys, every password in `vault.yml`, and the vault password itself if you encrypt the file. Recovery credentials must never exist only inside the thing they recover. The role also pins SSH to key-only (`PasswordAuthentication no` drop-in), so a provider/console password can never open password auth over SSH.

## Configure

```bash
cd ~/src/portable-dotnet-architecture/docker
vim infra/ansible/inventory/hosts.ini                  # VPS IP

vim infra/ansible/inventory/group_vars/all/main.yml    # applications list, ports, etc.

cd ~/src/portable-dotnet-architecture/docker/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
# required values:
# postgres_root_password: "replace-me"
# postgres_password: "replace-me"
# ansible-vault encrypt inventory/group_vars/all/vault.yml
```

**Bootstrap**

**First run** (if `devops` does not exist yet):

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml -u root --ask-vault-pass
```

**Subsequent runs** (`ansible.cfg` + inventory default to `devops`):

```bash
ansible-playbook playbooks/bootstrap.yml
# With vault: ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

Bootstrap also performs the initial deploy automatically for each application using its `image_default`, but only if that application has not been deployed before.

### Key variables in `inventory/group_vars/all/main.yml`

| Variable                | Description                                             |
|-------------------------|---------------------------------------------------------|
| `applications`          | List of app definitions (see below)                     |
| `postgres_image`        | Full Postgres image (default `postgis/postgis:18-3.6`)  |
| `postgres_max_connections` | Server connection ceiling (default 128, sized from the per-app pool budgets) |
| `backup_retention_days` | Days to keep nightly dumps (default 7)                  |
| `use_cloudflared`       | `true` to install Cloudflare Tunnel                     |

> PostgreSQL 18+ note: upstream `postgis/postgis` changed default `VOLUME`
> path to `/var/lib/postgresql`. The compose template in this repo already
> mounts this path and sets `PGDATA=/var/lib/postgresql/data` for compatibility.

### Application definition

```yaml
applications:
  - name:          myapp                # used for container names, scripts path
    server_name:   myapp.example.com    # Nginx server_name
    blue_port:     18081                # host port for blue container
    green_port:    18082                # host port for green container
    internal_port: 8080                 # container's ASPNETCORE_URLS port
    image_default: ghcr.io/org/myapp:latest
    drain_seconds: 32
    appsettings_override:               # → appsettings.override.json (see below)
      ConnectionStrings:
        App: "Host=postgres;Port=5432;Database=myapp_db;Username=appuser;Password={{ postgres_password }};Pooling=true;Keepalive=60;Maximum Pool Size=18"
```

> Databases are **not** pre-created by Ansible — .NET EF Core creates them
> automatically on first migration. The `postgres_user` has `CREATEDB` privilege.

### Application configuration (`appsettings_override`)

The `appsettings_override` dictionary is rendered as `appsettings.override.json` and
mounted read-only into the container at `/app/appsettings.override.json`.

.NET automatically merges it on top of the `appsettings.json` baked into the Docker
image when `DOTNET_ENVIRONMENT=Production` (set via `common.env`).

Put **only the values that differ per environment** here — connection strings, secrets,
URLs.  Everything else stays in the image's `appsettings.json`.

Npgsql keeps one pool per unique connection string, so give every string an explicit
`Maximum Pool Size` — budget ~18–28 connections per app (hot path 18, auth 8, key
ring 2) so several apps can share one Postgres without exhausting `max_connections`.
`Keepalive=60` lets each pool detect and evict connections killed by a Postgres
restart (container recreate, minor image update) before requests trip over them.

Reference vault variables for secrets:

```yaml
# inventory/group_vars/all/vault.yml
postgres_password: "strong-password"
smtp_password:     "smtp-secret"

# inventory/group_vars/all/main.yml  (inside application entry)
appsettings_override:
  ConnectionStrings:
    Users:          "Host=postgres;Port=5432;Database=waa_users;Username=appuser;Password={{ postgres_password }};Pooling=true;Keepalive=60;Maximum Pool Size=8"
    DataProtection: "Host=postgres;Port=5432;Database=waa_dp;Username=appuser;Password={{ postgres_password }};Pooling=true;Keepalive=60;Maximum Pool Size=2"
    App:            "Host=postgres;Port=5432;Database=waa;Username=appuser;Password={{ postgres_password }};Pooling=true;Keepalive=60;Maximum Pool Size=18"
  FileStorage:
    BaseDirectory: "/data/files"
  Email:
    Agents:
      DEFAULT:
        Smtp:
          Authentication:
            Password: "{{ smtp_password }}"
```

> **Why not `.env` with `ConnectionStrings__Users=...`?**  
> Environment variables work for flat settings, but deeply nested configs like
> `Email__Agents__DEFAULT__Smtp__Authentication__Password` become unreadable.
> A mounted JSON file keeps the original structure and is easier to audit.

### Container registry authentication

For public images, including public GHCR images, no token is required for pulls.

For private images, add credentials in Ansible variables:

```yaml
# infra/ansible/inventory/group_vars/all/vault.yml
ghcr_token: "github_pat_xxx"
```

```yaml
# infra/ansible/inventory/group_vars/all/main.yml
applications:
  - name: myapp
    image_default: ghcr.io/org/myapp:latest
    registry_server: ghcr.io
    registry_username: your-github-username
    registry_password: "{{ ghcr_token }}"
```

The generated deploy script performs `docker login` before `docker compose pull` only when all three values are present.

## Deploy

After bootstrap, each app has its scripts at `/opt/apps/<name>/scripts/` and the initial deploy has already been performed from `image_default`.

```bash
# Deploy a newer specific image:
sudo -u devops /opt/apps/myapp/scripts/deploy.sh ghcr.io/org/myapp:v1.2.3

# Rollback (instant Nginx swap, no container changes):
sudo -u devops /opt/apps/myapp/scripts/rollback.sh
```

If the target image is private, the host must already have the registry credentials configured via Ansible as shown above.

## Deployment sequence

```
docker pull <idle-slot-image>
  ↓
docker compose up -d <app>-<idle>
  ↓
poll /.well-known/ready (max 90s)
  ↓
cp upstream-<idle>.conf → nginx conf.d
nginx -t && systemctl reload nginx
  ↓
sleep drain_seconds
  ↓
docker compose stop <app>-<active>
```

## Directory layout on VPS

```
/opt/apps/
  <app>/
    config/
      appsettings.override.json  ← mounted read-only into container
    docker/
      compose.base.yml
      compose.blue.yml
      compose.green.yml
    env/
      common.env        ← ASPNETCORE_URLS, DOTNET_ENVIRONMENT
      blue.env          ← SLOT_NAME=blue
      green.env         ← SLOT_NAME=green
    nginx/
      upstream-blue.conf
      upstream-green.conf
    runtime/
      active-slot
      active-image
      deploy-history.log
    scripts/
      deploy.sh         ← deploy.sh <image>
      rollback.sh
      health-check.sh
      switch-nginx.sh
      current-slot.sh

/opt/postgres/
  docker/
    compose.postgres.yml
    postgres.env        ← root password (0600)
  backups/              ← nightly per-database .sql.gz files
  scripts/
    pg-backup.sh        ← auto-discovers all user databases
```

## Postgres backup

A cron job runs nightly at 02:30, dumping every user database individually as
`<dbname>_<timestamp>.sql.gz` under `/opt/postgres/backups/`.
Old backups are pruned after `backup_retention_days` (default 7).

Databases are **not** pre-created — .NET EF Core handles that via migrations.
The backup script auto-discovers all non-system databases, so new databases
are included automatically.

```bash
# Manual backup:
/opt/postgres/scripts/pg-backup.sh

# Restore a database:
gunzip -c /opt/postgres/backups/myapp_db_20240101-020030.sql.gz \
  | docker exec -i postgres psql -U postgres -d myapp_db
```

## Cloudflare Tunnel (optional)

Set `use_cloudflared: true` and provide `cloudflare_token` in `vault.yml`.
With a tunnel active, remove ports 80/443 from `ufw_allowed_tcp_ports` to keep the VPS unexposed.
