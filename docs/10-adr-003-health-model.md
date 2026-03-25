# ADR-003: Health Model

## Status
Accepted

## Context
The platform needs a health model that supports readiness-based traffic removal and graceful shutdown.

## Decision
Expose:
- `/.well-known/live`
- `/.well-known/ready`

`live` checks process liveness only.
`ready` checks startup completion, dependency availability, and draining state.

## Consequences
This health model can later be reused by more advanced platforms if the runtime evolves.
