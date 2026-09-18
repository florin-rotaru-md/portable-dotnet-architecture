# Native application provisioning

Ansible owns state **inside** the VMs: OS/packages, PostgreSQL, app slots, Nginx, cloudflared,
Alloy and optional Loki/Grafana. Proxmox hosts are covered by the [lab guide](../proxmox-lab/README.md).
The installed Waa/Fiscal applications, release procedure and current gaps are owned by
[platform operations](../../platform/docs/OPERATIONS.md).

## Inputs

Keep installation inventory outside this checkout. The committed examples define the supported inputs:

- [hosts.ini.example](infra/ansible/inventory/hosts.ini.example): host groups and connection settings.
- [main.yml.example](infra/ansible/inventory/group_vars/all/main.yml.example): applications and role options.
- [vault.yml.example](infra/ansible/inventory/group_vars/all/vault.yml.example): secret variable names.

On the control machine, prepare these files once; do not overwrite an existing installation inventory:

```bash
mkdir -p ~/app-inventory/group_vars/all
cd ~/src/portable-dotnet-architecture/native/infra/ansible
cp inventory/hosts.ini.example ~/app-inventory/hosts.ini
cp inventory/group_vars/all/main.yml.example ~/app-inventory/group_vars/all/main.yml
cp inventory/group_vars/all/vault.yml.example ~/app-inventory/group_vars/all/vault.yml
export ANSIBLE_INVENTORY=~/app-inventory/hosts.ini
```

Fill the host addresses, approved SSH identities, application list and secret values. Use an existing
administrative account for the initial bootstrap; subsequent runs use the configured `devops` account.
Confirm key-based access and sudo before hardening SSH. Vault encryption is optional in the tooling;
protect the inventory and recovery copy whether encrypted or plaintext. Never commit them.

| App input | Effect |
|---|---|
| `name`, `assembly`, `domain` | Runtime paths, .NET entry assembly and Nginx virtual host |
| `port_blue`, `port_green`, `drain_seconds` | Two loopback listeners and release overlap |
| `repo_url`, `repo_branch`, `project_path` | Initial source checkout and publish target |
| `repo_token` | Read-only repository credential, rendered privately for later deploys |
| `appsettings_override` | Rendered app configuration; application-specific layering still applies |
| `use_cloudflared`, `cloudflared_version` | Tunnel installation and explicit connector version |
| `use_loki_grafana`, `monitoring_target` | Optional logging services and their destination VM |

Read the example/role defaults for all optional variables rather than copying a production inventory
from a runbook. Budget PostgreSQL connections for both app slots during release, with room for
backup/admin work. A storage or RAM change does not change that budget automatically.

## Apply or release

Run from `native/infra/ansible` with the reviewed inventory selected:

```bash
# Inspect host changes first; treat any diff output as potentially sensitive.
ansible-playbook playbooks/bootstrap.yml --check --limit app
# Apply reviewed role/inventory changes to that host group.
ansible-playbook playbooks/bootstrap.yml --limit app
# Release application source to a selected app.
ansible-playbook playbooks/deploy.yml -e app=myapp
```

Use `--ask-vault-pass` when the selected inventory is encrypted. A complete initial bootstrap can
deploy every configured app automatically; verify the `applications` list and dependency order first.

An application definition carries its config bundle and repository token, and Ansible prints a
loop's `item` with every `assert` result and with any item that fails; `loop_control.label` only
shortens the header line. The validation and deploy tasks therefore loop over application names
or positions and look the definition up in a task variable. Role tasks that still loop over
`native_apps` print the whole definition when an item fails, and `-v` prints it always: treat the
output of a failed or verbose run as a credential, and keep new loops off the definitions.
Application code release and host configuration apply are different operations. Pulling this repository
alone updates neither installed templates nor services. App migrations create/update application
schemas; Ansible installs/tunes PostgreSQL and makes PostGIS available to new spatial databases.

## Runtime contract

`deploy.sh` publishes into the idle slot, starts it, polls `/.well-known/ready`, validates/reloads
Nginx, enables the serving slot, drains, then stops/disables the old slot. Exactly one slot per app
must be enabled after release. A freshly provisioned app has no enabled slot before first publish.

```text
/opt/apps/<app>/
  build/                    source checkout
  slots/{blue,green}/        published code
  env/{common,blue,green}.env
  config/                   override and private repo-token
  nginx/                    upstream templates
  runtime/active-slot
  runtime/deploy-history.log
  scripts/                  deploy, rollback, health-check, switch-nginx, current-slot
```

On the app VM, later deploys can use `sudo -u devops /opt/apps/<app>/scripts/deploy.sh`.
Token resolution is command argument → `APP_REPO_TOKEN` → private `config/repo-token`; prefer the
rendered file over command-line secrets. Reapply the app role after rotating its inventory token.
`rollback.sh` switches code slots; it does not undo schema changes or shared configuration. Use
the [release and rollback acceptance checks](../../platform/docs/OPERATIONS.md#release).

## Tunnel and logs

cloudflared runs with automatic update disabled. A reviewed version change plus role apply restarts
the connector; assess the interruption and verify externally afterwards. No incoming Internet port
is needed when all public ingress uses the tunnel.

Loki/Grafana default to loopback. With dedicated monitoring, bind Loki to the intended interface and
allow ingress only from the app hosts. Alloy reads application log files and pushes to the configured
endpoint; verify received logs rather than only active services. Persistent data lives under
`/opt/monitoring`. Do not expose Grafana publicly without the intended access boundary.
