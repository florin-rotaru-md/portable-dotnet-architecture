# Hyper-V overlay for native/

This folder adapts the existing `native/` setup to a Windows 11 host running Ubuntu VMs on Hyper-V.

It is not a separate deployment stack. The actual runtime still comes from `native/infra/ansible`.
This folder gives you:

- a practical rollout plan for Windows 11 + Hyper-V
- a Hyper-V-specific command walkthrough
- ready-to-copy inventory files for the `native/` Ansible setup

## Recommended topology

Use four Ubuntu 24.04 LTS VMs (naming pattern: `{name}-{distribution}`):

| VM | Purpose | Suggested size |
|----|---------|----------------|
| `control-ubuntu` | Ansible controller, repo checkout, SSH keys, vault files | 2 vCPU, 4 GB RAM, 40 GB disk |
| `app-ubuntu` | Nginx + .NET runtime, blue/green app slots | 4-8 vCPU, 8-16 GB RAM, 80+ GB disk |
| `postgres-ubuntu` | PostgreSQL + PostGIS, nightly backups | 2-4 vCPU, 4-8 GB RAM, 60+ GB disk |
| `monitoring-ubuntu` | Docker host for Loki + Grafana | 2 vCPU, 4 GB RAM, 40+ GB disk |

Why four VMs:

- the controller survives app and database rebuilds
- SSH keys and vault material stay isolated from the runtime host
- PostgreSQL on a dedicated VM allows independent scaling and backup disk placement
- Dockerized observability stays isolated from the app runtime and database
- Ansible matches the flow already documented in `native/`

If you want the smallest possible lab, you can point both `[app]` and `[postgres]` inventory groups at the same VM IP. For anything even mildly production-like, keep at least the database separate.

## Networking recommendation

Prefer an External Hyper-V vSwitch.

- stable LAN IPs make Ansible inventory predictable
- DNS, port forwarding, and tunnel configuration are simpler
- Windows Default Switch is fine for ad-hoc testing, not for a long-lived environment

Suggested addressing example:

- Windows host: `192.168.0.10`
- `control-ubuntu`: `192.168.0.20`
- `app-ubuntu`: `192.168.0.21`
- `postgres-ubuntu`: `192.168.0.22`
- `monitoring-ubuntu`: `192.168.0.23`

## Fast path

1. Create all four VMs and attach them to the same External vSwitch.
2. Install Ubuntu 24.04 LTS on all four.
3. In `control-ubuntu`, install Ansible and clone this repository.
4. Copy the files from `hyper-v/files/` into `native/infra/ansible/inventory/`.
5. Adjust IPs, domains, repository URLs, and secrets.
6. Run the first bootstrap from `control-ubuntu` — Play 1 targets `postgres-ubuntu`, Play 2 targets `app-ubuntu` (including Grafana Alloy), Play 3 targets `monitoring-ubuntu` (Loki + Grafana).

## Files in this folder

- `plan.md`: phased rollout plan for a practical Hyper-V deployment
- `example`: end-to-end command walkthrough adapted for Windows 11 + Hyper-V
- `files/hosts.ini`: inventory starter for the app VM
- `files/main.yml`: `group_vars/all/main.yml` starter for native multi-app mode
- `files/vault.yml.example`: secret template for the same flow

## Copy targets

Use these copy targets inside the repo checkout on `control-ubuntu`:

- `hyper-v/files/hosts.ini` -> `native/infra/ansible/inventory/hosts.ini`
- `hyper-v/files/main.yml` -> `native/infra/ansible/inventory/group_vars/all/main.yml`
- `hyper-v/files/vault.yml.example` -> `native/infra/ansible/inventory/group_vars/all/vault.yml`

## Production notes

- Keep the Windows host as the virtualization layer, not as the application runtime.
- Store the Ansible private key, the vault password, and database backups off-host.
- Prefer Cloudflare Tunnel if you do not control a static public IP.
- Enable Hyper-V VM auto-start and avoid treating checkpoints as backups.