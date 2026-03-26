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
3. Create the Ubuntu 24.04 cloud-init VM template (VMID 9000)
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

```bash
vim infra/ansible/inventory/hosts.ini   # set IPs from terraform output
```

### 3. Configure variables and vault

```bash
vim infra/ansible/group_vars/all.yml

cp infra/ansible/group_vars/vault.yml.example infra/ansible/group_vars/vault.yml
vim infra/ansible/group_vars/vault.yml
ansible-vault encrypt infra/ansible/group_vars/vault.yml
```

### 4. Bootstrap

```bash
cd infra/ansible
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
  --from-literal=ConnectionStrings__Main="Host=10.10.0.50;Port=5432;Database=myapp_db;Username=appuser;Password=<pass>" \
  -n myapp

# Cloudflare Tunnel token (strongly recommended — VMs have no public IP):
kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token=<your-cloudflare-token> \
  -n cloudflared
```

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
│   ├── inventory/hosts.ini
│   ├── group_vars/all.yml
│   ├── group_vars/vault.yml.example
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
