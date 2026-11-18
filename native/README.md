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
| `repo_url`, `repo_branch`, `project_path` | GitHub repository (`https://github.com/<owner>/<repository>.git`), branch and publish target |
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
# Release application source to a selected app: its branch's tip, or the one commit a release names.
ansible-playbook playbooks/deploy.yml -e app=myapp
ansible-playbook playbooks/deploy.yml -e app=myapp -e commit=<full hash>
#   A release of several apps names its commit once: a push made while it runs cannot then give
#   two of them different source.
```

Use `--ask-vault-pass` when the selected inventory is encrypted. A complete initial bootstrap can
deploy every configured app automatically; verify the `applications` list and dependency order first.

An application definition carries its config bundle, and Ansible prints a
loop's `item` with every `assert` result and with any item that fails; `loop_control.label` only
shortens the header line. The validation and deploy tasks therefore loop over application names
or positions and look the definition up in a task variable. Role tasks that still loop over
`native_apps` print the whole definition when an item fails, and `-v` prints it always: treat the
output of a failed or verbose run as a credential, and keep new loops off the definitions.
Application code release and host configuration apply are different operations. Pulling this repository
alone updates neither installed templates nor services. App migrations create/update application
schemas; Ansible installs/tunes PostgreSQL and makes PostGIS available to new spatial databases.

## Runtime contract

`deploy.sh` first asserts local name resolution (below), then publishes into the idle slot, copies
the override into it, starts it, polls `/.well-known/ready`, validates/reloads Nginx, enables the
serving slot, drains, then stops/disables the old slot. Exactly one slot per app must be enabled
after release. A freshly provisioned app has no enabled slot before first publish. One `deploy.sh`
runs per app at a time (`runtime/deploy.lock`).

A changed override or env file takes the same path. The app role writes `config/` and `env/` and
ends with `deploy.sh --config-only`, which copies the live build into the idle slot and starts it
under the new files. A configuration the app refuses fails the run and leaves the serving slot as
it was; the change stays pending and the next run takes it up again. A slot's override is written
only while that slot is stopped: the hosts reload the file when it changes, so a copy written under
the serving process would reach users unchecked. `runtime/config-live.sha256` is the fingerprint of
the override and env files the serving slot was started with, and
`deploy.sh --config-only --check` says whether the files on disk differ from it.

```text
/opt/apps/<app>/
  build/                    source checkout
  slots/{blue,green}/        published code, the override it was started with, release-commit
  env/{common,blue,green}.env
  config/                   override and optional config bundle
  nginx/                    upstream templates
  runtime/active-slot
  runtime/config-live.sha256
  runtime/deploy-history.log
  scripts/                  deploy, rollback, health-check, switch-nginx, current-slot
/opt/apps/deploy-keys/      host-wide: a deploy key per repository, GitHub's host key, SSH options
/usr/local/sbin/ensure-local-domains   host-wide; rendered by the nginx role
/etc/systemd/system/ensure-local-domains.service   runs it at boot
```

On the app VM, later deploys can use `sudo -u devops /opt/apps/<app>/scripts/deploy.sh`.
`rollback.sh` switches to the other slot as it was last started: the previous build after a deploy,
the same build under its previous override after a configuration change. It does not undo schema
changes, and it clears the fingerprint, so the next run of the app role applies the inventory's
configuration again. Use
the [release and rollback acceptance checks](../../platform/docs/OPERATIONS.md#release).

### Repository access

The app VM reads each repository over SSH with a GitHub deploy key of its own. The app role
generates it at `/opt/apps/deploy-keys/<owner>/<repository>`: read-only on GitHub's side, valid
for that one repository, never copied off the VM and absent from the inventory. `ssh_config` in
the same directory holds every SSH option a fetch uses, and `known_hosts` pins GitHub's host key
(`github_ssh_host_key` in the role defaults); a deploy refuses any other.

GitHub is given the public half once per key: repository → Settings → Deploy keys → Add deploy
key, with "Allow write access" unchecked. The role reads each repository on every run and prints
the key of one it could not read, with the address to add it at;
`bootstrap.yml --limit app --tags deploy-key` runs that part alone. A deploy that cannot read its
repository stops before it touches a slot and prints the same key.

```bash
# On the app VM: which repository GitHub takes this key for.
sudo -u devops ssh -F /opt/apps/deploy-keys/ssh_config -i /opt/apps/deploy-keys/<owner>/<repository> -T git@github.com
```

A rebuilt VM generates new keys: its first bootstrap prints them and stops at the initial deploy
until GitHub has them; the keys of the VM it replaces are then deleted on GitHub by hand. To
replace a key, delete its two files on the VM, run the tag, add the new key and delete the old one
on GitHub.

### Local name resolution

An app that a sibling addresses by name declares `resolve_locally: true`; today that is `fiscal`,
which both Waa APIs reach at `http://fiscal.waa.ro/`. Its domain must resolve to `127.0.0.1` on the
app VM. Otherwise the name resolves to Cloudflare. The Waa client then refuses to connect: it only
connects to loopback or private addresses and never follows a redirect
([wire contract](../../platform/docs/fiscal/ARCHITECTURE.md#wire-contract)). Invoicing waits as an
outage until the name resolves locally again. Before that client guard, the API key crossed a
plaintext hop to the edge and a POST followed the edge's 301 as a GET.

`/usr/local/sbin/ensure-local-domains` owns that block in `/etc/hosts`. It prints `written` or
`unchanged`, and it fails when the name still resolves elsewhere. The nginx role renders it and
runs it three ways:

- at every boot, through `ensure-local-domains.service`;
- on every bootstrap;
- from every `deploy.sh`, before building. A deploy stops when the script is missing; render it
  with `bootstrap.yml --tags nginx`.

The boot run exists because cloud-init regenerates `/etc/hosts` from its template at every boot.
`manage_etc_hosts: true` comes from Proxmox's NoCloud user-data. User-data outranks
`/etc/cloud/cloud.cfg.d/`, so a drop-in inside the VM cannot turn it off. Before the unit existed,
the 2026-10-09 package-update reboot dropped the block, and that went unnoticed until 2026-10-21.

The unit runs after cloud-init's init stage (`cloud-init-network.service`), which is where
`update_etc_hosts` rewrites the file. It runs before every app slot unit. It only orders and does
not block: a failed run leaves the slots to start and is in `journalctl -u ensure-local-domains -b`.

Alternatives that were not chosen:

- `manage_etc_hosts: false` in a custom Proxmox user-data (`qm set --cicustom`). It is a host-side
  change, lost when the cloud-init drive is regenerated.
- The block in `/etc/cloud/templates/hosts.debian.tmpl`. That keeps a second copy of the list.

## Tunnel and logs

cloudflared runs with automatic update disabled. A reviewed version change plus role apply restarts
the connector; assess the interruption and verify externally afterwards. No incoming Internet port
is needed when all public ingress uses the tunnel.

Loki/Grafana default to loopback. With dedicated monitoring, bind Loki to the intended interface and
allow ingress only from the app hosts. Alloy reads application log files and pushes to the configured
endpoint; verify received logs rather than only active services. Persistent data lives under
`/opt/monitoring`. Do not expose Grafana publicly without the intended access boundary.
