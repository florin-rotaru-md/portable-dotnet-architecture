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

### Resize disk
Open Shell
``` bash
qm resize 1030 scsi0 +608G
```

Open VM ssh
``` bash
sudo -i
apt update && apt install cloud-guest-utils
lsblk
```

``` bash
NAME                      MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
sda                         8:0    0  640G  0 disk
├─sda1                      8:1    0    1M  0 part
├─sda2                      8:2    0    2G  0 part /boot
└─sda3                      8:3    0   30G  0 part
  └─ubuntu--vg-ubuntu--lv 252:0    0   15G  0 lvm  /
sr0                        11:0    1    4M  0 rom
```

look for lvm type ex
└─sda3                      8:3    0   30G  0 part
  └─ubuntu--vg-ubuntu--lv 252:0    0   15G  0 lvm  /

``` bash
growpart /dev/sda 3
pvresize /dev/sda3
lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
```

## 11. Generate SSH key on ansible-control
On ansible-control:
``` bash
test -f ~/.ssh/id_ed25519_ansible || ssh-keygen -t ed25519 -C "ansible-control" -f ~/.ssh/id_ed25519_ansible
cat ~/.ssh/id_ed25519_ansible.pub
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
