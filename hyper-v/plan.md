# Windows 11 + Hyper-V rollout plan

## Goal

Reach the same end state as `native/`, but with Windows 11 as the host and Ubuntu VMs on Hyper-V.

End state:

- one persistent control VM for Ansible and secrets
- one persistent app VM running Nginx and the .NET apps
- one persistent postgres VM running PostgreSQL and PostGIS
- one persistent monitoring VM running Dockerized Loki + Grafana
- blue/green deploy and rollback through the existing scripts from `native/`

## Phase 1: Hyper-V host preparation

1. Enable Hyper-V on Windows 11 Pro/Enterprise.
2. Create an External virtual switch bound to the NIC that reaches your LAN/router.
3. Reserve or assign stable LAN IPs for all target Ubuntu VMs.
4. Decide where backups leave the box: NAS, another Linux machine, cloud object storage, or encrypted external disk.

Recommended Windows-side decisions:

- keep Windows Update automatic, but schedule it outside business hours
- enable VM auto-start for all target Ubuntu VMs
- keep the controller and app VM on separate virtual disks

## Phase 2: Create the VMs

Create:

- `ubuntu-control`
- `ubuntu-app-01`
- `ubuntu-postgres`
- `ubuntu-monitoring`

Suggested sizing:

- `ubuntu-control`: 2 vCPU, 4 GB RAM, 40 GB disk
- `ubuntu-app-01`: 4 vCPU minimum, 8 GB RAM minimum, 80 GB disk minimum
- `ubuntu-postgres`: 2-4 vCPU, 4-8 GB RAM, 60 GB disk minimum
- `ubuntu-monitoring`: 2 vCPU, 4 GB RAM, 40 GB disk minimum

If PostgreSQL will hold real data volume, size the postgres VM storage first. Resizing later is possible, but avoid making it your normal operating path. Consider attaching a second VHDX for backups on a different physical disk.

## Phase 3: Base OS setup

Install Ubuntu 24.04 LTS on all four VMs.

On each VM:

- install OpenSSH server during setup or immediately after first boot
- update packages
- set hostname and timezone
- confirm all VMs can reach each other by IP

On the app VM specifically:

- if disk space is larger than the initial root filesystem, expand the root partition and filesystem before bootstrap

On the postgres VM specifically:

- if you attached a second VHDX for backups, verify it appears as `/dev/sdb` unformatted — the `postgres` role will format and mount it automatically

## Phase 4: Controller setup

On `ubuntu-control`:

1. Install Ansible and Git.
2. Generate or restore the dedicated SSH key used for Ansible.
3. Clone this repository.
4. Copy the prepared files from `hyper-v/files/` into `native/infra/ansible/inventory/`.
5. Edit:
   - app VM IP (`[app]` group in `hosts.ini`)
   - postgres VM IP (`[postgres]` group in `hosts.ini`)
   - `postgres_host` and `postgres_app_cidr` in `main.yml`
   - domain names, repository URLs, and project paths
   - secrets in `vault.yml`

Design rule:

- generate and keep the Ansible SSH key inside `ubuntu-control`, not on Windows

That keeps file permissions and Ansible lookups predictable.

## Phase 5: First bootstrap

From `ubuntu-control`, run the single bootstrap playbook. It contains two plays:

- **Play 1** targets `[postgres]` (`ubuntu-postgres`): installs `common` + `postgres`
- **Play 2** targets `[app]` (`ubuntu-app-01`): installs `common` + `dotnet` + `nginx` + `app`

Run as either `root` (if enabled) or the initial Ubuntu user with `sudo`:

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible-playbook playbooks/bootstrap.yml -u ubuntu --ask-become-pass
```

The `common` role creates the `devops` user and installs passwordless sudo on target VMs. You do not need to hand-create `devops` before running.

Play behavior:

- Play 1 targets `[postgres]` (`ubuntu-postgres`)
- Play 2 targets `[app]` (`ubuntu-app-01`)
- Play 3 targets `[monitoring]` (`ubuntu-monitoring`) when `use_loki_grafana: true` and `monitoring_target: monitoring`

After bootstrap, all future runs use the `devops` account through the configured SSH key.

## Phase 6: Productive hardening

Before exposing traffic, confirm:

- PostgreSQL backups are created on `ubuntu-postgres` and exported off the Hyper-V host
- your domain resolves correctly or Cloudflare Tunnel is active
- app readiness endpoint returns `200`
- rollback works on a test deploy

Practical additions worth doing early:

- enable `ansible-vault` for `vault.yml`
- document the vault password recovery path
- keep a copy of the controller SSH key in a password manager or encrypted archive

## Phase 7: Operations model

Normal app operations stay inside the app VM:

- deploy: `sudo -u devops /opt/apps/<app>/scripts/deploy.sh`
- rollback: `sudo -u devops /opt/apps/<app>/scripts/rollback.sh`

Normal database operations stay inside the postgres VM:

- manual backup: `sudo -u postgres /opt/postgres/scripts/pg-backup.sh`

Normal infrastructure changes stay inside the control VM:

- edit `native/infra/ansible/inventory/...`
- rerun `ansible-playbook playbooks/bootstrap.yml`

Normal monitoring operations stay inside the monitoring VM:

- check stack: `ssh devops@<monitoring-ip> 'cd /opt/monitoring && sudo docker compose ps'`
- restart stack: `ssh devops@<monitoring-ip> 'cd /opt/monitoring && sudo docker compose up -d'`

## When to move beyond native/

Stay on `native/` if:

- you have 1-3 apps
- you want minimal overhead
- you are comfortable with apps building on the server during deploy

Move to `docker/` if:

- you want immutable images and cleaner runtime packaging
- you need simpler CI/CD handoff between environments

Move to `k3s-proxmox/` only if:

- you are intentionally standardizing on Kubernetes
- you accept the operational overhead
- you want multi-node or GitOps as a first-class requirement