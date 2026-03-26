# Operations Runbook

## Standard operations

### Bootstrap or replace app-20
1. Provision fresh Linux VPS.
2. Install SSH key access.
3. Update `infra/ansible/inventory/production.ini`.
4. Review `infra/ansible/group_vars/all.yml` and define the `applications` list with unique names, server names, and blue/green ports.
5. Run Ansible app bootstrap playbook.
6. Copy secrets and environment files for each application runtime.
7. Validate Nginx and Docker.

### Bootstrap or replace db-30
1. Provision fresh Linux VPS.
2. Update inventory.
3. Run DB bootstrap playbook.
4. Confirm PostgreSQL runtime is running.
5. Configure backup destination.
6. Restore database if needed.
7. Validate firewall and connectivity from `app-20`.

### Deploy a release
1. Ensure image exists in registry.
2. Run the target application deploy script with the image tag.
3. Confirm readiness and active slot for that application.
4. Verify app health externally using the application hostname.
5. Record release in tracking file or ticket.

### Roll back a release
1. Run the rollback script for the target application or redeploy the previous image.
2. Confirm traffic has switched back for that application.
3. Investigate failed release.
4. Preserve logs and deployment metadata.

## Incident reminders

During incidents, prefer:
- preserving evidence
- capturing active slot and image tag
- checking readiness and liveness separately
- avoiding ad-hoc manual edits not reflected in source control
