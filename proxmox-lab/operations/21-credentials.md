# Stage 21 — Credentials & key management

*Part of the [Proxmox lab guide](../README.md).*

Everything before this stage assumes you can log in. Replication, HA, backups, restores — all of it is theater if the day you need it is also the day you discover the only key was on the machine that died. This stage is the inventory of what exists, where each piece lives, and what recovery looks like when one of them is gone.

## 21.1 Inventory — what exists and where it lives

Three kinds of SSH material, easy to conflate, with completely different loss profiles. All the pairs below are generated in one sitting in [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now) — this table is what each one *becomes* afterwards:

| What | Where it lives | What it is | If lost |
|---|---|---|---|
| **Your workstation's private key** (`~/.ssh/id_ed25519`) | Your PC | **Your identity.** Opens whatever it's authorized on | You knock on other doors (21.5) |
| **control-ubuntu's private key** (`~/.ssh/id_ed25519_devops`) | VM 1020; the pair is in the password manager like every [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now) key — generated there, installed in [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) | **Ansible's identity.** Every playbook run flows through it | Config management stops until you restore 1020 or re-install the pair from the password manager (21.5) — the cheapest loss on this list |
| **Each node's root private key** (`/root/.ssh/id_ed25519`, pve1 and pve2) | The nodes | Injected via `--sshkeys /root/.ssh/vm_keys.pub` ([9.4](../vms/09-ubuntu-template.md#94-cloud-init-defaults)) → opens **every VM**, and is the *only* thing that opens a freshly cloned one ([Stage 10](../vms/10-vms.md#ssh-access--key-only-from-the-first-boot)). They also open **root on the QDevice** ([8.4](../cluster/08-qdevice.md#84-ssh--key-only-from-your-pc-and-from-both-nodes)) — which is what lets `pvecm qdevice setup` work without ever enabling password login there. Two nodes, two keys, so losing a node doesn't lose the path | One less recovery path; also: guard these, they're skeleton keys |
| **The break-glass private key** | Password manager + paper, **never in the lab** | Authorized everywhere from birth, used nowhere. The one that still works when the four above are gone | The recovery of last resort is gone — regenerate and re-seed via Ansible the same day |
| **Public keys** in `~/.ssh/authorized_keys` | Each VM's disk | **The locks, not the keys.** Travel with the disk: replicated by Stage 12, backed up by Stage 17 | Nothing — regenerate from the role |
| **Host keys** (`/etc/ssh/ssh_host_*`) | Each VM's disk | The **server's** identity toward you — they never authenticate *you*. The cloud image ships without them (and the ISO route strips them, [9.8e](../vms/09-ubuntu-template.md#98-the-alternative-interactive-iso-install)), so every clone generates unique ones at first boot | Nothing **on the VM** — it regenerates at first boot. The cost lands on whatever pinned the old one, and it lands *silently*: `BatchMode=yes` has no prompt to raise, so an automated caller gets `Host key verification failed` on stderr and no answer. pve1 still pins a superseded key for 192.168.0.22 — 1022 was rebuilt in the 2026-09-05..07 database reset — so everything that sshs from there to the database VM fails closed — `pg-offsite`'s pull of the WAL spool and both of `backup-verify`'s in-VM checks ([21.7](#217-the-fourth-kind-the-pins-nobody-inventories)); a check that prints *state UNKNOWN* reports the pin, it does not repair it. Repair pins the same day, on **both nodes** (`/root/.ssh/known_hosts`), on control-ubuntu and on your PC — and repair means *replace*, not delete: an unknown host fails identically to a stale one under `BatchMode`, so `ssh-keygen -f <known_hosts> -R <ip>` on its own leaves the check just as broken, for a new reason. Remove, then reconnect once interactively and compare the fingerprint against the VM's own `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` ([8.4](../cluster/08-qdevice.md#84-ssh--key-only-from-your-pc-and-from-both-nodes), [21.7](#217-the-fourth-kind-the-pins-nobody-inventories)) |

And the non-SSH credentials, which get less attention and hurt more:

| Credential | Protects | Kept where |
|---|---|---|
| Proxmox root password (×2 nodes) | The hypervisors, web UI and console | Password manager |
| QDevice root password, and its `devops` console password | The third box. After [8.4](../cluster/08-qdevice.md#84-ssh--key-only-from-your-pc-and-from-both-nodes) closes password login over the network, these work **only at the console** — and that console is the single way back in if root's `authorized_keys` there is ever lost | Password manager |
| VM `--cipassword` | The console login — the no-SSH recovery path (21.4) | Password manager |
| **Digi Storage Business** account, and the **app password** rclone signs in with | The offsite tier's storage — remote `digi:`, rclone backend `koofr`, provider `digistorage` ([17.3](../backup/17-backup-restore.md#173-offsite--digi-storage)). The account login is what mints a new app password | Password manager |
| rclone crypt **password + salt** of `digi-crypt:` | Everything on Digi — images, WAL, base backups, logical dumps, host config, the inventory copy ([17.3](../backup/17-backup-restore.md#173-offsite--digi-storage)). Without both, what is stored there is unreadable | Password manager **+ paper** |
| `/root/.config/rclone/rclone.conf` (pve1 and pve2, identical) | Holds all three of the above — *obscured*, not encrypted — and is in no backup | The nodes only; rebuilt from the two rows above |
| `vault.yml` contents (postgres password, tokens, `grafana_admin_password`) — and the vault password if encrypted | The application layer | Repo (encrypted) + password manager + the inventory copy on Digi (`inventory/`, [17.6](../backup/17-backup-restore.md#176-host-configuration-and-the-ansible-inventory)) |

> **A restore from Digi starts at the password manager.** Every object there is encrypted with the two crypt passwords — the copy of the Ansible inventory under `inventory/` too, which a VM rebuilt from git needs ([17.6](../backup/17-backup-restore.md#176-host-configuration-and-the-ansible-inventory)) — and the only other place they exist is `rclone.conf` on the nodes, which is what the scenario that needs Digi has lost. Treat that file as the credential it is: rclone's obscuring is reversible by anyone who can run `rclone reveal`, so a copy of `rclone.conf` is a copy of the offsite tier.

## 21.2 What a restore actually gives back

The question that motivates this stage: *after a `qmrestore`, do I still get in?*

**Yes, with nothing to reconfigure.** vzdump restores the disk bit for bit, and `authorized_keys` is a file on that disk — the restored VM accepts exactly the keys the original did. The original host keys come back too, so you don't even get the `REMOTE HOST IDENTIFICATION HAS CHANGED` warning. Access survives restore for free.

One nuance: restoring **alongside** the original into a new VM ID ([17.7 A](../backup/17-backup-restore.md#a-restore-into-a-new-vm-id-safest--start-here)) means two machines now hold the same host keys and the same locks. Fine for a disposable inspection VM with its NIC disconnected; wrong for anything that stays. A clone meant to *live* should go through the template path, where host keys are stripped.

## 21.3 The rule: recovery credentials must live outside the thing they recover

This is the trap that matters more than any single key:

> If the only copy of the private key sits on control-ubuntu, and control-ubuntu sits inside an encrypted backup on Digi Storage, you need the key to reach the key. If the rclone crypt passwords exist only inside the lab, the offsite backup is mathematically unrecoverable in **exactly** the scenario it exists for — house gone, lab gone, passwords gone with it.

Circular recovery dependencies are invisible until the day they bite, because every partial failure still works — only the total one doesn't. So audit for the cycle, not for the copies.

**The minimum that must exist outside the lab** — password manager, plus ideally a paper copy somewhere physically separate. [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now) exists to make this list true from day one rather than as a retrofit; if you're reading this on an already-built lab, it's a checklist instead:

1. **SSH private keys** — all of [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now)'s pairs: your workstation's, both nodes' root keys, `devops`, and the break-glass key (21.6). One origin, one rule — every pair has a password-manager copy, no exceptions to remember
2. **rclone crypt password and salt**, plus the Digi account — [17.3](../backup/17-backup-restore.md#173-offsite--digi-storage) already says this; it bears repeating because it's load-bearing: without the pair nothing on Digi is readable, the inventory copy included
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

- **It does not weaken SSH.** cloud-init tends to flip `ssh_pwauth` on when a password is set — which would quietly turn "console safety net" into "password-guessable SSH". Two things foreclose it: the cloud image's own `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`, in force from the first boot, and afterwards the `common` role's `99-key-only.conf`. The password works at the console, and nowhere else — including on a brand-new clone Ansible has never touched.
- **Without it, recovery still exists — barely.** The hypervisor can always mount the VM's disk (zvol → partition mapping → LVM activation → edit `authorized_keys` by hand). It works. It is also fiddly, error-prone root-level surgery on your database VM's disk, performed on precisely the day everything else already went wrong. A password in a password manager is the same outcome with none of the drama.

## 21.5 Recovery scenarios — what losing each thing actually means

| You lost | Still working | The way back |
|---|---|---|
| **Workstation key** | control-ubuntu's key, pve1 root's key | Get in via the control VM or pve1. Generate a new pair, add the public key to `ansible_ssh_extra_public_keys`, run the playbook. Remove the old one from the list (21.6) |
| **control-ubuntu** (the VM or its key) | Your workstation key, the nodes' root keys | Restore VM 1020 from backup — its key is on the restored disk (21.2). Or rebuild it and **re-install** the pair from the password manager, the same install as [Stage 10](../vms/10-vms.md#ssh-keys--control-ubuntu--the-other-three) — its public half is already in `vm_keys.pub` and on every VM, so the restored key opens 1021/1022/1023 immediately ([0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now)) |
| **Every SSH key at once** | The Proxmox console + `--cipassword` | Log in on the console, re-seed `authorized_keys`, then rotate everything deliberately |
| **Every SSH key, and no cipassword** | The hypervisor's access to the disk | Mount the zvol from pve1/pve2 and edit `authorized_keys` manually (21.4). Set the cipassword right after |
| **Proxmox root password** | Physical access | Standard Debian recovery: boot with `init=/bin/bash` from GRUB, `passwd`, reboot. Then store it properly |
| **rclone crypt passwords** | Replication and the staging on each node's `local` — unaffected | Everything already on Digi is **gone** — that's the design. New crypt config and passwords in `rclone.conf` on both nodes, paper copy this time; then `backup-verify` shows what has reached the new remote and what has not yet ([17.3](../backup/17-backup-restore.md#173-offsite--digi-storage)) |
| **Digi app password** | Everything; the data on Digi is intact | Mint a new one from the Digi account and put it into `rclone.conf` on both nodes. A non-event, unless the account login went with it |
| **ansible-vault password** | Everything currently running | `vault.yml` is unrecoverable; re-issue its contents — reset `postgres_password` via `psql` as the `postgres` user, re-issue API tokens, re-encrypt |
| **The cipassword** | Everything — SSH is unaffected | `qm set <id> --cipassword` + reboot. Non-event, if SSH still works |

The pattern across every row: **each credential's recovery path runs through a *different* credential.** That's the property to preserve when you change anything about this setup — never let two of these collapse into one.

## 21.6 Two habits that make key loss boring

**1. At least two authorized keys per VM.** One key is a single point of failure with perfect uptime until it isn't. Following [0.5](../setup/00-preparation.md#05-keys--generate-all-of-them-now) you have five, and the list the `common` role takes should name all of them — the same five that are in `vm_keys.pub`:

```yaml
# group_vars / vault.yml
ansible_ssh_public_key: "{{ lookup('file', '~/.ssh/id_ed25519_devops.pub') }}"
ansible_ssh_extra_public_keys:
  - "ssh-ed25519 AAAA... workstation"
  - "ssh-ed25519 AAAA... break-glass"
  - "ssh-ed25519 AAAA... pve1-root"
  - "ssh-ed25519 AAAA... pve2-root"
```

> **The two node keys are the ones people leave out, and it's the expensive omission.** They're not "someone's key", so they don't feel like they belong in an identity list — but they are in `vm_keys.pub`, they are the hypervisor's only way into its own guests ([Stage 10](../vms/10-vms.md#ssh-access--key-only-from-the-first-boot)), and they are half the rows in [21.5](#215-recovery-scenarios--what-losing-each-thing-actually-means). Leave them out and the `exclusive` flag below will quietly delete them from every VM on its first run, taking the hypervisor's access with it.

Didn't do 0.5, and the break-glass pair doesn't exist yet? It's generated once, offline, and its private half never touches a lab machine:

```bash
ssh-keygen -t ed25519 -C "break-glass" -f ./id_ed25519_breakglass
# public half  → ansible_ssh_extra_public_keys, and → /root/.ssh/vm_keys.pub on pve1
# private half + passphrase → password manager + paper, then delete the local file
```

**2. `authorized_keys` belongs to Ansible, not to hands.** The role manages the full list declaratively: it applies identically to new VMs and restored ones, and a key added by hand on one VM is drift waiting to confuse you. Once every key you rely on is in the list, flip the lock:

```yaml
ssh_authorized_keys_exclusive: true
```

From then on, keys **not** in the list are removed on the next run — rotating a compromised key is *delete the line, run the playbook*, across every VM at once. This is the same ownership boundary as [20.5](20-upgrades.md#205-the-same-pattern-applied-elsewhere): the template's `--sshkeys` matters exactly once, at first boot; after that, Ansible owns the file.

> Don't enable `exclusive` before the list is complete — it removes keys, that's its job. Check what's actually authorized first: `ansible all -m command -a 'cat ~/.ssh/authorized_keys' -b --become-user devops`, reconcile against the list, then flip.

## 21.7 The fourth kind: the pins nobody inventories

[21.1](#211-inventory--what-exists-and-where-it-lives) lists three kinds of SSH material — private keys, public keys, host keys — and each of them authenticates somebody. There is a fourth file that authenticates nobody, appears in no inventory, and is the only thing on this page that has already turned a working system into a green checkmark: the **pinned copy** of a host key. Four of them exist on these nodes, they are not the same file, and nothing keeps three of them in step.

| File | Who actually reads it | State here, 2026-09-10 |
|---|---|---|
| `/etc/pve/nodes/<node>/ssh_known_hosts` | **PVE itself.** `PVE::SSHInfo` passes `-o UserKnownHostsFile=<that file> -o HostKeyAlias=<node>` on every migration and replication call, so it consults nothing else — and it keys the entry on the node *name*, never on an address | present and correct on both nodes; migration and replication tested working in both directions |
| `/etc/pve/priv/known_hosts` | Nothing you rely on — the pre-8.x cluster-wide file, still in pmxcfs, still stale | two lines, `pve1` and `192.168.0.11`. **No pve2 entry at all**, and none will appear: `ssh_merge_known_hosts` has exactly one caller, the `pvecm create` path, so the key of a node that *joined* was never merged |
| `/etc/ssh/ssh_known_hosts` — here a symlink to the legacy file above | every *plain* `ssh` on the node: the helper scripts, and your own hands | on **pve1** only, and it buys nothing — it resolves to a file holding pve1's own key and nobody else's |
| `/root/.ssh/known_hosts` | plain `ssh` again, per node, shared with nothing, hashed so `grep` won't find anything | pve1 has pins it accumulated by hand — including a **superseded** one for 192.168.0.22 (line 9), 1022 having been rebuilt in the 2026-09-05..07 database reset. pve2 has no pin for pve1 at all |

Two consequences, both of which read as something else until you know:

- **`ssh root@192.168.0.11` from pve2 dies with `Host key verification failed`, and the cluster is genuinely fine.** Migration and replication never notice: they pass their own known-hosts file and a `HostKeyAlias`, and that path was tested working from pve2 ([14](../ha/14-live-migration.md)). So do not read this as a cluster fault and do not go looking at corosync or the migration network. What breaks is everything that shells out to a *plain* `ssh`. The direction that works is the accident: pve1 reaches pve2 only because root there once accepted the key by hand, and pve2 never did the same in reverse — nothing systematic maintains either. **`pvecm updatecerts` is not the repair**, however much it sounds like it: it rewrites the per-node files in row one, which are not broken and which plain `ssh` never reads. Pin the key where plain `ssh` looks for it, and take it from the file PVE already keeps correct rather than from a first-connection prompt you have no way to check:

  ```bash
  # on pve2 — the alias line PVE trusts, re-keyed onto the address you actually type.
  # That file is one line with NO trailing newline (557 bytes, `wc -l` says 0), and sed
  # preserves that, so terminate it here: without the echo a second run — or any later
  # append — glues two entries into one line and known_hosts stops matching either.
  { sed 's/^pve1 /pve1,192.168.0.11 /' /etc/pve/nodes/pve1/ssh_known_hosts; echo; } >> /root/.ssh/known_hosts
  ssh -o BatchMode=yes root@192.168.0.11 hostname     # must answer pve1, not a warning
  ```

- **A rebuilt VM invalidates the pins on the hypervisors, and what stops first is the database's offsite tier.** A *restore* gives the guest's host keys back ([21.2](#212-what-a-restore-actually-gives-back)); a *rebuild* — the template path, [17.7 F](../backup/17-backup-restore.md#f-full-disaster-recovery-both-nodes-gone), `create-vms.sh` — mints new ones. pve1 still pins 1022's old key: the VM answers a ping, and `ssh` refuses it with `REMOTE HOST IDENTIFICATION HAS CHANGED` before any command runs. Everything a node sends there is plain `ssh` under `BatchMode`: `pg-offsite`'s pull of the WAL spool, every minute, and both of `backup-verify`'s in-VM checks ([17.4](../backup/17-backup-restore.md#174-postgres--continuous-wal-and-a-weekly-base)). `pg-offsite` logs the refusal to `/var/log/pg-offsite.log` and retries while WAL piles up in the VM's spool. The checks keep the SSH exit status apart from the query result, so they fail closed — `pg-archive: could not query 192.168.0.22 …, so the WAL tier's state is UNKNOWN` — and quote the first meaningful line the `ssh` printed, which here is the host-key banner itself, so the message names the pin instead of guessing at causes. They say so only once the current copies are on the nodes, so re-run [Stage 2.4](../setup/02-post-install.md#24-install-the-helper-scripts-both-nodes) on both nodes *and* repair the pin — one without the other leaves a file in no inventory deciding whether the database leaves the building at all.

The rule: a pin is not a credential — losing one costs nothing, and not a single row of [21.5](#215-recovery-scenarios--what-losing-each-thing-actually-means) applies to it. A **wrong** pin is worse than a lost one, because it is the failure on this page most easily mistaken for good news — which is why the checks keep *I could not ask* apart from *I asked and the answer was no*. So:

- ***"I rebuilt a VM"* also means *"clear its pin wherever anything sshs to it"*** — `ssh-keygen -f /root/.ssh/known_hosts -R <ip>` on pve1, pve2 and control-ubuntu, then re-pin. Not by the recipe above, which works only because PVE maintains a correct copy of a *node's* key: no such file exists for a guest, so a guest is re-pinned by connecting once interactively and comparing the fingerprint against the VM's own `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` read from the Proxmox console ([21.1](#211-inventory--what-exists-and-where-it-lives)). Both halves belong in the rebuild step, not in your memory — and removing without re-pinning leaves the check exactly as broken, for a new reason.
- **`Host key verification failed` on a node is an alerting outage**, in the same class as a dead mail path: something that was watching the lab has stopped watching. Fix the pin. Never paper over it with `-o StrictHostKeyChecking=no`, which trades one loud failure for a permanent blind spot.
