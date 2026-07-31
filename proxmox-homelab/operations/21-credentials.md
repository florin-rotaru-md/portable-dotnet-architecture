# Stage 21 — Credentials & key management

*Part of the [Proxmox homelab guide](../README.md).*

Everything before this stage assumes you can log in. Replication, HA, backups, restores — all of it is theater if the day you need it is also the day you discover the only key was on the machine that died. This stage is the inventory of what exists, where each piece lives, and what recovery looks like when one of them is gone.

## 21.1 Inventory — what exists and where it lives

Three kinds of SSH material, easy to conflate, with completely different loss profiles:

| What | Where it lives | What it is | If lost |
|---|---|---|---|
| **Your workstation's private key** (`~/.ssh/id_ed25519`) | Your PC | **Your identity.** Opens whatever it's authorized on | You knock on other doors (21.5) |
| **control-ubuntu's private key** (`~/.ssh/id_ed25519_devops`) | VM 1020 | **Ansible's identity.** Every playbook run flows through it | Config management stops until restored |
| **pve1 root's private key** (`/root/.ssh/id_ed25519`) | pve1 | Injected via `--sshkeys` ([9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)) → opens **every VM** | One less recovery path; also: guard this one, it's a skeleton key |
| **Public keys** in `~/.ssh/authorized_keys` | Each VM's disk | **The locks, not the keys.** Travel with the disk: replicated by Stage 12, backed up by Stage 17 | Nothing — regenerate from the role |
| **Host keys** (`/etc/ssh/ssh_host_*`) | Each VM's disk | The **server's** identity toward you — they never authenticate *you*. The cloud image ships without them (and the ISO route strips them, [9.8e](../vms/09-ubuntu-template.md#98-the-alternative-interactive-iso-install)), so every clone generates unique ones at first boot | Nothing — regenerated automatically |

And the non-SSH credentials, which get less attention and hurt more:

| Credential | Protects | Kept where |
|---|---|---|
| Proxmox root password (×2 nodes) | The hypervisors, web UI and console | Password manager |
| VM `--cipassword` | The console login — the no-SSH recovery path (21.4) | Password manager |
| rclone crypt passwords | The **entire offsite tier** ([17.6](../backup/17-backup-restore.md#176-offsite--digi-storage-via-rclone)) | Password manager **+ paper** |
| `vault.yml` contents (postgres password, tokens, `grafana_admin_password`) — and the vault password if encrypted | The application layer | Repo (encrypted) + password manager |
| `walreceiver` password | The WAL stream to the QDevice ([13](../ha/13-wal-stream.md)) — replication-only role, no data access; loss = recreate it and update the QDevice's `.pgpass`, a non-event | vault.yml + password manager |

## 21.2 What a restore actually gives back

The question that motivates this stage: *after a `qmrestore`, do I still get in?*

**Yes, with nothing to reconfigure.** vzdump restores the disk bit for bit, and `authorized_keys` is a file on that disk — the restored VM accepts exactly the keys the original did. The original host keys come back too, so you don't even get the `REMOTE HOST IDENTIFICATION HAS CHANGED` warning. Access survives restore for free.

One nuance: restoring **alongside** the original into a new VM ID ([17.7 A](../backup/17-backup-restore.md#a-restore-into-a-new-vm-id-safest--start-here)) means two machines now hold the same host keys and the same locks. Fine for a disposable inspection VM with its NIC disconnected; wrong for anything that stays. A clone meant to *live* should go through the template path, where host keys are stripped.

## 21.3 The rule: recovery credentials must live outside the thing they recover

This is the trap that matters more than any single key:

> If the only copy of the private key sits on control-ubuntu, and control-ubuntu sits inside an encrypted backup on Digi Storage, you need the key to reach the key. If the rclone crypt passwords exist only inside the lab, the offsite backup is mathematically unrecoverable in **exactly** the scenario it exists for — house gone, lab gone, passwords gone with it.

Circular recovery dependencies are invisible until the day they bite, because every partial failure still works — only the total one doesn't. So audit for the cycle, not for the copies.

**The minimum that must exist outside the lab** — password manager, plus ideally a paper copy somewhere physically separate:

1. **SSH private keys** — workstation + `id_ed25519_devops` (or at least one break-glass key, 21.6)
2. **rclone crypt passwords** — [17.6](../backup/17-backup-restore.md#176-offsite--digi-storage-via-rclone) already says this; it bears repeating because it's load-bearing
3. **Proxmox root passwords** — both nodes
4. **The VM `--cipassword`** — the one most people miss, and the subject of 21.4

If `vault.yml` is ansible-vault-encrypted, its password joins the list — same logic, smaller blast radius (everything in it can be re-issued; painful, not fatal).

## 21.4 The console is the final safety net — give it a password

If the VMs are key-only and every key is lost, SSH is a wall. But the Proxmox console doesn't depend on SSH at all — it's a virtual keyboard plugged into the VM. It only helps if there's a password to type into it.

That's what `--cipassword` on the template ([9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)) is for: one strong password, set once, inherited by every clone, stored in the password manager. For VMs cloned before it was set:

```bash
qm set 1021 --cipassword '<strong password>'     # per VM; takes effect next boot
```

(the config change regenerates the cloud-init drive and re-triggers per-instance config — a reboot applies it; while SSH still works, `sudo passwd devops` inside the guest does it immediately)

Two properties worth being precise about:

- **It does not weaken SSH.** cloud-init tends to flip `ssh_pwauth` on when a password is set — which would quietly turn "console safety net" into "password-guessable SSH". The `common` role forecloses this: `/etc/ssh/sshd_config.d/99-key-only.conf` pins `PasswordAuthentication no`. The password works at the console, and nowhere else.
- **Without it, recovery still exists — barely.** The hypervisor can always mount the VM's disk (zvol → partition mapping → LVM activation → edit `authorized_keys` by hand). It works. It is also fiddly, error-prone root-level surgery on your database VM's disk, performed on precisely the day everything else already went wrong. A password in a password manager is the same outcome with none of the drama.

## 21.5 Recovery scenarios — what losing each thing actually means

| You lost | Still working | The way back |
|---|---|---|
| **Workstation key** | control-ubuntu's key, pve1 root's key | Get in via the control VM or pve1. Generate a new pair, add the public key to `ansible_ssh_extra_public_keys`, run the playbook. Remove the old one from the list (21.6) |
| **control-ubuntu** (the VM or its key) | Your workstation key, pve1 root's key | Restore VM 1020 from backup — its key is on the restored disk (21.2). Or rebuild it and restore `id_ed25519_devops` from the password manager |
| **Every SSH key at once** | The Proxmox console + `--cipassword` | Log in on the console, re-seed `authorized_keys`, then rotate everything deliberately |
| **Every SSH key, and no cipassword** | The hypervisor's access to the disk | Mount the zvol from pve1/pve2 and edit `authorized_keys` manually (21.4). Set the cipassword right after |
| **Proxmox root password** | Physical access | Standard Debian recovery: boot with `init=/bin/bash` from GRUB, `passwd`, reboot. Then store it properly |
| **rclone crypt passwords** | Local tiers (replication, USB) — unaffected | The existing offsite data is **gone** — that's the design. New crypt config, new passwords, full re-sync, paper copy this time |
| **ansible-vault password** | Everything currently running | `vault.yml` is unrecoverable; re-issue its contents — reset `postgres_password` via `psql` as the `postgres` user, re-issue API tokens, re-encrypt |
| **The cipassword** | Everything — SSH is unaffected | `qm set <id> --cipassword` + reboot. Non-event, if SSH still works |

The pattern across every row: **each credential's recovery path runs through a *different* credential.** That's the property to preserve when you change anything about this setup — never let two of these collapse into one.

## 21.6 Two habits that make key loss boring

**1. At least two authorized keys per VM.** One key is a single point of failure with perfect uptime until it isn't. The `common` role takes a list:

```yaml
# group_vars / vault.yml
ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_devops.pub') }}"
ansible_ssh_extra_public_keys:
  - "ssh-ed25519 AAAA... workstation"
  - "ssh-ed25519 AAAA... break-glass"
```

The break-glass pair is generated once, offline, and its private half never touches a lab machine:

```bash
ssh-keygen -t ed25519 -C "break-glass" -f ./id_ed25519_breakglass
# public half  → ansible_ssh_extra_public_keys
# private half + passphrase → password manager + paper, then delete the local file
```

**2. `authorized_keys` belongs to Ansible, not to hands.** The role manages the full list declaratively: it applies identically to new VMs and restored ones, and a key added by hand on one VM is drift waiting to confuse you. Once every key you rely on is in the list, flip the lock:

```yaml
ssh_authorized_keys_exclusive: true
```

From then on, keys **not** in the list are removed on the next run — rotating a compromised key is *delete the line, run the playbook*, across every VM at once. This is the same ownership boundary as [20.5](20-upgrades.md#205-the-same-pattern-applied-elsewhere): the template's `--sshkeys` matters exactly once, at first boot; after that, Ansible owns the file.

> Don't enable `exclusive` before the list is complete — it removes keys, that's its job. Check what's actually authorized first: `ansible all -m command -a 'cat ~/.ssh/authorized_keys' -b --become-user devops`, reconcile against the list, then flip.
