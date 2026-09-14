# Backup and recovery

[Map](README.md) · [Operations](OPERATIONS.md) · [Fiscal recovery](../../platform/docs/fiscal/OPERATIONS.md#recovery)

## Coverage

Verification evidence on 2026-09-14:

| Layer | Observed | What it proves |
|---|---|---|
| ZFS replication | 1022 every minute, other guests hourly; last sync successful | Peer copy for node loss, subject to last completed sync |
| HA | 1021/1022 active with fencing | Restart orchestration; not recovery from corruption/deletion |
| Logical dumps | Nightly run is complete locally and on Digi | Scheduled backup works; isolated logical restore remains to be proved |
| VM images | All four guests are stored locally and on Digi; VM 1021 restored from Digi in isolation | Download, decryption, restore and boot/agent proof passed; application-level checks remain |
| WAL / PITR | `archive_mode=on`, `archive_timeout=1min`; 25 archived / 0 failed; newest WAL and verified base are on Digi | The source chain is active and offsite; an actual point-in-time restore remains to be proved |
| Digi Storage | Encrypted WAL/base/dumps, four VM images and both host configs pass `backup-verify` on pve1 and pve2 | Scheduled offsite coverage is active and readable from both nodes |
| rclone | `1.60.1-DEV`; `digi:` and `digi-crypt:` on both nodes; config owned by root, mode `0600` | The two-node storage prerequisite is complete |
| Offsite helpers | Same helper chain and schedule on both nodes | Either node can service the current VM owner; daily verification passes |
| VM image schedule | Enabled quarterly job for 1020-1023; one local and two Digi copies per VM | Periodic full-guest coverage is active |
| Host config | Current pve1 and pve2 archives are on Digi | Hand-managed host configuration has encrypted offsite coverage |
| Inventory/vault | Protected recovery copy outside the cluster confirmed during activation | Control-plane rebuild inputs are available independently |

Single-disk pools rely on peer copies for disk loss. Replication also propagates corruption or
deletion; it cannot replace an independent backup. Application objects stored outside PostgreSQL
need provider-side retention and recovery appropriate to each application.

## Digi Storage and rclone

### Account requirements

Use a dedicated, non-admin Digi Storage Business user for automation. Allocate enough of the 300 GB
group capacity to that user's private space before configuring rclone. A new Business user and the
group's Common Space start with zero capacity; the first admin user's private space initially owns
the full allocation. Common Space is writable by every group member, so use it only when shared
access is intentional. Keep a separate group admin able to reset the backup user and allocation.

Create a dedicated rclone application password for the backup user at
`https://storage.rcs-rds.ro/app/admin/preferences/password`. Do not use an operator's interactive
account password in cron. Store the username, application password, crypt password and crypt salt
in the protected recovery store outside the cluster. Losing the crypt password or salt makes the
offsite data unreadable.

The backup credential needs list, create, read, write and delete access because retention uses
`delete` and `purge`. Do not create public share links. Client-side crypt protects confidentiality
but cannot prevent a compromised node or credential from deleting the remote; this tier is offsite,
not immutable.

References: [Digi Storage Business](https://storage.rcs-rds.ro/help/business),
[Digi Storage with rclone](https://storage.rcs-rds.ro/help/rclone), and
[rclone's Digi backend](https://rclone.org/koofr/#digi-storage).

### Host requirements

Both pve1 and pve2 run the jobs as root and require the same working rclone configuration.

- Install rclone **1.58 or newer** for the dedicated Digi Storage API. On 2026-09-14 both nodes'
  configured Debian repositories offered `1.60.1+dfsg-4`, which satisfies this requirement. Keep
  the same reviewed version on both nodes; `rclone version` is part of installation evidence.
- Permit outbound DNS and HTTPS/TCP 443 to `storage.rcs-rds.ro`. System time and the CA trust store
  must be valid for TLS.
- Install `python3`, `rsync`, `openssh-client`, `coreutils` (`timeout`), `util-linux` (`flock`) and
  `ca-certificates`. Cron must include `/usr/sbin:/usr/bin:/sbin:/bin`. The audited nodes already
  had all required commands except rclone. Install the reviewed repository packages with:

  ```bash
  apt-get update
  apt-get install --yes rclone python3 rsync openssh-client coreutils util-linux ca-certificates
  rclone version
  ```
- Root must have enough local staging space under `/var/lib/vz/postgres` for an incoming PostgreSQL
  base backup plus retry data. `/var/lib/vz/dump` must hold the local VM image before upload.
- From the node owning VM 1022, `devops@192.168.0.22` must work non-interactively and `sudo -n`
  must permit the `find`, `rsync` and settled-WAL removal used by `pg-offsite`.
- `rclone config file` must identify `/root/.config/rclone/rclone.conf`, owned by root with mode
  `0600`. rclone only obscures stored passwords; that file is a credential. Do not set a separate
  rclone configuration password: unattended cron would then require another secret through
  `RCLONE_CONFIG_PASS`. Keep a protected recovery copy of the file instead.

No mount or FUSE package is required. The scripts use rclone's CLI directly.

### Remote configuration

Use rclone's dedicated Digi Storage provider. Run `rclone config` on a secured node and create:

| Remote | Selection | Required values |
|---|---|---|
| `digi` | `koofr` → provider `digistorage` | Backup username and its rclone application password |
| `digi-crypt` | `crypt` | Underlying path `digi:OperationalBackup`, standard filename encryption, directory encryption enabled, unique password and salt |

The dedicated provider selects the account's primary storage automatically; do not add a `Digi
Cloud` path component. Create the empty `digi:OperationalBackup` container once, then read and write
backup content only through `digi-crypt:`. Configure pve2 with the same underlying path, crypt
password, salt and filename settings; a newly generated crypt config cannot read pve1's data.
Reference: [rclone crypt](https://rclone.org/crypt/).

#### Configure `digi` on pve1

Before starting, allocate capacity to the backup user and generate an application password at
`https://storage.rcs-rds.ro/app/admin/preferences/password`. Store the username and application
password in the protected recovery store. Run the following as root on pve1:

```bash
install -d -m 700 /root/.config/rclone
rclone config
```

Use the text values below instead of numeric menu positions; numeric positions can change between
rclone versions:

```text
n/s/q> n
name> digi
Storage> koofr
provider> digistorage
user> <DIGI_BACKUP_USERNAME>
y/g> y
password> <DIGI_RCLONE_APPLICATION_PASSWORD>
password> <DIGI_RCLONE_APPLICATION_PASSWORD>
Edit advanced config? y/n> n
y/e/d> y
```

The two `password>` entries are the password and confirmation prompts. Do not choose `s` from the
main menu and do not set `endpoint` or `mountid`. Confirm the underlying remote before creating the
encrypted layer:

The trailing colon is mandatory in every remote path: `digi:` means the configured remote, while
`digi` means a local directory named `digi`.

```bash
rclone listremotes
rclone lsd digi:
rclone about digi:
```

#### Configure `digi-crypt` on pve1

Run `rclone config` again and use these values:

```text
e/n/d/r/c/s/q> n
name> digi-crypt
Storage> crypt
remote> digi:OperationalBackup
filename_encryption> standard
directory_name_encryption> true
y/g> g
Bits> 128
Use this password? y/n> y
y/g/n> g
Bits> 128
Use this password? y/n> y
Edit advanced config? y/n> n
y/e/d> y
e/n/d/r/c/s/q> q
```

The first generated value is the crypt password; the second is `password2`, the crypt salt. Copy
both displayed values immediately into the protected recovery store. They are required to decrypt
the backup if `rclone.conf` is lost. Keep data encryption enabled; the advanced default
`no_data_encryption = false` must not be changed.

Create the empty container before its first listing. Without this step, `rclone lsf digi-crypt:`
returns `directory not found` even when both remotes are configured correctly:

```bash
rclone mkdir digi:OperationalBackup
rclone lsf --max-depth 1 digi-crypt:
```

The effective configuration must have the values below; rclone may omit lines that use their
defaults. Password fields are stored obscured:

```ini
[digi]
type = koofr
provider = digistorage
user = <DIGI_BACKUP_USERNAME>
password = <OBSCURED_APPLICATION_PASSWORD>

[digi-crypt]
type = crypt
remote = digi:OperationalBackup
filename_encryption = standard
directory_name_encryption = true
password = <OBSCURED_CRYPT_PASSWORD>
password2 = <OBSCURED_CRYPT_SALT>
```

Do not paste the real values into documentation, tickets or shell commands. Apply permissions and
copy the complete configuration to pve2 so both nodes use exactly the same encryption keys:

```bash
chown root:root /root/.config/rclone/rclone.conf
chmod 600 /root/.config/rclone/rclone.conf

ssh root@192.168.0.12 'install -d -m 700 /root/.config/rclone'
scp /root/.config/rclone/rclone.conf root@192.168.0.12:/root/.config/rclone/rclone.conf
ssh root@192.168.0.12 \
  'chown root:root /root/.config/rclone/rclone.conf && chmod 600 /root/.config/rclone/rclone.conf'
```

Run the [acceptance](#acceptance) commands on pve1 and pve2 after the copy.

### Capacity requirement

Budget the remote before enabling scheduled uploads:

```text
2 * sum(latest compressed image of each VM)
+ 4 * compressed PostgreSQL base backup
+ 30 days of logical dumps
+ WAL from the oldest retained base
+ 30 days of host configuration archives
+ one largest in-flight upload
```

Keep at least 20% of the provider allocation free after the retained set. The contracted plan is
marketed as 300 GB, while `rclone about digi:` reports 300 GiB; use a 240 GiB operational ceiling
against that reported allocation. On 2026-09-14 the four live ZFS volumes referenced about 14.4 GB
and the existing compressed 1022 image was 1.34 GB. This indicates ample current headroom but does
not bound future database/media growth. Check the allocation with `rclone about digi:` and the
encrypted footprint with `rclone size digi-crypt:`.

The Digi backend is case-insensitive. Backup names must remain unique without relying on case.

### Acceptance

Complete on **both** nodes before installing the schedules:

```bash
(
  set -euo pipefail

  probe=$(mktemp)
  restored=$(mktemp)
  remote_probe="checks/$(hostname)-$(date +%s).bin"
  cleanup() {
    rclone deletefile "digi-crypt:$remote_probe" >/dev/null 2>&1 || true
    rm -f "$probe" "$restored"
  }
  trap cleanup EXIT

  rclone version
  rclone config file
  rclone listremotes
  rclone lsd digi:
  rclone about digi:
  rclone mkdir digi:OperationalBackup
  rclone lsf --max-depth 1 digi-crypt:

  head -c 1048576 /dev/urandom > "$probe"
  rclone copyto "$probe" "digi-crypt:$remote_probe"
  rclone copyto "digi-crypt:$remote_probe" "$restored"
  cmp "$probe" "$restored"
  rclone deletefile "digi-crypt:$remote_probe"

  trap - EXIT
  rm -f "$probe" "$restored"
  echo "PASS: encrypted Digi round trip and deletion"
)
```

Expect `digi:` and `digi-crypt:` exactly in `listremotes`, successful listing, recorded
allocated/free capacity, a byte-identical round trip and successful deletion. Confirm that the
plaintext probe name and contents are absent when inspecting `digi:OperationalBackup`. Record
rclone version, account allocation, configuration-file permissions and results without recording
credentials.

## Backup provisioning and rebuild

Use this sequence to rebuild the backup chain or to activate it in a replacement environment. In
current production it is complete through the VM restore drill. Enabling WAL restarts PostgreSQL;
the current role can also install the latest minor package available from PGDG. Confirm application
readiness after the playbook.

### 1. Protect the recovery inputs

Store these outside the cluster before changing PostgreSQL:

- `/root/.config/rclone/rclone.conf` from either node;
- clear crypt password and salt recorded during configuration;
- `/home/devops/app-inventory`, including its vault;
- host/root SSH recovery keys.

Do not print or commit their contents.

### 2. Install the same helper version on both nodes

Copy the reviewed `proxmox-lab/scripts` directory to each node and run as root from that directory:

```bash
./install-scripts.sh
```

The installer replaces `/etc/cron.d/pve-helper-scripts`. Verify on **both** pve1 and pve2:

```bash
command -v pg-offsite offsite-sync backup-verify pve-config-backup
grep -E 'pg-offsite|offsite-sync|backup-verify|pve-config-backup' \
  /etc/cron.d/pve-helper-scripts
ssh -o BatchMode=yes devops@192.168.0.22 \
  'sudo -n find /opt/postgres/backups -maxdepth 0 -type d -printf ok && sudo -n rsync --version >/dev/null'
```

The last command must print `ok` from each node. `/etc/infra-report.conf` is already present on both
audited nodes. Keep this step immediately before the PostgreSQL apply: until WAL is enabled, the
new `pg-offsite` cron can report that its source spool is absent.

### 3. Enable PostgreSQL WAL and base backups

On control (`192.168.0.20`), edit
`/home/devops/app-inventory/group_vars/all/main.yml` and set:

```yaml
postgres_wal_archive_enabled: true
postgres_archive_timeout: 60
postgres_wal_spool_max_mb: 20480
postgres_basebackup_weekday: "0"
postgres_basebackup_hour: "2"
postgres_basebackup_minute: "45"
```

The VM has about 989 GB free, so the 20 GB spool cap and initial base backup fit the current host.
Keep the existing logical dump schedule at 00:15. Apply from the reviewed checkout on control:

```bash
cd /home/devops/src/portable-dotnet-architecture/native/infra/ansible
export ANSIBLE_INVENTORY=/home/devops/app-inventory/hosts.ini
ansible-playbook playbooks/bootstrap.yml --check --limit postgres --tags postgres
ansible-playbook playbooks/bootstrap.yml         --limit postgres --tags postgres
```

Add `--ask-vault-pass` to both commands when the inventory vault is encrypted. After the apply,
confirm application readiness, then verify on VM 1022:

```bash
sudo -u postgres psql -XAt -c 'show archive_mode;'
sudo -u postgres psql -XAt -c 'show archive_timeout;'
sudo -u postgres psql -XAt -c 'show archive_command;'
sudo -u postgres crontab -l
sudo -u postgres psql -XAt -c 'select pg_switch_wal();'
sudo find /opt/postgres/wal-spool -maxdepth 1 -type f -name '*.zst' -printf '%f\n'
sudo -u postgres psql -XAt -c \
  'select archived_count, failed_count, coalesce(last_archived_wal, chr(45)), coalesce(last_failed_wal, chr(45)) from pg_stat_archiver;'
sudo -u postgres sh -c 'cd / && exec /opt/postgres/scripts/pg-basebackup.sh'
```

Required results: `archive_mode=on`, `archive_timeout=1min`, the managed archive command, nightly
logical cron, weekly base cron, at least one compressed WAL file and a completed base directory
with `backup_manifest`.

### 4. Seed the PostgreSQL offsite tier

VM 1022 currently runs on pve1. Run there:

```bash
pg-offsite --now
tail -n 100 /var/log/pg-offsite.log
rclone lsf --recursive digi-crypt:postgres
```

Require a WAL object, a complete base under `postgres/base/` and the latest complete logical dump
run under `postgres/logical/`. `pg-offsite` must upload a WAL file before removing it from the VM
spool. When VM 1022 moves, run this command on its new owner; cron is installed on both nodes and
the non-owner exits without work.

### 5. Schedule and seed VM images

Create or verify this job from either Proxmox node:

```bash
pvesh create /cluster/backup \
  --id quarterly-local-images \
  --schedule '*-1,4,7,10-01 03:30' \
  --storage local \
  --vmid 1020,1021,1022,1023 \
  --mode snapshot \
  --compress zstd \
  --prune-backups 'keep-last=1' \
  --enabled 1
pvesh get /cluster/backup --output-format yaml
```

The schedule is 03:30 on 1 January, April, July and October; its syntax was accepted by the live
Proxmox parser. Run the job once immediately from **Datacenter -> Backup -> Run now** and require a
successful image for all four VMs. The job keeps one local image per VM; `offsite-sync` keeps the
newest two per VM on Digi.

### 6. Upload images and host configuration

Run on pve1 and pve2 after the initial VM job completes:

```bash
pve-config-backup
offsite-sync
```

Then verify the remote inventory from either node:

```bash
rclone lsf --recursive digi-crypt:vzdump
rclone lsf --recursive digi-crypt:config
rclone size digi-crypt:
```

### 7. Close activation with verification and restore

Run on both nodes:

```bash
backup-verify
```

Every check must be `[ OK ]`. A missing tier is not accepted as an initial warning. Finally, run on
a node without a local copy of the target image (`pve2` in the current topology):

```bash
image=$(rclone lsf --files-only digi-crypt:vzdump \
  | grep '^vzdump-qemu-1021-.*\.vma\.zst$' | sort | tail -1)
test -n "$image"
rclone copyto "digi-crypt:vzdump/$image" "/var/lib/vz/dump/$image"
restore-drill 1021
rm -f "/var/lib/vz/dump/$image"
```

This proves remote download/decryption as well as an isolated VM restore. The remaining proofs are
an isolated logical database restore, an actual PITR replay and the Fiscal counter/key-ring procedure.

Target responsibilities in code:

| Script / role | Responsibility |
|---|---|
| Native postgres role | Logical dumps/globals, WAL archive spool and base backup settings |
| `pg-offsite` | WAL plus completed bases/dump runs from the node owning 1022 to encrypted remote |
| `offsite-sync` | Node VM/config archives and remote retention |
| `pve-config-backup` | Hand-managed host configuration and custom scripts/units |
| `backup-verify` | Freshness/completeness checks with explicit missing-tool/remote failures |

Read the scripts/config for precise cadence, paths and retention; do not maintain a second schedule
table. Keep source and installed versions aligned deliberately.

## Database restore

Choose the last independently verified backup and the accepted loss window. On a rebuilt cluster
restore required globals/roles, then every app's database and its DataProtection database; users
databases are separate where present. Use `pg_restore --exit-on-error`, inspect logs and verify
ownership/extensions/schema, not just process exit status.

Restore into an isolated database/VM first. Disable external mail, payments, ANAF/accounting and
all work queues that can affect production. Do not attach production credentials/networking to a
scratch clone. Validate representative reads, decryption and current migrations before cutover.

For Fiscal, follow the [counter and key-ring procedure](../../platform/docs/fiscal/OPERATIONS.md#recovery).
Never rely on `StartNumber` or a fresh migration to restore legal numbering. `fiscal_dp` must
contain the keys used by `fiscal_app`; a newer ring retains old decryption keys, an older ring may not.

PITR additionally requires a usable base older than the target and an unbroken WAL chain. Keep
recovery isolated, set the explicit target and inspect whether replay reached it. The production
source chain is active and offsite, but PITR recovery is not proved until that replay succeeds.

## VM or node loss

For a node failure, establish which node owns the surviving state and whether fencing completed.
Allow HA to recover 1021/1022; recover control/monitoring manually if needed. Check PostgreSQL crash
recovery, applications and last replicated state. Do not start the same guest on both nodes.

For archive restoration, use a spare VM ID and isolated network. `restore-drill` supports the
guest-level rehearsal; inspect its help/options before running. A successful boot/guest agent
is only the first gate. Then prove DB, key-ring, fiscal counter, object and application behavior.

Restore encrypted offsite archives using independently stored crypt credentials. Test that a
fresh recovery machine can read them; credentials cached on the failed environment prove nothing.

For replacement hardware: drain/isolate the old node, preserve current cluster configuration and
disk identity, and ensure the removed node cannot rejoin unexpectedly. Use a clean replacement
join with matching network/pool names. If transplanting disks, identify boot/apps/db by model and
serial, import deliberately and check interface/firmware settings before booting guests.

## Forced quorum

Use only after independently proving the other node is powered off or isolated and cannot write
the same guest storage. This is an emergency recovery decision, never a routine QDevice workaround.
The emergency command is `pvecm expected 1` on the sole surviving owner. Restore normal membership
and expected votes before allowing the peer back. If peer state is uncertain, do not force quorum.

## Credentials

Keep workstation, host-root and break-glass private keys in protected recovery storage outside
the cluster. The controller's own Ansible key can be recovered from its protected backup or
re-issued through a trusted host/console. Never replace an existing recoverable identity unnecessarily.

Cloud-init seeds access once; the native common role owns ongoing authorized-key reconciliation.
Before enabling exclusive reconciliation, include both host keys and all intended recovery paths.
Test a second login before revoking the old one. Keep console access available during SSH changes.

Back up the inventory/vault pair with restricted access; plaintext remains plaintext even when
the file is named `vault.yml`. Include edge, object-storage, DB, repository and integration recovery
material. Host config archives can carry signing keys; encrypt them outside the host.

## Drill acceptance

Record results in the team's operational system, with artifact, recovery point, elapsed time and
remaining limitations. A completed drill requires:

- Independent backup/crypt/SSH access from the recovery environment.
- Isolated guest boot, unique network identity and no accidental production sends.
- DB ownership/extensions/migrations and app/users/DP recovery.
- Fiscal counter comparison, decryption, same-number PDF reproduction and safe queue reconciliation.
- Restored object access and expected public/private boundaries.
- Application/API/edge checks and verified notification delivery.

Destructive failover/fencing drills need an explicit maintenance window and current recoverable
copies. The two-to-three-minute recovery estimate from the design is not a measured guarantee for
the current data/workload; measure it in the drill.
