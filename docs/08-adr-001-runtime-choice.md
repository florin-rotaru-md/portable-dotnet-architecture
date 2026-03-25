# ADR-001: Runtime Choice

## Status
Accepted

## Context
We need a portable deployment runtime for a small number of .NET services running on Linux VPS infrastructure.

## Decision
Use Docker Compose as the application runtime layer.

## Consequences
### Positive
- low complexity
- easy host portability
- simple debugging model
- minimal resource overhead

### Negative
- no native rolling update orchestration
- no advanced cluster scheduling

## Mitigation
Implement controlled blue/green switching through Nginx and deployment scripts.
