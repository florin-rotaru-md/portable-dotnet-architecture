## 1. Download Proxmox Virtual Environment
https://www.proxmox.com/en/downloads

## 2. Install Proxmox

## 3. Configure Proxmox
Datacenter -> proxmox -> Updates -> Repositories
-   disable https://enterprise.proxmox.com/debian/ceph-squid
-   disable https://enterprise.proxmox.com/debian/pve
-   add No-Subscription

### Disable sleep
Open Shell
``` bash
nano /etc/systemd/logind.conf

```

Add / modify
``` bash
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
```

Apply
``` bash
systemctl restart systemd-logind
```

### Disable sleep, hibernate, power saving
``` bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
echo "setterm -blank 0 -powerdown 0" >> /etc/profile
```

``` bash
apt update && apt full-upgrade -y
reboot
```

### utils
``` bash
apt install -y ntfs-3g
```

## 4. Download Ubuntu Server iso
https://ubuntu.com/download/server

## 5. Upload iso
Datacenter -> proxmox -> local -> ISO Images -> Upload

## 6. Add disks
List disks
``` bash
lsblk

root@proxmox:~# lsblk
NAME               MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
nvme0n1            259:0    0 476.9G  0 disk 
├─nvme0n1p1        259:1    0  1007K  0 part 
├─nvme0n1p2        259:2    0     1G  0 part /boot/efi
└─nvme0n1p3        259:3    0   475G  0 part 
  ├─pve-swap       252:0    0     8G  0 lvm  [SWAP]
  ├─pve-root       252:1    0    96G  0 lvm  /
  ├─pve-data_tmeta 252:2    0   3.5G  0 lvm  
  │ └─pve-data     252:4    0 347.9G  0 lvm  
  └─pve-data_tdata 252:3    0 347.9G  0 lvm  
    └─pve-data     252:4    0 347.9G  0 lvm  
nvme1n1            259:4    0   1.9T  0 disk 
```

### Clean {nvme1n1} disk
``` bash
wipefs -a /dev/nvme1n1
```

### Create Physical Volume
``` bash
pvcreate /dev/nvme1n1
```

### Create Volume Group
``` bash
vgcreate vg_nvme2 /dev/nvme1n1
```

### Create Thin Pool
``` bash
lvcreate -l 75%VG -T vg_nvme2/thinpool -c 128K -Zn
```

Datacenter → Storage → Add → LVM-Thin
ID: nvme2-thin
Volume group: vg_nvme2
Thin pool: thinpool
Select: Disk image, Container

## 7. Create ubuntu template
### Check iso: 
``` bash
ls /var/lib/vz/template/iso
```

### Create and start vm
``` bash
qm create 9000 \
  --name ubuntu-template \
  --memory 4096 \
  --cores 4 \
  --net0 virtio,bridge=vmbr0

qm set 9000 --machine q35 && \
qm set 9000 --bios seabios && \
qm set 9000 --scsihw virtio-scsi-single && \
qm set 9000 --scsi0 nvme2-thin:32,discard=on,iothread=1 && \
qm set 9000 --agent enabled=1 && \
qm set 9000 --cdrom local:iso/ubuntu-24.04.4-live-server-amd64.iso && \
qm set 9000 --boot order="scsi0;ide2" && \
qm set 9000 --bootdisk scsi0
```

Open
Datacenter → proxmox → 9000 -> Console
=> ESC
Type number for option - DVD/CD

Try or Install Ubuntu Server
English -> Done
Layout English US -> Done
Variant English US -> Done
(x) Ubuntu Server -> Done
Network configuration -> Done
Proxy address -> Done
Ubuntu archive mirror configuration -> Done
Guided storage configuration -> Done
Storage configuration -> Done
Confirm destructive action -> Continue

Your name           : deploy
Your server name    : deploy
Pick a user name    : deploy
Choose a password   : deploy

Upgrade to Ubuntu Pro 
(x) Skip for now -> Continue

SSH configuration
(x) Install OpenSSH server -> Continue

Featured server snaps
-> Done

Install complete
-> Reboot

### VM Login and check ip address
``` bash
ip a
```

### Connect using ssh
``` bash
ssh deploy@192.168.0.1
```

### Install qemu-guest-agent, cloud-init && cleanup
``` bash
apt update && \
apt upgrade -y && \
apt install -y qemu-guest-agent cloud-init sudo curl wget bash-completion && \
systemctl enable --now qemu-guest-agent && \
apt clean && \
journalctl --rotate && \
journalctl --vacuum-time=1s && \
cloud-init clean --logs && \
history -c && \
truncate -s 0 /etc/machine-id && \
rm -f /var/lib/dbus/machine-id && \
rm -rf /tmp/* /var/tmp/* && \
sync
```

### shutdown VM
``` bash
qm shutdown 9000
```

### cloud-init - Proxmox settings
Proxmox Shell
``` bash
qm set 9000 --delete ide2 && \
qm set 9000 --ide2 nvme2-thin:cloudinit && \
qm set 9000 --serial0 socket --vga serial0 && \
qm set 9000 --ipconfig0 ip=dhcp && \
qm set 9000 --boot order='scsi0'
```

### convert to template
``` bash
qm template 9000
```


### optional - backup template
``` bash
lsblk
```

You should see something like this:
``` bash
NAME                               MAJ:MIN RM   SIZE RO TYPE MOUNTPOINTS
sda                                  8:0    0   1.7T  0 disk 
├─sda1                               8:1    0   128M  0 part 
└─sda2                               8:2    0   1.7T  0 part 
```

``` bash
mkdir -p /mnt/usb-backup
```

``` bash
mount -t ntfs-3g /dev/sda2 /mnt/usb-backup
```

``` bash
pvesm add dir usb-backup \
  --path /mnt/usb-backup \
  --content backup
```

``` bash
vzdump 9000 --dumpdir /mnt/usb-backup --compress zstd
umount /mnt/usb-backup
sync
```

## 8. Create VM1010 ansible-control
Datacenter -> proxmox -> 9000 (ubuntu-template)
    right click -> clone
        Target Node     : proxmox
        VM ID           : 1010
        Name            : ansible-control
        Mode            : Full Clone
        Target Storage  : nvme2-thin

Datacenter -> proxmox -> 1010 -> Hardware
    Memory      : 4 GiB
    Processors  : 2
    Type        : host

Datacenter -> proxmox -> 1010 -> Cloud-init
    IP config -> Edit
    IPv4/CIDR   : 192.168.0.10/24
    Gateway     : 192.168.0.1

SSH deploy@192.168.0.10
``` bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip jq bash-completion python3 python3-pip python3-venv pipx openssh-client sshpass
mkdir -p ~/.local/bin
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
pipx ensurepath
pipx install --include-deps ansible
```

Verify:
``` bash
ansible --version
python3 --version
```

## 9. Create VM1021 app-20
Datacenter -> proxmox -> 9000 (ubuntu-template)
    right click -> clone
        Target Node     : proxmox
        VM ID           : 1020
        Name            : app-20
        Mode            : Full Clone
        Target Storage  : nvme2-thin

Datacenter -> proxmox -> 1020 -> Hardware
    Memory      : 8 GiB
    Processors  : 8
    Type        : host

Datacenter -> proxmox -> 1020 -> Cloud-init
    IP config -> Edit
    IPv4/CIDR   : 192.168.0.20/24
    Gateway     : 192.168.0.1

## 10. Create VM1030 db-30
Datacenter -> proxmox -> 9000 (ubuntu-template)
    right click -> clone
        Target Node     : proxmox
        VM ID           : 1030
        Name            : db-30
        Mode            : Full Clone
        Target Storage  : nvme2-thin

Datacenter -> proxmox -> 1030 -> Hardware
    Memory      : 32 GiB
    Processors  : 8
    Type        : host

Datacenter -> proxmox -> 1030 -> Cloud-init
    IP config -> Edit
    IPv4/CIDR   : 192.168.0.30/24
    Gateway     : 192.168.0.1

## 11. Generate SSH key on ansible-control
On ansible-control:
``` bash
test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -C "ansible-control" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Copy the public key to both VMs.

If password login is still enabled on the target VMs:
``` bash
ssh-copy-id deploy@192.168.0.20
ssh-copy-id deploy@192.168.0.30
```

Test SSH:
``` bash
ssh deploy@192.168.0.20 hostname
ssh deploy@192.168.0.30 hostname
```

## 12. Copy repository on ansible-control
On ansible-control, clone this repository or copy only the infrastructure package.

Example using git:
``` bash
mkdir -p ~/src
cd ~/src
git clone --branch master https://github.com/florin-rotaru-md/portable-dotnet-architecture.git
cd ~/src/portable-dotnet-architecture/infra/ansible
```

If repository access is not available from the VM, copy the folder from your workstation:
``` bash
ssh deploy@192.168.0.10 "mkdir -p /home/deploy/src"
scp -r portable-dotnet-architecture deploy@192.168.0.10:/home/deploy/src/
```

## 13. Install Ansible collections used by playbooks
On ansible-control:
``` bash
ansible-galaxy collection install community.docker ansible.posix
```

Optional local config for cleaner output:
``` bash
cat > ~/src/Statics/portable-dotnet-architecture/infra/ansible/ansible.cfg <<'EOF'
[defaults]
inventory = inventory/production.ini
host_key_checking = False
interpreter_python = auto_silent
stdout_callback = yaml

[privilege_escalation]
become = True
become_method = sudo
become_ask_pass = False
EOF
```

## 14. Configure inventory for local LAN
Edit `portable-dotnet-architecture/infra/ansible/inventory/production.ini`:
``` ini
[app]
app-20 ansible_host=192.168.0.20 ansible_user=deploy

[db]
db-30 ansible_host=192.168.0.30 ansible_user=deploy
```

Edit `portable-dotnet-architecture/infra/ansible/group_vars/production.yml`:
``` yml
ansible_python_interpreter: /usr/bin/python3
ufw_allowed_tcp_ports:
  - 22
  - 80
  - 443
postgres_version: "18"
postgres_bind_cidr: "192.168.0.20/32"
backup_retention_days: 7
```

## 15. Review placeholders before first bootstrap
These files still contain template values and should be adjusted before production use:

- `portable-dotnet-architecture/infra/ansible/group_vars/all.yml`
  - `project_name`
  - `nginx_server_name`
  - `app_image_default`
- `portable-dotnet-architecture/infra/ansible/roles/app_host/tasks/main.yml`
  - `ConnectionStrings__Main=Host=192.168.0.30;...`
- `portable-dotnet-architecture/infra/ansible/roles/db_host/templates/postgres-compose.yml.j2`
  - `POSTGRES_PASSWORD=replace-me`

## 16. Validate Ansible connectivity
From `portable-dotnet-architecture/infra/ansible`:
``` bash
ansible all -m ping
ansible app -m command -a "hostname -I"
ansible db -m command -a "hostname -I"
```

If `ping` fails because of sudo or SSH prompts, retry with:
``` bash
ansible all -m ping -u deploy --private-key ~/.ssh/id_ed25519
```

## 17. Bootstrap db-30
``` bash
ansible-playbook playbooks/bootstrap-db.yml
```

Verify:
``` bash
ssh deploy@192.168.0.30
docker ps
sudo crontab -l -u deploy
exit
```

## 18. Bootstrap app-20
``` bash
ansible-playbook playbooks/bootstrap-app.yml
```

Verify:
``` bash
ssh deploy@192.168.0.20
docker network ls | grep app_net
systemctl status nginx --no-pager
ls -lah /opt/myapp
exit
```

## 19. Files created by bootstrap
On `app-20` Ansible will create:
``` text
/opt/myapp/
  docker/
  env/
  nginx/
  runtime/
  scripts/
```

On `db-30` Ansible will create:
``` text
/opt/postgres/
  compose.yml
  data/
  backups/
  backup-db.sh
  backup-files.sh
```

## 20. First post-bootstrap adjustments
After bootstrap, log into the hosts and replace placeholders:

On `db-30`:
``` bash
nano /opt/postgres/compose.yml
docker compose -f /opt/postgres/compose.yml up -d
```

On `app-20`:
``` bash
nano /opt/myapp/env/common.env
```

Then test network reachability from app to db:
``` bash
ssh deploy@192.168.0.20
nc -zv 192.168.0.30 5432
exit
```

## 21. Recommended helper script on ansible-control
Create a simple wrapper to avoid long commands:
``` bash
cat > ~/bootstrap-local.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd ~/src/Statics/portable-dotnet-architecture/infra/ansible
ansible all -m ping
ansible-playbook playbooks/bootstrap-db.yml
ansible-playbook playbooks/bootstrap-app.yml
EOF
chmod +x ~/bootstrap-local.sh
```

Run it:
``` bash
~/bootstrap-local.sh
```

## 22. Operational notes for ansible-control
- keep the private SSH key only on `ansible-control`
- use snapshots before major playbook changes
- commit infra changes in git before rerunning playbooks
- keep `production.ini` and `group_vars` in sync with real IPs
- rerun playbooks safely after updates; the roles are intended to be idempotent

