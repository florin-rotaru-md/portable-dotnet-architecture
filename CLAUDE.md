# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repository Is

A production-oriented reference architecture for deploying .NET services on portable Linux VPS infrastructure using Docker Compose, Nginx, and Ansible. The `.NET app` in `src/MyApp/` is a minimal example demonstrating health check and graceful shutdown patterns. The bulk of the work is in infrastructure-as-code (`infra/ansible/`) and deployment automation (`deploy/`).

## Build & Run Commands

```bash
# Build the application
dotnet build src/MyApp/MyApp.csproj

# Run locally
dotnet run --project src/MyApp/MyApp.csproj

# Publish (release)
dotnet publish src/MyApp/MyApp.csproj -c Release

# Build Docker image
docker build -t myapp src/MyApp/

# Run container
docker run -p 8080:8080 myapp
```

There are no test projects. The `/slow` endpoint (15s delay) is the manual test for graceful shutdown behavior.

## Architecture Overview

### Application Layer (`src/MyApp/`)

The app demonstrates two patterns:

**Two-tier health checks:**
- `/.well-known/live` — Liveness probe. Always healthy (process is alive). Used by Docker `HEALTHCHECK`.
- `/.well-known/ready` — Readiness probe. Returns healthy only when startup is complete, not draining, and `ConnectionStrings__Main` is set. This is what the deployment script polls before cutting traffic over.

**Graceful shutdown:**
- `AppLifetimeState` holds two volatile bool flags: `StartupCompleted` and `IsDraining`.
- `StartupStateHostedService` sets `StartupCompleted = true` after simulated startup work, and the ready check flips unhealthy when the app stopping event fires.
- Shutdown timeout is 60 seconds, giving in-flight requests time to complete.

### Infrastructure Layer

**Blue/green deployment model:**
- Each app runs as two Docker containers (`<app>-blue`, `<app>-green`). One is live, one is idle.
- Nginx switches traffic by swapping which `upstream-{blue|green}.conf` is active and reloading (zero-downtime).
- Deployment sequence: start idle slot → poll `/.well-known/ready` → switch Nginx → drain old slot (default 20–30s) → stop old slot.

**Host topology:**
- `app-20` (192.168.0.20) — Nginx + Docker containers
- `db-30` (192.168.0.30) — PostgreSQL Docker container + backup cron jobs

**Ansible roles:**
- `common` — base packages, `deploy` user, UFW firewall
- `docker` — Docker engine, docker-compose-v2, `app_net` network
- `app_host` — per-app directory structure, compose files, env files, deployment scripts
- `nginx` — Nginx install, per-app site configs, upstream configs
- `db_host` — native PostgreSQL install (PGDG apt repo), `pg_hba.conf` template, `listen_addresses`, UFW rule for port 5432
- `backup` — pg_dump cron job (2:15 AM daily)

### Runtime Scripts (`deploy/scripts/` via Ansible templates)

Each application gets these scripts rendered to `/opt/apps/<app>/scripts/`:
- `deploy.sh` — full deployment orchestration
- `rollback.sh` — switches Nginx back to the previous slot immediately
- `switch-nginx.sh` — swaps upstream conf and reloads Nginx
- `current-slot.sh` — reads active slot from file or Nginx config
- `health-check.sh` — polls `/.well-known/ready` (default: 45 attempts × 2s = 90s max)

### Application Configuration

Apps are defined in `infra/ansible/group_vars/all.yml` under `applications[]`. Each entry specifies:
- `name`, `server_name`, `blue_port`, `green_port`, `internal_port`
- `image_default` — default Docker image to use
- `drain_seconds` — how long to wait after Nginx switch before stopping the old slot

Environment files are written to `/opt/apps/<app>/env/` on the host:
- `common.env` — `ASPNETCORE_URLS`, `DOTNET_ENVIRONMENT`, `ConnectionStrings__Main`
- `blue.env` / `green.env` — `SLOT_NAME=blue` or `SLOT_NAME=green`

## CI/CD

GitHub Actions (`.github/workflows/build-image.yml`) builds and pushes a multi-arch Docker image to `ghcr.io` on push to `main`. Deployment is manual — run `deploy.sh` on the target host.

## Key Documentation

- `docs/01-architecture-overview.md` — design objectives and topology
- `docs/02-deployment-strategy.md` — slot model, deployment sequence, rollback
- `docs/03-graceful-shutdown.md` — health check and shutdown implementation details
- `docs/05-operations-runbook.md` — bootstrap and deployment procedures
- `docs/08-adr-001-runtime-choice.md` through `docs/10-adr-003-health-model.md` — ADRs explaining why Docker Compose, blue/green, and two-tier health checks were chosen
