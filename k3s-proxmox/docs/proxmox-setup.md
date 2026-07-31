# Proxmox host setup

One-time preparation on the Proxmox host before running Terraform.

## 1. Create a Terraform API token

In the Proxmox web UI:

1. **Datacenter → Permissions → API Tokens → Add**
2. User: `root@pam` (or a dedicated user)
3. Token ID: `terraform`
4. Uncheck "Privilege Separation" (gives the token the same rights as the user)
5. Copy the displayed secret — it is shown only once.

The token string has the format `root@pam!terraform=<uuid>`.
Put it in `terraform.tfvars` as `proxmox_api_token`.

**Minimal permissions** (if you prefer not to use root):
```
VM.Allocate, VM.Clone, VM.Config.*, VM.Monitor, VM.PowerMgmt,
Datastore.AllocateSpace, Datastore.AllocateTemplate,
SDN.Use, Sys.Modify
```

---

## 2. Enable snippets on the local datastore

Terraform uploads cloud-init files as Proxmox snippets.

```bash
# On the Proxmox host (SSH as root):
pvesm set local --content iso,snippets,vztmpl,backup
```

Or via web UI: **Datacenter → Storage → local → Edit → Content → add "Snippets"**.

---

## 3. Create the Ubuntu 26.04 cloud-init VM template

Run the following on the **Proxmox host** (SSH as root).
Replace `local-lvm` and `vmbr0` with your actual storage and bridge names.

```bash
# Download Ubuntu 26.04 LTS cloud image
wget -O /var/lib/vz/template/iso/ubuntu-26.04-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Create VM (VMID 9000)
qm create 9000 \
  --name ubuntu-2404-template \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0 \
  --agent enabled=1 \
  --ostype l26 \
  --scsihw virtio-scsi-single

# Import disk into storage pool
qm importdisk 9000 \
  /var/lib/vz/template/iso/ubuntu-26.04-cloudimg-amd64.img \
  local-lvm

# Attach the imported disk as scsi0
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0,discard=on,iothread=1

# Add cloud-init drive
qm set 9000 --ide2 local-lvm:cloudinit

# Set boot order
qm set 9000 --boot order=scsi0

# Serial console (needed for cloud-init output to work)
qm set 9000 --serial0 socket --vga serial0

# Convert to template
qm template 9000
```

After this, `vm_template_id = 9000` in `terraform.tfvars` is ready to use.

---

## 4. Create the internal bridge (vmbr1)

The Terraform config uses two bridges:
- `vmbr0` — external / LAN (usually exists by default)
- `vmbr1` — internal cluster network (must be created)

```bash
# /etc/network/interfaces — add on the Proxmox host:
auto vmbr1
iface vmbr1 inet static
    address  10.10.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -A POSTROUTING -s '10.10.0.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.10.0.0/24' -o vmbr0 -j MASQUERADE
```

```bash
systemctl restart networking
# or: ifreload -a
```

VMs on `vmbr1` (10.10.0.0/24) can reach the internet via NAT through `vmbr0`.

---

## 5. Verify SSH access from Proxmox host

Terraform's `bpg/proxmox` provider SSHes into the Proxmox host to upload snippets.
Make sure your local SSH agent has the key, or set `private_key` in `terraform.tfvars`.

```bash
ssh root@<proxmox-ip>   # should succeed without password
```
