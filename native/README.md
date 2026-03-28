# Setup 1 — Native .NET multi-app on a VPS

Single Ubuntu VPS. No Docker. Applications are compiled and run directly as systemd services.
Blue/green deployment via source build (`dotnet publish`) and Nginx upstream swap.

## What gets installed

| Component  | Method           |
|------------|------------------|
| .NET SDK   | Microsoft apt    |
| PostgreSQL | PGDG apt         |
| Nginx      | Ubuntu apt       |
| cloudflared| Cloudflare apt *(optional)* |

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

The `common` role creates a dedicated `deploy` user on the VPS with passwordless sudo.
All playbook runs connect as this user after the initial bootstrap.

**1. Generate a key pair on your control machine** (skip if you already have one):

```bash
test -f ~/.ssh/id_ed25519_ansible || \
  ssh-keygen -t ed25519 -C "ansible-control" -f ~/.ssh/id_ed25519_ansible -N ""
```

**Copy the public key to the target VPS** (so Ansible can connect):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_ansible.pub root@<vps-ip>
```

**2. Add the public key to `vault.yml`** (see Configure below):

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
```

```yaml
ansible_ssh_public_key: "ssh-ed25519 AAAA...  ansible-control"
# or use an Ansible lookup ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_ansible.pub') }}"
```

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
# Optionally encrypt: ansible-vault encrypt inventory/group_vars/all/vault.yml
```

Key variables in `inventory/group_vars/all/main.yml`:

| Variable          | Description                                 |
|-------------------|---------------------------------------------|
| `applications`    | List of native apps (required)              |
| `name`            | App identifier (systemd/nginx/runtime paths) |
| `assembly`        | .NET assembly name (DLL without extension)  |
| `domain`          | Nginx `server_name`                         |
| `port_blue`       | Port for blue slot                          |
| `port_green`      | Port for green slot                         |
| `drain_seconds`   | Nginx drain before stopping old slot        |
| `repo_url`        | Git repo URL used for initial deploy        |
| `project_path`    | Path to the `.csproj` used for first deploy |
| `appsettings_override` | Per-app `appsettings.Production.json` merge values |
| `use_cloudflared` | `true` to install Cloudflare Tunnel         |

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

**3. First bootstrap** — the `deploy` user doesn't exist yet, so connect as the initial root/admin user:

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml -u root --ask-pass --ask-vault-pass
```

> If the VPS was provisioned with your SSH key for root already, omit `--ask-pass`.

**4. All subsequent runs** — `ansible.cfg` and `group_vars` set `ansible_user: deploy` automatically:

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
sudo -u deploy /opt/apps/myapp/scripts/deploy.sh \
  --repo-url     "https://github.com/your-org/your-repo.git" \
  --branch       "master" \
  --token        "ghp_xxx"   # omit for public repos \
  --project-path "src/MyApp/MyApp.csproj"
```

**Subsequent deploys:**
```bash
sudo -u deploy /opt/apps/myapp/scripts/deploy.sh
```

**Rollback** (switches Nginx back instantly):
```bash
sudo -u deploy /opt/apps/myapp/scripts/rollback.sh
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
    appsettings.Production.json  ← rendered from appsettings_override and copied on deploy
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
