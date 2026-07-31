# Stage 9 — The VMs

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

| VM ID | Name | Storage | CPU | RAM | IP (Cloud-init) |
|---|---|---|---|---|---|
| 1010 | control-ubuntu | `apps` | 2 | 4 GiB | 192.168.0.10/24, gw .1 |
| 1020 | app-ubuntu | `apps` | 8 | 8 GiB | 192.168.0.20/24, gw .1 |
| 1030 | postgres-ubuntu | **`db`** | 8 | 32 GiB | 192.168.0.30/24, gw .1 |

> ⚠️ Under Hardware → Processors, the type stays **x86-64-v3** (inherited from the template). Do NOT change it to `host` — the VM would no longer migrate safely between the two nodes.

## Resize the postgres disk (after cloning)

Proxmox Shell:
```bash
qm resize 1030 scsi0 +608G
```

Inside the VM (ssh → `sudo -i`):
```bash
apt update && apt install cloud-guest-utils
lsblk    # identify the LVM partition (e.g. sda3 → ubuntu--vg-ubuntu--lv)

growpart /dev/sda 3 && \
pvresize /dev/sda3 && \
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv && \
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

(Don't skip the `resize2fs` at the end — `lvextend` alone grows the volume but the filesystem doesn't see the new space until you resize it too.)

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
ssh devops@192.168.0.20 hostname
ssh devops@192.168.0.30 hostname
```

Three empty machines, reachable and key-authenticated — [Stage 9b](09b-bootstrap.md) fills them.
