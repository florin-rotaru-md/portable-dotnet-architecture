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
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl python3 python3-pip python3-venv pipx openssh-client
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
pipx ensurepath && pipx install --include-deps ansible
ansible-galaxy collection install community.docker

# 2. Clone this repo
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/portable-dotnet-architecture.git
cd ~/src/portable-dotnet-architecture/docker
```

## Configure

```bash
vim infra/ansible/inventory/hosts.ini       # VPS IP

vim infra/ansible/group_vars/all.yml        # applications list, ports, etc.

cp infra/ansible/group_vars/vault.yml.example infra/ansible/group_vars/vault.yml
vim infra/ansible/group_vars/vault.yml
# ansible-vault encrypt infra/ansible/group_vars/vault.yml
```

### Key variables in `group_vars/all.yml`

| Variable                | Description                                 |
|-------------------------|---------------------------------------------|
| `applications`          | List of app definitions (see below)         |
| `postgres_version`      | Postgres image tag (default `16`)           |
| `backup_retention_days` | Days to keep nightly dumps (default 7)      |
| `use_cloudflared`       | `true` to install Cloudflare Tunnel         |

### Application definition

```yaml
applications:
  - name:          myapp               # used for container names, scripts path
    db:            myapp_db            # database name in postgres
    server_name:   myapp.example.com   # Nginx server_name
    blue_port:     18081               # host port for blue container
    green_port:    18082               # host port for green container
    internal_port: 8080                # container's ASPNETCORE_URLS port
    image_default: ghcr.io/org/myapp:latest
    drain_seconds: 32
```

## Bootstrap

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml
# With vault: ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

## Deploy

After bootstrap, each app has its scripts at `/opt/apps/<name>/scripts/`.

```bash
# Deploy a specific image:
sudo -u deploy /opt/apps/myapp/scripts/deploy.sh ghcr.io/org/myapp:v1.2.3

# Rollback (instant Nginx swap, no container changes):
sudo -u deploy /opt/apps/myapp/scripts/rollback.sh
```

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
    docker/
      compose.base.yml
      compose.blue.yml
      compose.green.yml
    env/
      common.env        ← DB connection string, ASPNETCORE_URLS
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
  backups/              ← nightly pg_dump -Fc files
  backup-db.sh
  backup.log
```

## Postgres persistence

Data lives in Docker named volume `postgres_data`. To inspect or back up manually:

```bash
# Manual backup of all databases:
/opt/postgres/backup-db.sh

# Restore a database:
docker exec -i postgres pg_restore -U appuser -d myapp_db < /opt/postgres/backups/myapp_db-20240101-020015.dump
```

## Cloudflare Tunnel (optional)

Set `use_cloudflared: true` and provide `cloudflare_token` in `vault.yml`.
With a tunnel active, remove ports 80/443 from `ufw_allowed_tcp_ports` to keep the VPS unexposed.
