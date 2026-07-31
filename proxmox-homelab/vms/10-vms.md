# Stage 10 — The VMs

*Part of the [Proxmox homelab guide](../README.md).*

All via cloning — for each VM: right-click on **9000** → **Clone**, and in the dialog:

| Field | Value |
|---|---|
| Target node | `pve1` (rebalance later if you want) |
| VM ID / Name | from the table below |
| Mode | **Full Clone** — linked clones can't migrate off the node |
| Target Storage | from the table below |

Then adjust each clone before first boot:
- **Hardware → Memory / Processors** → values below (CPU **Type stays `x86-64-v3`**, inherited)
- **Cloud-Init → IP Config (net0) → Edit** → static IP + gateway below
- Start the VM, and once it's up: `ssh devops@<its-IP>`

| VM ID | Name | Storage | CPU | RAM | Disk | IP (Cloud-init) |
|---|---|---|---|---|---|---|
| 1010 | control-ubuntu | `apps` | 2 | 4 GiB | 32G — as cloned | 192.168.0.10/24, gw .1 |
| 1020 | app-ubuntu | `apps` | 8 | 8 GiB | **128G** | 192.168.0.20/24, gw .1 |
| 1030 | postgres-ubuntu | **`db`** | 8 | 32 GiB | **640G** | 192.168.0.30/24, gw .1 |
| 1040 | monitoring-ubuntu | `apps` | 2 | 4 GiB | **320G** | 192.168.0.40/24, gw .1 |

1040 is the fourth, last VM: Loki + Grafana, wired up in [Stage 11](11-bootstrap.md#117-the-monitoring-vm-1040--loki--grafana). Its 320G looks generous next to 1010's 32G for the same CPU/RAM — but the `apps` pool is thin-provisioned ([Stage 6.1](../cluster/06-zfs-pools.md#61-thin-provisioning--set-it-before-any-vm-disk-exists)), so a big declared ceiling costs nothing until logs actually fill it. Cheap headroom now beats a `qm resize` interruption later.

> ⚠️ Under Hardware → Processors, the type stays **x86-64-v3** (inherited from the template). Do NOT change it to `host` — the VM would no longer migrate safely between the two nodes.

## Grow the disk — per VM

Every clone arrives with the template's 32GB floor. Each VM is then grown to the size *it* needs, which is why the template stays small: clones grow, never shrink, so a generous template would be a ceiling imposed on every VM you ever create ([9.3](09-ubuntu-template.md#93-create-the-vm-shell-around-it)).

One command per VM, from the Proxmox Shell — **before the first start**:

| VM | Target | Command |
|---|---|---|
| 1010 control | 32G | — nothing to do, the clone is already right |
| 1020 app | 128G | `qm resize 1020 scsi0 128G` |
| 1030 postgres | 640G | `qm resize 1030 scsi0 640G` |
| 1040 monitoring | 320G | `qm resize 1040 scsi0 320G` |

Absolute sizes, not `+N`: the target is what it is regardless of what the template happens to be, so these lines stay correct if the template is ever rebuilt at a different size. Grow-only — ZFS-backed disks cannot be shrunk, in Proxmox or anywhere else. (`qm` sizes are binary: `640G` is 640 × 1024³.)

**The guest side happens by itself.** The cloud image's root sits on a plain partition, and cloud-init's `growpart` module runs at **every** boot — the first boot finds the bigger disk and grows the partition and filesystem into it. Nothing to run inside the guest, nothing to remember on VM number four; `df -h /` after boot is the proof, and the smoke test in [9.6](09-ubuntu-template.md#96-verify-before-you-build-on-it) already validated the mechanism. (Resized a disk while the VM was running? It's picked up on the next reboot.) This is also why [Stage 11](11-bootstrap.md#114-vaultyml-and-mainyml) sets `grow_root_filesystem: false`: the `common` role's growth chain exists for LVM layouts, and there's no LVM here to grow.

**ISO-alternative layouts only** ([9.8](09-ubuntu-template.md#98-the-alternative-interactive-iso-install)): there the root *is* on LVM, cloud-init can't grow it, and the `common` role does it on every playbook run — keep `grow_root_filesystem: true` and see [9.8g](09-ubuntu-template.md#98-the-alternative-interactive-iso-install) for the manual chain.

## Control node — Ansible

On control-ubuntu (192.168.0.10):
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip jq bash-completion python3 python3-pip python3-venv pipx openssh-client sshpass
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
pipx ensurepath
pipx install --include-deps ansible
ansible --version
```

## SSH keys

On control-ubuntu:
```bash
test -f ~/.ssh/id_ed25519_devops || ssh-keygen -t ed25519 -C "devops" -f ~/.ssh/id_ed25519_devops
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub devops@192.168.0.20
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub devops@192.168.0.30
ssh-copy-id -i ~/.ssh/id_ed25519_devops.pub devops@192.168.0.40
ssh devops@192.168.0.20 hostname
ssh devops@192.168.0.30 hostname
ssh devops@192.168.0.40 hostname
```

Four empty machines, reachable and key-authenticated — [Stage 11](11-bootstrap.md) fills them.
