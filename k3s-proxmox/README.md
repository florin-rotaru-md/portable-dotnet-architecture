# Setup 4 — k3s on Proxmox

Same GitOps stack as `k3s/` but VMs are provisioned on a **self-hosted Proxmox VE** node
instead of a cloud provider. Ideal for home-lab, on-prem, or hybrid scenarios.

## Differences vs `k3s/`

| Aspect              | `k3s/` (Hetzner)            | `k3s-proxmox/` (Proxmox)          |
|---------------------|-----------------------------|------------------------------------|
| Terraform provider  | `hetznercloud/hcloud`       | `bpg/proxmox`                      |
| VM provisioning     | Hetzner API                 | Proxmox QEMU/KVM via API           |
| Networking          | Hetzner private network     | Proxmox bridges (vmbr0, vmbr1)     |
| Public IPs          | Yes (by default)            | No — use Cloudflare Tunnel         |
| cloud-init delivery | Hetzner user_data field     | Proxmox snippets datastore         |
| VM backups          | Hetzner snapshots           | Proxmox vzdump / PBS               |

**Ansible roles, FluxCD configs, and Helm charts are identical to `k3s/`.**
`ansible.cfg` sets `roles_path` to `../../k3s/infra/ansible/roles` to avoid duplication.
Flux watches `k3s/flux/` paths in the same Git repo.

---

## Prerequisites

Before running Terraform, complete the one-time Proxmox host setup:

**→ [docs/proxmox-setup.md](docs/proxmox-setup.md)**

Summary:
1. Create a Terraform API token in Proxmox
2. Enable snippets on the `local` datastore
3. Create the Ubuntu 26.04 cloud-init VM template (VMID 9000)
4. Create the internal bridge `vmbr1` (10.10.0.0/24)

---

## Minimal bootstrap commands

```bash
# Install tools:
sudo apt install -y curl git python3 pipx
pipx install --include-deps ansible
ansible-galaxy collection install community.general community.docker

# Install Terraform:
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# Clone repo:
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/portable-dotnet-architecture.git
cd ~/src/portable-dotnet-architecture/k3s-proxmox
```

---

## Step-by-step

### 1. Provision VMs with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars       # Proxmox endpoint, API token, SSH key, etc.

terraform init
terraform plan
terraform apply
terraform output           # note the IPs
```

### 2. Update Ansible inventory

**Keep your inventory outside the clone.** Only the `.example` files are committed; a real
inventory on a tracked path turns every `git pull` on the control node into a conflict against your
own edits. Ansible resolves `group_vars/` relative to the inventory file, so the layout is all that
has to match — the reasoning is spelled out in the
[native setup's Configure section](../native/README.md#configure).

```bash
mkdir -p ~/app-inventory/group_vars/all
cd ~/src/portable-dotnet-architecture/k3s-proxmox/infra/ansible
cp inventory/hosts.ini.example                ~/app-inventory/hosts.ini
cp inventory/group_vars/all/main.yml.example  ~/app-inventory/group_vars/all/main.yml
cp inventory/group_vars/all/vault.yml.example ~/app-inventory/group_vars/all/vault.yml

echo 'export ANSIBLE_INVENTORY=~/app-inventory/hosts.ini' >> ~/.bashrc && . ~/.bashrc
#   ...or pass -i ~/app-inventory/hosts.ini per command.

vim ~/app-inventory/hosts.ini   # set IPs from terraform output
```

### 3. Configure variables and vault

```bash
vim ~/app-inventory/group_vars/all/main.yml
vim ~/app-inventory/group_vars/all/vault.yml
# required values:
# postgres_password: "replace-me"
# s3_access_key: "replace-me"
# s3_secret_key: "replace-me"
ansible-vault encrypt ~/app-inventory/group_vars/all/vault.yml
```

#### *(Optional)* Ansible service account — SSH key setup

Cloud-init creates a dedicated `ops` user on every VM.
The `common` role can install your controller key into that account via `ansible_ssh_public_key`.

**1. Generate a key pair on your control machine** (skip if you already have one):

```bash
test -f ~/.ssh/id_ed25519_devops || \
  ssh-keygen -t ed25519 -C "devops" -f ~/.ssh/id_ed25519_devops -N ""
```

**Copy the public key to the target VPS** (so Ansible can connect):

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub root@<vps-ip>
```

**2. Add the public key to `vault.yml`:**

```yaml
ansible_ssh_public_key: "ssh-ed25519 AAAA...  control-ubuntu"
# or use a Ansible lookup: "{{ lookup('file', '~/.ssh/id_ed25519_devops.pub') }}"
```

**More than one key, and rotation.** One key is a single point of failure — the `common` role manages `authorized_keys` declaratively and takes a list via `ansible_ssh_extra_public_keys` (workstation key, break-glass key kept offline). Once every key you rely on is listed, set `ssh_authorized_keys_exclusive: true` in `main.yml`: keys **not** in the list are removed on the next run, so rotating a compromised key is *delete the line, run the playbook*.

> **The keys people leave out of that list are the ones seeded outside Ansible** — here, `ssh_public_key` from `terraform.tfvars`, which cloud-init installed on every VM at creation, plus any hypervisor root key you authorized by hand. They don't read as "someone's identity", so they're forgotten, and then the first `exclusive: true` run deletes them from every VM and takes the log-in-from-the-hypervisor recovery path with them. Before flipping the flag: `ansible all -m command -a 'cat ~/.ssh/authorized_keys' -b --become-user ops`, and reconcile against the list. The same trap, in its Proxmox form: [proxmox-lab 21.6](../proxmox-lab/operations/21-credentials.md#216-two-habits-that-make-key-loss-boring).

> **Credentials that must live outside this environment** (password manager, ideally plus paper): the private keys, `vault.yml` contents, the vault password itself if encrypted — and the Proxmox root password plus any VM `--cipassword` (the console is your no-SSH recovery path). Recovery credentials must never exist only inside the thing they recover. The role also pins SSH to key-only, so a console password can never open password auth over SSH.

```bash
vim ~/app-inventory/group_vars/all/vault.yml
```

### 4. Bootstrap

```bash
cd infra/ansible

# First run — connect as the cloud-init user provisioned by Terraform (typically root):
ansible-playbook playbooks/bootstrap.yml -u root --ask-vault-pass

# All subsequent runs — ops user is set automatically via ansible.cfg + group_vars:
ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

This runs the same roles as `k3s/`:
- `common` — UFW, fail2ban on all nodes
- `postgres` — installs Postgres on the DB VM, nightly S3 backup
- `k3s_server` — installs k3s, schedules etcd snapshots to S3
- `flux` — bootstraps FluxCD, which then deploys everything from Git

### 5. Create Secrets in k3s

```bash
export KUBECONFIG=~/src/portable-dotnet-architecture/kubeconfig

# DB connection (use internal bridge IP 10.10.0.50):
kubectl create secret generic myapp-db \
  --from-literal=ConnectionStrings__Main="Host=10.10.0.50;Port=5432;Database=myapp_db;Username=appuser;Password=<pass>;Keepalive=60;Maximum Pool Size=18" \
  -n myapp

# Cloudflare Tunnel token (strongly recommended — VMs have no public IP):
kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token=<your-cloudflare-token> \
  -n cloudflared
```

Databases are not created by Ansible. Applications should create/update their own databases via migrations.
PostGIS is enabled on `template1`, and backups include all non-system databases.

If the application image is private, create an image pull secret in the same namespace and reference it from `k3s/flux/apps/myapp/helmrelease.yaml`:

```bash
kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github_pat> \
  -n myapp
```

```yaml
values:
  imagePullSecrets:
    - name: ghcr-creds
```

Public images do not need this secret.

### 6. Verify

```bash
kubectl get nodes
flux get all -A
```

---

## Directory layout

```
k3s-proxmox/
├── terraform/                    ← Proxmox VMs + optional Cloudflare DNS
│   ├── main.tf                   ← bpg/proxmox provider, cloud-init snippets
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── cloud-init/
│   └── user-data.yml             ← same as k3s/ + qemu-guest-agent
├── infra/ansible/
│   ├── ansible.cfg               ← roles_path → ../../k3s/infra/ansible/roles
│   ├── inventory/hosts.ini.example
│   ├── inventory/group_vars/all/main.yml.example    ← copy outside the clone
│   ├── inventory/group_vars/all/vault.yml.example
│   └── playbooks/bootstrap.yml
└── docs/
    ├── proxmox-setup.md          ← template, API token, bridges
    └── disaster-recovery.md      ← includes Proxmox host failure scenarios
```

Flux configs and Helm charts live in `k3s/flux/` and `k3s/helm/` and are shared.

---

## Cloudflare Tunnel

Since Proxmox VMs are on a private LAN, the recommended egress is Cloudflare Tunnel.
The `cloudflared` deployment in `k3s/flux/infra/cloudflared/` handles this.
Create the tunnel token Secret before Flux reconciles:

```bash
kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token=<token> \
  -n cloudflared
```

With a tunnel active, no ports need to be forwarded on your router.

---

## Disaster recovery

See [docs/disaster-recovery.md](docs/disaster-recovery.md) — includes the Proxmox-specific
scenario of **full host hardware loss** (D2) and the additional VM-backup layer via PBS/vzdump.
