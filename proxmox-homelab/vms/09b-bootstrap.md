# Stage 9b — First Ansible bootstrap (filling the VMs)

*Part of the [waa Proxmox homelab guide](../README.md).*

Stages 8–9 produced three empty Ubuntu machines. Everything that makes them *useful* — Postgres + PostGIS, the .NET app with blue/green deploys, nginx, `cloudflared`, the nightly database dump, SSH key management — is installed by the Ansible project in [`native/infra/ansible`](../../native/infra/ansible), run from control-ubuntu (1010). This stage is that first run.

It sits **before replication (Stage 10) on purpose**: finish the machines first, then wire redundancy around them. Replicating, HA-protecting and failover-testing VMs that don't run anything yet just means doing parts of Stages 10–15 twice.

The authoritative command-by-command walkthrough is [`native/example`](../../native/example) — a copy-paste file covering the control node, `vault.yml`, `main.yml`, inventory and the playbook run. **Follow it from the `on control vm:` section onward**, with the homelab-specific differences below. Don't skim past them; two of these (the split-VM database variables) produce a broken app if left at their single-VM defaults.

## 9b.1 What's different here vs `native/example`

| Topic | `native/example` (single VPS) | This homelab |
|---|---|---|
| Topology | app + postgres on one VM | app = **1020** (.20), postgres = **1030** (.30) |
| `hosts.ini` | one `[app]` host | `[app]` and `[postgres]` groups — see 9b.3 |
| `postgres_host` | `127.0.0.1` | **`192.168.0.30`** — the app's connection strings point here |
| `postgres_app_cidr` | empty (loopback only) | **`192.168.0.20/32`** — lets 1020 reach Postgres; the role writes it into `pg_hba.conf` and the firewall |
| `use_cloudflared` | `false` | `true` + `cloudflare_token` in `vault.yml` — the tunnel lives inside 1020 ([why](cloudflare-tunnel.md)) |
| sudoers / `growpart` prep steps | needed (hand-installed VM) | **skip** — cloud-init already set up `devops`, and the postgres disk was grown in [Stage 9](09-vms.md#resize-the-postgres-disk-after-cloning) |
| SSH keys | generated in the walkthrough | already done at the end of [Stage 9](09-vms.md#ssh-keys) — reuse `~/.ssh/id_ed25519_devops` |

## 9b.2 On control-ubuntu (1010)

Ansible and the SSH key exist since Stage 9. Clone the repo:

```bash
mkdir -p ~/src && cd ~/src
git clone https://github.com/florin-rotaru-md/portable-dotnet-architecture
```

## 9b.3 Inventory — the homelab addresses

```bash
cat << 'EOF' > ~/src/portable-dotnet-architecture/native/infra/ansible/inventory/hosts.ini
[app]
192.168.0.20 ansible_user=devops ansible_private_key_file=~/.ssh/id_ed25519_devops

[postgres]
192.168.0.30 ansible_user=devops ansible_private_key_file=~/.ssh/id_ed25519_devops
EOF
```

Sanity check before anything else — both VMs reachable, passwordless sudo working:

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible all -m ping
ansible all -b -m command -a whoami        # expect: root, twice
```

> If the `-b` check prompts for a password, cloud-init didn't grant `devops` passwordless sudo on that clone. Fix it once, over SSH: `echo 'devops ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/devops && sudo chmod 440 /etc/sudoers.d/devops`.

## 9b.4 `vault.yml` and `main.yml`

Create both exactly as `native/example` shows, then apply the homelab deltas from the 9b.1 table — in `main.yml`:

```yaml
postgres_host: "192.168.0.30"
postgres_app_cidr: "192.168.0.20/32"
use_cloudflared: true
```

and in `vault.yml`, alongside the keys and `postgres_password`:

```yaml
cloudflare_token: "eyJhIjoi..."        # the tunnel token for waa
```

Two rules worth internalizing now, because they outlive this stage:

- **`vault.yml` is never committed** (it's gitignored); `postgres_password` and every token live only there and in the password manager — see the credential inventory in [Stage 18.1](../operations/18-credentials.md#181-inventory--what-exists-and-where-it-lives).
- **Any `group_vars` change you make here must be mirrored** into the example files (`native/example` and the hyper-v/docker counterparts) — they are full copies meant to stay in sync, per the [repo rule](../README.md#relationship-to-the-rest-of-the-repo).

## 9b.5 Run it

```bash
cd ~/src/portable-dotnet-architecture/native/infra/ansible
ansible-playbook playbooks/bootstrap.yml --diff
```

The first run takes a while: PGDG + PostGIS on 1030, the .NET SDK on 1020, and — because `repo_url`/`project_path` are set — the **first application deploy**, straight into the blue slot. `--diff` shows every file it writes; on a fresh VM that's a lot of output, and that's fine. (Don't use `--check` with this role set — [Stage 17.3 step 4](../operations/17-upgrades.md#step-4-bump-the-variable-run-the-playbook) explains why it breaks.)

Re-running it later is always safe — that's the point of it being the single owner of in-VM state.

## 9b.6 Verify before moving on

```bash
# Postgres up, PostGIS present, dump script installed (on 1030)
ssh devops@192.168.0.30 'systemctl is-active postgresql && ls -l /opt/postgres/scripts/pg-backup.sh'
ssh devops@192.168.0.30 'sudo -u postgres psql -tAc "select version(), postgis_version()"'

# App slot up and healthy, nginx routing it (on 1020)
ssh devops@192.168.0.20 '/opt/apps/api.waa.ro/scripts/current-slot.sh'
curl -s -H "Host: api.waa.ro" http://192.168.0.20/.well-known/ready    # expect HTTP 200

# Tunnel up (on 1020), then the real test: the public URL in a browser
ssh devops@192.168.0.20 'systemctl is-active cloudflared'
```

All four green → the machines are done. From here on, **change VM state via the playbook, not by hand** ([the ownership boundary, 17.5](../operations/17-upgrades.md#175-the-same-pattern-applied-elsewhere)) — and continue with [Stage 10](../ha/10-replication.md), which replicates disks that now hold their real content.
