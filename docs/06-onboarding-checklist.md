# Onboarding Checklist

## For a new engineer or operator

### Read first
- `README.md`
- `docs/01-architecture-overview.md`
- `docs/02-deployment-strategy.md`
- `docs/03-graceful-shutdown.md`
- `docs/04-backup-and-restore.md`

### Understand these concepts
- per-application blue/green slot model
- liveness vs readiness
- graceful shutdown flow
- separation of `app-20` and `db-30`
- how Ansible owns host setup
- how deployment metadata is stored
- why each application needs a unique `server_name`, `blue_port`, and `green_port`

### Required access
- source repository
- container registry
- `app-20` SSH
- `db-30` SSH
- DNS provider access
- backup destination access

### First exercises
- inspect an active slot file under `/opt/apps/<app-name>/runtime/active-slot`
- run a dry deployment in a non-production environment
- perform a restore test in a disposable environment
- trace the full request path from Nginx to the app
