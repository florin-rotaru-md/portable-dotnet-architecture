# Portable .NET Production Architecture

This package contains a production-oriented reference implementation for a portable VPS deployment model built around:

- .NET services
- PostgreSQL
- Linux VPS hosts
- Docker Compose
- Nginx
- Ansible
- Blue/Green deployments

It is designed to support:

- provider portability
- reproducible setup
- reproducible configuration
- stable deployments
- zero-downtime application updates
- graceful shutdown and request draining
- reliable backups and restore procedures
- fast rollback
- onboarding, tracking, and controlled future updates

## High-level topology

- **app-20**: Nginx + multiple application runtimes, each with its own `blue` and `green` slots + deployment scripts
- **db-30**: PostgreSQL runtime + backup jobs + restore scripts
- **External services**: DNS provider independent from VPS, external backup storage, container registry

## Core concepts

### Blue/Green deployment
Each application on `app-20` has its own blue/green pair.

1. Detect the active slot for the target application.
2. Start the inactive slot for that application with the new image.
3. Wait until `/.well-known/ready` returns success.
4. Switch the Nginx upstream for that application to the new slot.
5. Allow a drain period for in-flight requests.
6. Stop the old slot for that application.

### Health model
- `/.well-known/live`: process liveness only
- `/.well-known/ready`: readiness for new traffic

During shutdown:
- `live` remains healthy briefly
- `ready` becomes unhealthy immediately

This allows traffic to stop flowing to the old instance before runtime termination.

## Package layout

- `docs/` Architecture, ADRs, onboarding, operations, rollout, backup, and change tracking
- `infra/ansible/` Provisioning and configuration management
- `deploy/` Runtime compose files, Nginx switching configs, deployment scripts
- `ops/` Backup and restore helpers
- `src/MyApp/` Example .NET application with graceful draining support
- `.github/workflows/` Example CI pipeline

## Intended usage

Use this package as a baseline and adapt:

- hostnames such as `ansible-control`, `app-20`, and `db-30`
- application names, unique server names, and port pairs in `applications`
- image names
- secrets
- environment variables
- backup destinations
- firewall rules
- database sizing and retention

## Important notes

- This is a template, not a turnkey production deployment.
- Secrets are represented as placeholders and must be replaced by secure values.
- Test all backup and restore procedures before relying on them.
- Validate graceful shutdown behavior with long-running requests before going live.
