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

The `common` role ensures the controller's public key is in `deploy`'s `authorized_keys`,
making all Ansible runs key-based from the start.

**1. Generate a key pair on your control machine** (skip if you already have one):

```bash
test -f ~/.ssh/id_ed25519_ansible || \
  ssh-keygen -t ed25519 -C "ansible-control" -f ~/.ssh/id_ed25519_ansible -N ""
```

**Copy the public key to the target VPS** (so Ansible can connect):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_ansible.pub deploy@<vps-ip>
```

**2. Add the public key to `vault.yml`** (see Configure below):

```bash
cd ~/src/portable-dotnet-architecture/docker/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
# set postgres_root_password and postgres_password before bootstrap
```

```yaml
ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_ansible.pub') }}"
```

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
# ansible-vault encrypt infra/ansible/inventory/group_vars/all/vault.yml
```

**Bootstrap — all runs connect as `deploy`:**

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml
# With vault: ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

### Key variables in `inventory/group_vars/all/main.yml`

| Variable                | Description                                 |
|-------------------------|---------------------------------------------|
| `applications`          | List of app definitions (see below)         |
| `postgres_version`      | Postgres image tag (default `18`)           |
| `backup_retention_days` | Days to keep nightly dumps (default 7)      |
| `use_cloudflared`       | `true` to install Cloudflare Tunnel         |

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
    appsettings_override:               # → appsettings.Production.json (see below)
      ConnectionStrings:
        App: "Host=postgres;Port=5432;Database=myapp_db;Username=appuser;Password={{ postgres_password }};Pooling=true"
```

> Databases are **not** pre-created by Ansible — .NET EF Core creates them
> automatically on first migration. The `postgres_user` has `CREATEDB` privilege.

### Application configuration (`appsettings_override`)

The `appsettings_override` dictionary is rendered as `appsettings.Production.json` and
mounted read-only into the container at `/app/appsettings.Production.json`.

.NET automatically merges it on top of the `appsettings.json` baked into the Docker
image when `DOTNET_ENVIRONMENT=Production` (set via `common.env`).

Put **only the values that differ per environment** here — connection strings, secrets,
URLs.  Everything else stays in the image's `appsettings.json`.

Reference vault variables for secrets:

```yaml
# inventory/group_vars/all/vault.yml
postgres_password: "strong-password"
smtp_password:     "smtp-secret"

# inventory/group_vars/all/main.yml  (inside application entry)
appsettings_override:
  ConnectionStrings:
    Users:          "Host=postgres;Port=5432;Database=waa_users;Username=appuser;Password={{ postgres_password }};Pooling=true"
    DataProtection: "Host=postgres;Port=5432;Database=waa_dp;Username=appuser;Password={{ postgres_password }};Pooling=true"
    App:            "Host=postgres;Port=5432;Database=waa;Username=appuser;Password={{ postgres_password }};Pooling=true"
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

After bootstrap, each app has its scripts at `/opt/apps/<name>/scripts/`.

```bash
# Deploy a specific image:
sudo -u deploy /opt/apps/myapp/scripts/deploy.sh ghcr.io/org/myapp:v1.2.3

# Rollback (instant Nginx swap, no container changes):
sudo -u deploy /opt/apps/myapp/scripts/rollback.sh
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
      appsettings.Production.json  ← mounted read-only into container
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
