# Setup 1 — Native .NET on a single VPS

Single Ubuntu VPS. No Docker. Application compiled and run directly as systemd services.
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

The `common` role creates a dedicated `ansible` user on the VPS with passwordless sudo.
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
cp --update=none group_vars/vault.yml.example group_vars/vault.yml
vim infra/ansible/group_vars/vault.yml
```

```yaml
ansible_ssh_public_key: "ssh-ed25519 AAAA...  ansible-control"
# or use a Ansible lookup ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_ansible.pub') }}"
```

## Configure

```bash
cd ~/src/portable-dotnet-architecture/native
# Edit inventory with your VPS IP:
vim infra/ansible/inventory/hosts.ini

# Edit app settings (name, domain, ports, .NET version…):
vim infra/ansible/group_vars/all.yml

# Fill in secrets:
cd ~/src/portable-dotnet-architecture/native/infra/ansible
cp --update=none group_vars/vault.yml.example group_vars/vault.yml
vim infra/ansible/group_vars/vault.yml
# Optionally encrypt: ansible-vault encrypt infra/ansible/group_vars/vault.yml
```

Key variables in `group_vars/all.yml`:

| Variable          | Description                                 |
|-------------------|---------------------------------------------|
| `app_name`        | Short identifier, becomes systemd unit name |
| `app_assembly`    | .NET assembly name (DLL without extension)  |
| `app_domain`      | Nginx server_name                           |
| `app_port_blue`   | Port for blue slot (default 5000)           |
| `app_port_green`  | Port for green slot (default 5001)          |
| `drain_seconds`   | Nginx drain before stopping old slot        |
| `use_cloudflared` | `true` to install Cloudflare Tunnel         |


**3. First bootstrap** — the `ansible` user doesn't exist yet, so connect as the initial root/admin user:

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml -u root --ask-pass --ask-vault-pass
```

> If the VPS was provisioned with your SSH key for root already, omit `--ask-pass`.

**4. All subsequent runs** — `ansible.cfg` and `group_vars` set `ansible_user: ansible` automatically:

```bash
ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

## Bootstrap

```bash
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml
# With vault: ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

## Deploy

After bootstrap, deploy.sh is installed at `/opt/apps/<app_name>/scripts/deploy.sh`.

**First deploy** (provide repo details once — cached for subsequent runs):
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
    common.env  ← shared env (DB connection string, etc.)
    blue.env    ← SLOT_NAME + ASPNETCORE_URLS for blue
    green.env   ← SLOT_NAME + ASPNETCORE_URLS for green
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

Set `use_cloudflared: true` in `group_vars/all.yml` and provide `cloudflare_token` in `vault.yml`.
The tunnel is installed as a systemd service and starts automatically.
With a tunnel active, you can remove ports 80/443 from `ufw_allowed_tcp_ports`.
