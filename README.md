# portable-dotnet-architecture

Incremental reference architecture for deploying .NET (and other) services on a plain Ubuntu VPS.
Four self-contained setups — pick the one that matches your constraints and grow into the next
when you need to.

## Setups

| Folder     | When to use                                          | Key tools                              |
|------------|------------------------------------------------------|----------------------------------------|
| [`native/`](native/) | Single or multiple apps, no Docker, minimal overhead | Ansible, systemd, Nginx, Postgres (native) |
| [`docker/`](docker/) | Multiple apps, Docker-based, intermediate complexity | Ansible, Docker Compose, Nginx, Postgres (container) |
| [`k3s/`](k3s/)       | Horizontal scaling, GitOps, full IaC on cloud VPS | Terraform (Hetzner), Ansible, k3s, FluxCD, Helm |
| [`k3s-proxmox/`](k3s-proxmox/) | Same as `k3s/` but on self-hosted Proxmox | Terraform (bpg/proxmox), Ansible, k3s, FluxCD, Helm |

`native/` and `docker/` now perform the first application deploy during bootstrap when the required application source or image settings are configured. `native/` uses a multi-app `applications` definition. `k3s/` and `k3s-proxmox/` continue to deploy applications through FluxCD from Git.

## Minimal bootstrap (all setups)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip jq bash-completion \
  python3 python3-pip python3-venv pipx openssh-client sshpass

mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

pipx ensurepath
pipx install --include-deps ansible

mkdir -p ~/src
cd ~/src
git clone https://github.com/<your-org>/portable-dotnet-architecture.git

# Then pick a setup:
cd ~/src/portable-dotnet-architecture/native   # setup 1
cd ~/src/portable-dotnet-architecture/docker   # setup 2
cd ~/src/portable-dotnet-architecture/k3s      # setup 3
```

## Common patterns across all setups

- **Two-tier health checks**: `/.well-known/live` (liveness) and `/.well-known/ready` (readiness)
- **Graceful shutdown**: SIGTERM → drain in-flight requests → exit
- **Zero-downtime deploy**: idle slot starts → health check passes → traffic switches → old slot drains → stops
- **Postgres backup**: nightly `pg_dump`, retention configurable
- **Secrets**: never committed — managed via `ansible-vault` (setups 1 & 2) or k8s Secrets (setup 3)
- **Cloudflare Tunnel**: optional in all setups; removes need to expose ports 80/443 publicly

For setup-specific bootstrap inputs:
- `native/` uses multi-app via `applications`; each app can define `repo_url` and `project_path` for automatic first deploy, plus `appsettings_override` for `appsettings.override.json` merge values.
- `docker/` needs `image_default` for each application, plus registry credentials only for private images.

## Application contract

Your app must implement:

```
GET /.well-known/live   → 200 (process is alive)
GET /.well-known/ready  → 200 (startup complete, not draining)
                        → 503 (during startup or graceful shutdown)
```

See [`native/`](native/README.md) for a reference .NET 10 implementation.
For a complete end-to-end command walkthrough, see [`native/example`](native/example).

## Incremental path

```
native  ──►  docker  ──►  k3s  ──►  k3s-proxmox
  ↑             ↑            ↑             ↑
native multi-app   docker multi-app   cloud GitOps   on-prem GitOps
no Docker    Compose      Hetzner VPS   self-hosted Proxmox
manual CI    manual CI    IaC+FluxCD    IaC+FluxCD (no public IPs)
```

You can start with `native/`, migrate to `docker/` by containerising the app
(add a `Dockerfile`, push to a registry, update `image_default`), then move to `k3s/`
when you need autoscaling or want full GitOps.
Use `k3s-proxmox/` instead of `k3s/` when you prefer on-prem hardware over cloud VPS.
The two k3s setups share Ansible roles, Flux configs, and Helm charts.

Public registries work without extra credentials. If you use private images (including private GHCR repositories), configure registry credentials explicitly in the selected setup.
