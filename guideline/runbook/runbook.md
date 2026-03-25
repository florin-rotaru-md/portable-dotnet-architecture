
# Proxmox + .NET Production Runbook

## Purpose
Step-by-step execution guide for deploying the full stack.

---

## STEP 1 – Proxmox Setup
- Install Proxmox VE
- Configure storage
- Create bridge vmbr0

---

## STEP 2 – Create Ubuntu Template
1. Install Ubuntu 24.04
2. Install:
   sudo apt update
   sudo apt install -y qemu-guest-agent cloud-init
3. Enable services:
   systemctl enable qemu-guest-agent
4. Convert VM to template

---

## STEP 3 – Create VMs

### ansible-control
- 2 CPU / 4GB RAM

### app-20
- 8 CPU / 16GB RAM

### db-30
- 8 CPU / 32GB RAM

---

## STEP 4 – SSH Setup

On control:
ssh-keygen -t ed25519

Copy key:
ssh-copy-id deploy@192.168.0.20
ssh-copy-id deploy@192.168.0.30

---

## STEP 5 – Install Ansible

sudo apt update
sudo apt install -y python3-pip
pip install ansible

---

## STEP 6 – Inventory

[app]
app-20 ansible_host=192.168.0.20

[db]
db-30 ansible_host=192.168.0.30

Test:
ansible all -m ping -i inventory.ini

---

## STEP 7 – Install runtime dependencies (app-20 and db-30)

sudo apt install -y docker.io docker-compose-plugin

---

## STEP 8 – Setup App Directories

/opt/myapp/
  docker/
  nginx/
  scripts/
  env/

---

## STEP 9 – First Deploy

docker network create app_net

docker compose up -d

Test:
curl localhost/.well-known/live
curl localhost/.well-known/ready

---

## STEP 10 – Blue/Green Deploy

1. Deploy new version
2. Wait ready
3. Switch nginx
4. Stop old

---

## STEP 11 – Backup

DB:
pg_dump daily from the PostgreSQL runtime on db-30

Store externally

---

## STEP 12 – Restore Test

- Restore DB on new VM
- Validate app works

---

## CHECKLIST

- [ ] SSH works
- [ ] Ansible ping works
- [ ] Docker installed
- [ ] App responds
- [ ] Backup works
- [ ] Restore tested

