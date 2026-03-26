# Disaster Recovery — k3s-proxmox Setup

The DR model is identical to `k3s/` with one additional dimension:
**the Proxmox host itself** can fail.

## Backup matrix

| Component        | Stored in                                 | Schedule     |
|------------------|-------------------------------------------|--------------|
| k3s cluster state| etcd snapshot → S3                        | Daily 3:00   |
| Application DBs  | pg_dump → S3                              | Daily 2:15   |
| Desired state    | Git repository                            | Always       |
| VM configs       | Proxmox backup (vzdump) → NFS / PBS       | Daily (recommended) |
| Proxmox config   | `/etc/pve/` → version-controlled manually | On change    |

---

## Scenario A — Pod / app rollback

Same as `k3s/` — Flux reconciles, or force via:
```bash
flux reconcile kustomization apps --with-source
```

---

## Scenario B — k3s VM fails (Proxmox host is healthy)

1. **Delete the failed VM** in Proxmox UI or:
   ```bash
   qm stop 200 && qm destroy 200
   ```

2. **Re-create via Terraform**:
   ```bash
   cd k3s-proxmox/terraform
   terraform apply
   ```

3. **Update inventory** with new IP, then:
   ```bash
   cd k3s-proxmox/infra/ansible
   ansible-playbook playbooks/bootstrap.yml --limit k3s_server
   ```

4. **Flux reconciles** everything from Git automatically.

---

## Scenario C — Postgres VM fails

Same steps as `k3s/docs/disaster-recovery.md — Scenario C`, substituting
the Proxmox internal IP `10.10.0.50` for the new Postgres VM.

```bash
# Recreate VM:
terraform apply

# Bootstrap:
ansible-playbook playbooks/bootstrap.yml --limit postgres

# Restore from S3:
aws s3 cp s3://<bucket>/postgres/<db>_latest.dump /tmp/restore.dump \
  --endpoint-url <s3_endpoint>
sudo -u postgres pg_restore -d myapp_db /tmp/restore.dump

# Update k3s Secret:
kubectl create secret generic myapp-db \
  --from-literal=ConnectionStrings__Main="Host=10.10.0.50;..." \
  -n myapp --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/myapp -n myapp
```

---

## Scenario D — Proxmox host fails (full hardware loss)

This is the scenario unique to on-prem. Two sub-cases:

### D1 — Proxmox host recoverable (disk intact)

```bash
# Reinstall Proxmox OS (same version), restore /etc/pve from backup
# Start VMs: qm start <vmid>
# VMs come back, Flux reconciles
```

### D2 — Proxmox host unrecoverable

1. **Stand up a new Proxmox host** (same or different hardware)
2. **Re-run one-time setup** (see `docs/proxmox-setup.md`):
   - Create API token
   - Enable snippets
   - Create Ubuntu template (VMID 9000)
   - Create vmbr1
3. **Re-run Terraform** (same `terraform.tfvars`):
   ```bash
   cd k3s-proxmox/terraform
   terraform init
   terraform apply
   ```
4. **Update inventory** IPs if they changed, then:
   ```bash
   ansible-playbook playbooks/bootstrap.yml
   ```
5. **Flux reconciles** all apps from Git.
6. **Restore Postgres** from S3 (Scenario C above).
7. **Update DB Secret** in k3s, restart pods.

**RTO estimate:**
- D1: ~15 minutes (VM restart + Flux)
- D2: ~60–90 minutes (new Proxmox setup + Terraform + Ansible + Flux)

**RPO:** up to 24 hours (last nightly backup)

---

## Proxmox-level VM backups (recommended additional layer)

Configure Proxmox Backup Server (PBS) or NFS backup storage and schedule `vzdump`:

```bash
# Via Proxmox web UI: Datacenter → Backup → Add
# Schedule: daily, storage: pbs or nfs-backup
# VMs to include: 200 (k3s-server-1), 210 (db-1)
# Mode: snapshot (no downtime)
```

With VM-level backups, D2 recovery becomes:
1. Install Proxmox on new hardware
2. Attach backup storage
3. Restore VMs from PBS: `qmrestore <backup> <vmid>`
4. Start VMs — Flux reconciles, DB is already restored

**RTO with VM backups: ~20–30 minutes**

---

## Pre-disaster checklist

- [ ] `aws s3 ls s3://<bucket>/etcd/` — recent snapshots present
- [ ] `aws s3 ls s3://<bucket>/postgres/` — recent dumps present
- [ ] Proxmox VMs are included in daily vzdump schedule
- [ ] `terraform plan` shows no unexpected drift
- [ ] `flux get all -A` shows all resources as `Ready`
- [ ] Test restore to a second Proxmox host quarterly
