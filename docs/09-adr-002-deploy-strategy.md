# ADR-002: Deployment Strategy

## Status
Accepted

## Context
We require no-downtime application updates and fast rollback without introducing Kubernetes.

## Decision
Use blue/green deployment with two local slots on the application host and Nginx upstream switching.

## Consequences
### Positive
- deterministic release flow
- fast rollback
- clear active vs inactive runtime state

### Negative
- duplicate runtime footprint on the app host during deployment
- more deployment logic than a single-container replace flow
