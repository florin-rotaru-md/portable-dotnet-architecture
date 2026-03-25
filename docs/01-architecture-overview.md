# Architecture Overview

## Objectives

The architecture is intentionally optimized for operational clarity and portability rather than platform complexity.

Primary objectives:

1. Recreate hosts quickly on a new VPS provider.
2. Keep application runtime consistent across environments.
3. Deploy new application versions without visible downtime.
4. Drain in-flight requests before old instances are stopped.
5. Keep database lifecycle separate from application lifecycle.
6. Maintain explicit backup and restore processes.

## Recommended topology

### app-20: Application host
Responsibilities:
- reverse proxy (Nginx)
- blue/green application containers
- deployment scripts
- environment configuration files
- operational metadata (active slot, active image)

### db-30: Database host
Responsibilities:
- PostgreSQL runtime
- backup jobs
- backup retention
- restore tooling
- restricted network exposure

### External dependencies
- DNS provider independent from the VPS provider
- external artifact/container registry
- external backup target (S3-compatible, separate VPS, or object storage)

## Why this design

### Why Docker Compose
- simple runtime model
- highly portable across Linux VPS providers
- predictable debugging model
- low operational overhead

### Why Ansible
- reproducible host configuration
- provider-independent bootstrap
- useful even for a single VPS
- supports controlled upgrades and drift reduction

### Why Nginx
- stable and widely understood reverse proxy
- reload without dropping active connections
- enough control for blue/green slot switching

### Why not Kubernetes for this baseline
- higher operational complexity
- more moving parts than needed for a small number of services
- PostgreSQL operations are usually simpler outside Kubernetes at this stage

## Traffic flow

1. Client requests reach Nginx.
2. Nginx forwards requests to the currently active slot (`blue` or `green`).
3. A new release is launched on the inactive slot.
4. After readiness succeeds, Nginx is reloaded to point to the new slot.
5. Old slot stops receiving new traffic.
6. Old slot drains in-flight requests.
7. Old slot is stopped after the drain window.

## Failure isolation

- Application release problems on `app-20` can be rolled back without touching `db-30`.
- Database issues do not require redeploying the application runtime.
- Provider migration is reduced to reprovisioning hosts + restoring data + flipping DNS.
