# Hyper-V overlay for native/

This folder adapts the existing `native/` setup to a Windows 11 host running Ubuntu VMs on Hyper-V.

It is not a separate deployment stack. The actual runtime still comes from `native/infra/ansible`.
This folder gives you:

- a practical rollout plan for Windows 11 + Hyper-V
- a Hyper-V-specific command walkthrough
- ready-to-copy inventory files for the `native/` Ansible setup

## Recommended topology

Use two Ubuntu 24.04 LTS VMs:

| VM | Purpose | Suggested size |
|----|---------|----------------|
| `ubuntu-control` | Ansible controller, repo checkout, SSH keys, vault files | 2 vCPU, 4 GB RAM, 40 GB disk |
| `ubuntu-app-01` | Nginx, PostgreSQL, .NET runtime, blue/green app slots | 4-8 vCPU, 8-16 GB RAM, 80+ GB disk |

Why two VMs:

- the controller survives app VM rebuilds
- SSH keys and vault material stay isolated from the runtime host
- Ansible matches the flow already documented in `native/`

If you want the smallest possible lab, you can run everything in a single Ubuntu VM and target `127.0.0.1` or the VM IP. For anything even mildly production-like, keep the controller separate.

## Networking recommendation

Prefer an External Hyper-V vSwitch.

- stable LAN IPs make Ansible inventory predictable
- DNS, port forwarding, and tunnel configuration are simpler
- Windows Default Switch is fine for ad-hoc testing, not for a long-lived environment

Suggested addressing example:

- Windows host: `192.168.0.10`
- `ubuntu-control`: `192.168.0.20`
- `ubuntu-app-01`: `192.168.0.21`

## Fast path

1. Create the VMs and attach both to the same External vSwitch.
2. Install Ubuntu 24.04 LTS on both.
3. In `ubuntu-control`, install Ansible and clone this repository.
4. Copy the files from `hyper-v/files/` into `native/infra/ansible/inventory/`.
5. Adjust IPs, domains, repository URLs, and secrets.
6. Run the first bootstrap from `ubuntu-control` against `ubuntu-app-01`.

## Files in this folder

- `plan.md`: phased rollout plan for a practical Hyper-V deployment
- `example`: end-to-end command walkthrough adapted for Windows 11 + Hyper-V
- `files/hosts.ini`: inventory starter for the app VM
- `files/main.yml`: `group_vars/all/main.yml` starter for native multi-app mode
- `files/vault.yml.example`: secret template for the same flow

## Copy targets

Use these copy targets inside the repo checkout on `ubuntu-control`:

- `hyper-v/files/hosts.ini` -> `native/infra/ansible/inventory/hosts.ini`
- `hyper-v/files/main.yml` -> `native/infra/ansible/inventory/group_vars/all/main.yml`
- `hyper-v/files/vault.yml.example` -> `native/infra/ansible/inventory/group_vars/all/vault.yml`

## Production notes

- Keep the Windows host as the virtualization layer, not as the application runtime.
- Store the Ansible private key, the vault password, and database backups off-host.
- Prefer Cloudflare Tunnel if you do not control a static public IP.
- Enable Hyper-V VM auto-start and avoid treating checkpoints as backups.