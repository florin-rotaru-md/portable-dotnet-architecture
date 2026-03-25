# Deployment Strategy

## Deployment goals

- no downtime during application update
- minimal operator steps
- fast rollback
- deterministic slot selection
- explicit health verification before cutover

## Slot model

Two application slots exist on `app-20`:
- `blue`
- `green`

Exactly one slot is active in Nginx at a time.
The inactive slot is used for the next release.

## Deployment sequence

1. Read the current active slot.
2. Select the inactive slot as target.
3. Pull the requested image.
4. Start target slot.
5. Poll `/.well-known/ready` until success or timeout.
6. Update Nginx active upstream config to target slot.
7. Reload Nginx.
8. Wait for drain window.
9. Stop old slot gracefully.
10. Persist deployment metadata (`active-slot`, `active-image`, deployment history).

## Rollback sequence

### Fast rollback
Use when the previous slot is still running.

1. Switch Nginx back to previous slot.
2. Reload Nginx.
3. Record rollback event.

### Full rollback
Use when the old slot has already been stopped.

1. Start previous image on inactive slot.
2. Wait for readiness.
3. Switch Nginx.
4. Stop bad release slot.

## Readiness rules

A slot is eligible for cutover only if:
- process has completed startup
- critical dependencies are reachable
- application is not in draining mode

## Liveness rules

Liveness only confirms the application process is alive and responsive enough for runtime supervision.
It should not depend on the database or third-party services.

## Deployment metadata

Recommended runtime files:
- `/opt/myapp/runtime/active-slot`
- `/opt/myapp/runtime/active-image`
- `/opt/myapp/runtime/deploy-history.log`

These files simplify troubleshooting, audit, and rollback.
