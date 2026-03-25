# Backup and Restore

## Principles

A backup is only useful if restore is documented and tested.

## Database backup levels

### Logical backups
Use `pg_dump` or `pg_dump -Fc` for:
- migration between providers
- schema/object inspection
- clean restore workflows

### Physical or WAL-based strategy
Consider base backups + WAL archiving for:
- point-in-time recovery
- lower RPO targets
- larger databases

## File backup scope

Back up only persistent data:
- uploaded files
- exported artifacts
- runtime state that must survive reprovisioning

Do not rely on local container writable layers.

## Recommended offsite policy

Send backups to storage independent from the active VPS provider.
Examples:
- S3-compatible object storage
- a second VPS in another location
- dedicated backup storage

## Restore goals

Document:
- how to restore PostgreSQL from logical backup
- how to restore persistent file data
- how to validate application startup after restore
- how to verify the app is serving traffic successfully

## Minimum restore test cadence

At least:
- after major infrastructure changes
- after PostgreSQL major version changes
- periodically on a disposable environment
