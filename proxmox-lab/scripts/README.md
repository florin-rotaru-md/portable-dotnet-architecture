# Proxmox helpers

[Operations](../OPERATIONS.md) · [Recovery](../RECOVERY.md) · [Build](../BUILD.md)

Scripts install on each Proxmox node in `/usr/local/sbin` without `.sh`; Python helpers install
alongside them. VM services/scripts are owned by Ansible in `native/`.

**Repository capability is not installed state.** On 2026-09-14 pve1 had the current
`pg-offsite` / `offsite-sync` chain, while pve2 did not. Reinstall the same reviewed version on both.
Follow [backup activation](../RECOVERY.md#backup-activation) before treating the schedule below as live.
Review `install-scripts.sh` before applying: it changes cron and replaces older backup scheduling.

| Command | Purpose | Schedule written by current installer |
|---|---|---|
| [cluster-health](cluster-health.sh) | Quorum, links, ZFS/disks, replication, HA/watchdog, versions and host measurements | Daily 07:07 |
| [backup-verify](backup-verify.sh) | Verify copies on encrypted offsite remote plus database archiver/spool | Daily 07:30 |
| [pve-config-backup](pve-config-backup.sh) | Archive host configuration and custom units/scripts; 14 local copies | Daily 02:40 |
| [pg-offsite](pg-offsite.sh) | Pull WAL; upload before removing VM spool; completed base/dump runs every 15 min | Every minute; `--now` forces full pass |
| [offsite-sync](offsite-sync.sh) | Upload VM images/config archives; apply offsite retention | Daily 05:00 |
| [node-return](node-return.sh) | Health, versions and replication catch-up before migration | Attended; `--check` is read-only |
| [restore-drill](restore-drill.sh) | Restore image into spare VM with NIC down, boot/agent proof, cleanup and measured RTO | Attended, quarterly and after backup changes |
| [create-vms](create-vms.sh) | Clone reviewed template into known VM IDs; size/address before boot | Attended build/recovery |
| [infra-report](infra-report.sh) | Wrap job output and publish structured evidence to app | Wrapper for four reporting cron jobs |
| [backup-retention.py](backup-retention.py) | Pure filename/age/retention calculations; no upload/delete | Called by backup scripts |

## Install and verify

1. Complete the [Digi account, capacity, host and rclone requirements](../RECOVERY.md#digi-storage-and-rclone)
   on both nodes. Preserve a protected recovery copy of the rclone and crypt secrets.
2. Prove `digi-crypt:` with the documented encrypted upload/download/delete check on both nodes.
3. Review the checked-out changes and apply the installer on each node within the relevant
   operations window. The installer does not install or configure rclone.
4. Inspect `/etc/cron.d/pve-helper-scripts` and installed helper versions on **both** nodes.
5. Confirm cron `PATH=/usr/sbin:/usr/bin:/sbin:/bin`. A missing external tool is a failed observation.
6. Run `pg-offsite --now`, `offsite-sync` and `backup-verify`; inspect logs and remote objects.
7. Prove an isolated restore/decryption and actual report receipt. Local send success does not prove
   recipient delivery.

`/etc/infra-report.conf` supplies `INFRA_URL`, `INFRA_TOKEN` and `INFRA_PEER_ADDRESS`. Keep it private.
The wrapper's exit code remains the job's exit code. Quiet mode still writes structured evidence;
an incomplete collector remains incomplete. Install all helper files as one version.

Health readings carry their timestamps and represent the scheduled sample. `SYNCING` is an in-flight
replication, not an error. Link 1 is optional/on-demand; Link 0 is required. Disk checks cover SATA
and NVMe. Missing commands, empty output and unreachable peers cannot establish a passing result.

Parser/retention verification from this directory:

```bash
python3 -B -m unittest discover -s tests -v
```
