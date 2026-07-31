# Setup 3 — k3s + Terraform + FluxCD + Helm

Full GitOps stack on a single-region k3s cluster. Infrastructure as code from VPS provisioning
to application deployment. External Postgres for data durability independent of the cluster.

## Stack

| Layer           | Tool                          |
|-----------------|-------------------------------|
| VPS / DNS       | Terraform + Hetzner Cloud     |
| OS bootstrap    | cloud-init                    |
| Configuration   | Ansible                       |
| Kubernetes      | k3s (embedded etcd)           |
| GitOps          | FluxCD v2                     |
| Apps            | Helm charts                   |
| Ingress         | ingress-nginx                 |
| TLS             | cert-manager (Let's Encrypt)  |
| Tunnel          | Cloudflare Tunnel             |
| DB              | Postgres on a separate VPS    |
| Backups         | S3-compatible (etcd + pg_dump)|

## Minimal bootstrap commands

```bash
# 1. Install tools on your laptop:
sudo apt install -y curl git unzip
# Terraform:
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
# Ansible + kubectl:
pipx install --include-deps ansible
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install kubectl /usr/local/bin/

# 2. Clone this repo
mkdir -p ~/src && cd ~/src
git clone https://github.com/<your-org>/portable-dotnet-architecture.git
cd ~/src/portable-dotnet-architecture/k3s
```

## Step-by-step setup

### 1. Configure and provision infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars          # fill in Hetzner + Cloudflare tokens, SSH key

terraform init
terraform plan
terraform apply
```

Take note of the output IPs:
```bash
terraform output
```

### 2. Update Ansible inventory

```bash
vim infra/ansible/inventory/hosts.ini   # set IPs from terraform output
```

### 3. Configure Ansible variables

```bash
vim infra/ansible/inventory/group_vars/all/main.yml

cd ~/src/portable-dotnet-architecture/k3s/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
# required values:
# postgres_password: "replace-me"
# s3_access_key: "replace-me"
# s3_secret_key: "replace-me"
ansible-vault encrypt inventory/group_vars/all/vault.yml
```

#### *(Optional)* Ansible service account — SSH key setup

Cloud-init creates a dedicated `ops` user on every node.
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

```bash
cd ~/src/portable-dotnet-architecture/k3s/infra/ansible
cp --update=none inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vim inventory/group_vars/all/vault.yml
```

**More than one key, and rotation.** One key is a single point of failure — the `common` role manages `authorized_keys` declaratively and takes a list via `ansible_ssh_extra_public_keys` (workstation key, break-glass key kept offline). Once every key you rely on is listed, set `ssh_authorized_keys_exclusive: true` in `main.yml`: keys **not** in the list are removed on the next run, so rotating a compromised key is *delete the line, run the playbook*.

> **Credentials that must live outside this environment** (password manager, ideally plus paper): the private keys, `vault.yml` contents (postgres password, S3 keys — losing the S3-encrypted backups' credentials makes them unrecoverable), and the vault password itself if encrypted. Recovery credentials must never exist only inside the thing they recover. The role also pins SSH to key-only, so a provider console password can never open password auth over SSH.

### 4. Bootstrap everything

```bash
cd infra/ansible

# First run — connect as the cloud-init user (root or ubuntu, as provisioned by Terraform):
ansible-playbook playbooks/bootstrap.yml -u root --ask-vault-pass

# All subsequent runs — ops user is set automatically via ansible.cfg + group_vars:
ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

This single command:
- Hardens all nodes (UFW, fail2ban)
- Installs and configures Postgres on the DB VPS
- Installs k3s on server node(s)
- Bootstraps FluxCD — which then pulls this Git repo and deploys all infra + apps

### 5. Create Secrets (not stored in Git)

```bash
export KUBECONFIG=~/src/portable-dotnet-architecture/kubeconfig

# DB connection string for myapp:
kubectl create secret generic myapp-db \
  --from-literal=ConnectionStrings__Main="Host=<postgres-private-ip>;Port=5432;Database=myapp_db;Username=appuser;Password=<pass>" \
  -n myapp

# Cloudflare tunnel token:
kubectl create secret generic cloudflare-tunnel-token \
  --from-literal=token=<your-cloudflare-token> \
  -n cloudflared
```

Databases are not created by Ansible. Applications should create/update their own databases via migrations.
PostGIS is enabled on `template1`, and backups include all non-system databases.

If your container image is private, create an image pull secret in the app namespace and reference it from the HelmRelease:

```bash
kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github_pat> \
  -n myapp
```

Then set in `flux/apps/myapp/helmrelease.yaml`:

```yaml
values:
  imagePullSecrets:
    - name: ghcr-creds
```

Public images, including public GHCR images, do not require this secret.

### 6. Verify

```bash
kubectl get nodes
flux get all -A          # all resources should be Ready
kubectl get pods -A
```

## Directory layout

```
k3s/
├── terraform/              ← VPS, network, DNS provisioning
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── cloud-init/
│   └── user-data.yml       ← OS bootstrap (runs on first boot)
├── infra/ansible/
│   ├── playbooks/bootstrap.yml
│   └── roles/
│       ├── common/         ← UFW, fail2ban
│       ├── postgres/       ← Postgres install + S3 backup cron
│       ├── k3s_server/     ← k3s install + etcd S3 snapshot cron
│       └── flux/           ← Flux CLI + bootstrap
├── flux/
│   ├── clusters/production/
│   │   ├── flux-system/    ← managed by Flux bootstrap
│   │   ├── infra.yaml      ← deploys infra/ kustomization
│   │   └── apps.yaml       ← deploys apps/ kustomization (depends on infra)
│   ├── infra/
│   │   ├── cert-manager/   ← Let's Encrypt TLS
│   │   ├── ingress-nginx/  ← Nginx ingress controller
│   │   └── cloudflared/    ← Cloudflare Tunnel
│   └── apps/
│       └── myapp/          ← HelmRelease for your application
├── helm/
│   └── myapp/              ← Helm chart (Deployment, Service, Ingress, HPA, PDB)
└── docs/
    └── disaster-recovery.md
```

## Deploying a new app version

```bash
# Edit the image tag in the HelmRelease:
vim flux/apps/myapp/helmrelease.yaml   # update image.tag

git add flux/apps/myapp/helmrelease.yaml
git commit -m "chore: bump myapp to v1.2.3"
git push

# Flux picks it up within 5 minutes (interval: 5m).
# To trigger immediately:
flux reconcile kustomization apps --with-source
```

## Scaling out (adding a k3s agent node)

```bash
# In terraform/main.tf, add a hcloud_server for agent nodes.
# In infra/ansible/roles/k3s_server/tasks/main.yml, install k3s with --server flag.
# Flux automatically distributes workloads across nodes.
```

## Disaster recovery

See [docs/disaster-recovery.md](docs/disaster-recovery.md).
