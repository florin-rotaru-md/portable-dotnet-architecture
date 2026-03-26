# Disaster Recovery — k3s Setup

## Architecture snapshot

| Component        | State stored in                          |
|------------------|------------------------------------------|
| Cluster config   | etcd (auto-snapshotted to S3 nightly)    |
| Desired state    | Git repository (this repo)               |
| Application DB   | Postgres VPS (pg_dump to S3 nightly)     |
| Secrets          | k8s Secrets (restore from vault / re-create) |

---

## Backup schedule

| Job                     | Frequency  | Destination           | Retention |
|-------------------------|------------|-----------------------|-----------|
| k3s etcd snapshot       | Daily 3:00 | `s3://<bucket>/etcd/` | 30 days   |
| Postgres pg_dump        | Daily 2:15 | `s3://<bucket>/postgres/` | 30 days |

Both are configured via `cron` in the respective Ansible roles.

---

## Recovery runbook

### Scenario A — Application rollback (no infrastructure failure)

```bash
# Flux will re-reconcile within 5 minutes on its own.
# To force immediate reconciliation:
flux reconcile kustomization apps --with-source

# To pin to a previous image tag, edit flux/apps/myapp/helmrelease.yaml
# and update image.tag, then commit + push.
```

---

### Scenario B — Single node failure (k3s server is dead)

1. **Provision a new VPS** via Terraform:
   ```bash
   cd k3s/terraform
   terraform apply
   ```

2. **Update inventory** with the new IP:
   ```bash
   vim k3s/infra/ansible/inventory/hosts.ini
   ```

3. **Run bootstrap playbook**:
   ```bash
   cd k3s/infra/ansible
   ansible-playbook playbooks/bootstrap.yml
   ```
   This installs k3s and bootstraps Flux.

4. **Flux reconciles** all applications automatically from Git — no manual steps needed.

5. **If the DB was on the failed node** (not the case in this architecture — DB is on a separate VPS), restore from S3 (see Scenario C).

---

### Scenario C — Postgres VPS failure

1. **Provision a new Postgres VPS**:
   ```bash
   cd k3s/terraform
   terraform apply   # or add a new resource block for the DB server
   ```

2. **Run bootstrap** for the new DB host:
   ```bash
   ansible-playbook playbooks/bootstrap.yml --limit postgres
   ```

3. **Restore the latest dump from S3**:
   ```bash
   # On the new Postgres VPS:
   aws s3 cp s3://<bucket>/postgres/<db>_latest.dump /tmp/restore.dump \
     --endpoint-url <s3_endpoint>

   pg_restore -U postgres -d myapp_db /tmp/restore.dump
   ```

4. **Update the k3s Secret** with the new DB host IP:
   ```bash
   kubectl create secret generic myapp-db \
     --from-literal=ConnectionStrings__Main="Host=<new-pg-ip>;Port=5432;Database=myapp_db;Username=appuser;Password=<pass>" \
     -n myapp \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

5. **Restart pods** to pick up the new connection string:
   ```bash
   kubectl rollout restart deployment/myapp -n myapp
   ```

---

### Scenario D — Full disaster (all VPS gone, restore from scratch)

```
Step 1: terraform apply
         ↓
Step 2: cloud-init runs automatically (SSH, UFW, base packages)
         ↓
Step 3: ansible-playbook playbooks/bootstrap.yml
         — installs k3s, postgres, Flux
         ↓
Step 4: Flux bootstraps from Git
         — all infra (cert-manager, ingress-nginx, cloudflared)
         — all apps (myapp HelmRelease)
         ↓
Step 5: Restore Postgres from S3 (Scenario C, step 3)
         ↓
Step 6: Update DB Secret → restart pods
         ↓
Step 7: DNS / Cloudflare Tunnel points to new nodes (auto via Terraform DNS record)
```

**RTO estimate:** 30–60 minutes (automated steps 1–4 dominate)
**RPO:** up to 24 hours (last nightly backup)

---

## Pre-disaster checklist (run periodically)

- [ ] Verify S3 bucket contains recent etcd snapshots: `aws s3 ls s3://<bucket>/etcd/`
- [ ] Verify S3 bucket contains recent pg_dump files: `aws s3 ls s3://<bucket>/postgres/`
- [ ] Test restore to a staging VPS at least quarterly
- [ ] Rotate secrets and update vault.yml accordingly
- [ ] Confirm `terraform plan` shows no unexpected drift
- [ ] Confirm `flux get all -A` shows all resources as `Ready`
