# Backup and recovery

[Map](README.md) · [Operations](OPERATIONS.md) · [Fiscal recovery](../../platform/docs/fiscal/OPERATIONS.md#recovery)

## Coverage

Verification evidence on 2026-09-14:

| Layer | Observed | What it proves |
|---|---|---|
| ZFS replication | 1022 every minute, other guests hourly; last sync successful | Peer copy for node loss, subject to last completed sync |
| HA | 1021/1022 active with fencing | Restart orchestration; not recovery from corruption/deletion |
| Logical dumps | PostgreSQL user's cron at 05:15; recent files under `/opt/postgres/backups` | Local backup files exist; restore still needs verification |
| VM image | Local 1022 archive dated 2026-09-13 on pve1 | One image exists, not complete fleet/offsite coverage |
| WAL / PITR | `archive_mode=off`, `archive_timeout=0`, zero archived WAL | Continuous replay/PITR is unavailable in this installation |
| Digi Storage | Business plan acquired; `rclone about digi:` on pve1 reports 300 GiB total/free | Account allocation and underlying access work on pve1; encrypted acceptance and restore remain open |
| rclone | pve1: `1.60.1-DEV`, `digi:` and `digi-crypt:` configured; pve2 not configured | One-node setup only; scheduled two-node workflow is not active |
| New offsite helpers | `pg-offsite` and `offsite-sync` absent from installed helper list | Repository workflow has not been installed on audited nodes |
| R2 | Older `r2-backup` helper/cron still installed; no validated copy/restoration | Do not claim R2 backup coverage |
| Host config | Archive helper/cron present | Job installation, not successful/decryptable offsite recovery |
| Inventory/vault | Plaintext on control; protected external copy not verified | Treat recovery as an open prerequisite |

The repository's newer inventory/scripts describe a target backup system. They do not establish
that it is running. Recheck this table after activation and an isolated restore, replacing the
current state rather than appending a history.

Single-disk pools rely on peer copies for disk loss. Replication also propagates corruption or
deletion; it cannot replace an independent backup. R2 document markers live outside PostgreSQL but
are not an independent backup of their own bucket.

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

## Backup activation

Apply as a separate planned infrastructure change:

1. Secure external recovery credentials and a protected copy of the installation inventory.
2. Satisfy [Digi Storage and rclone](#digi-storage-and-rclone) on both nodes, including capacity
   allocation and the encrypted round trip. Do not print config secrets.
3. Review/apply native PostgreSQL archive/base/dump settings. This can require a database restart.
   Verify runtime `archive_mode`, spool capacity and successful WAL archiving after real writes.
4. Review/install current helper scripts on both nodes. `install-scripts.sh` changes cron and
   removes the older R2 backup helper; it is not a read-only validation command.
5. Verify the owner-following `pg-offsite` job, complete base/dump transfers and WAL upload before
   local release. Verify `offsite-sync` for VM/config archives and the configured retention.
6. Configure/check the intended VM image cadence. The presence of a helper does not create a
   scheduled `vzdump` job. Staging capacity must fit the chosen images.
7. Run `backup-verify` and inspect actual remote timestamps/counts. Restore/decrypt an external
   copy into an isolated guest; prove application and fiscal recovery before declaring coverage.
8. Decide and implement a separate R2 backup strategy if required; the new offsite scripts do not
   claim to back up those buckets.

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
recovery isolated, set the explicit target and inspect whether replay reached it. It is **not
available in the verified installation**. A base/WAL directory in a template cannot replace that chain.

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
the file is named `vault.yml`. Include Cloudflare, R2, DB, repository and integration recovery
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
