# ADR-002: Deployment Strategy

## Status
Accepted

## Context
We require no-downtime application updates and fast rollback without introducing Kubernetes.

## Decision
Use blue/green deployment with two local slots per application on `app-20` and Nginx upstream switching.

## Consequences
### Positive
- deterministic release flow
- fast rollback
- clear active vs inactive runtime state

### Negative
- duplicate runtime footprint on `app-20` for each application during deployment
- more deployment logic than a single-instance replace flow
