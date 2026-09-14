# Infrastructure working rules

Start at [Proxmox](proxmox-lab/README.md) for hosts and [native](native/README.md) for VM provisioning.
Application operation is owned by [platform](../platform/docs/OPERATIONS.md); frontends are in
the sibling `ui` repository (`waa-src`, `educa-src`).

- `native/infra/ansible` owns users, runtime, Nginx, PostgreSQL, deploy scripts and tunnel inside VMs.
- `proxmox-lab` owns hand-managed hosts, quorum, ZFS, HA, maintenance and recovery. Update the owning
  guide with host changes; distinguish repository targets from verified installed behavior.
- `perf` contains the load harness. `docker`, `k3s`, `k3s-proxmox` and `hyper-v` are alternatives.
- Inventory is outside Git: workstation `D:/git/ansible/inventory`, control `~/app-inventory`.
  Workstation files are heredoc recipes. `vault.yml` is plaintext; protect every copy as a credential.
- Reflect role/input changes in `native/example` and the corresponding alternative examples when
  applicable. Check them explicitly; they are maintained by hand.
- The native postgres role owns PostgreSQL configuration. Inspect runtime before declaring tuning,
  archiving or backup behavior active. Recovery acceptance is in [Recovery](proxmox-lab/RECOVERY.md).
- Use workspace-qualified source citations, for example `platform/docs/ARCHITECTURE.md#storage`
  or `ui/waa-src/cloudflare/README.md#public-media`. Use relative Markdown links in documents.
- Keep current procedures and constraints. Consolidate obsolete plans and update their source refs;
  do not add a second history or status tracker.
