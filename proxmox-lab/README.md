# Production infrastructure

Two Proxmox nodes (`pve1` .11, `pve2` .12), separate QDevice (.10), four Ubuntu VMs on
`192.168.0.0/24`. `native/infra/ansible` manages guest services; the hosts are managed directly.

| VM | Role | Recovery |
|---|---|---|
| 1020 / .20 | Ansible control and installation inventory | Hourly replica; manual node-loss recovery |
| 1021 / .21 | Nginx, cloudflared, Waa RO/Events and Fiscal blue/green slots | HA; hourly replica |
| 1022 / .22 | PostgreSQL and app/users/DP databases | HA; minute replica |
| 1023 / .23 | Loki and Grafana | Hourly replica; manual node-loss recovery |

Read-only verification on 2026-09-14: both nodes quorate, pools ONLINE, four guests on pve1,
replication current, HA owns 1021/1022. LAN is the permanent link; direct 10G is optional.
Data pools are single disks, not mirrors.

| Task | Document |
|---|---|
| Install/rebuild hardware, cluster or VMs | [Build](BUILD.md) |
| Check health, maintain, migrate, update or diagnose | [Operations](OPERATIONS.md) |
| Understand actual backup coverage and recover | [Recovery](RECOVERY.md) |
| Install/use host helpers | [Scripts](scripts/README.md) |
| Apply guest configuration | [Native provisioning](../native/README.md) |
| Deploy/operate applications | [Platform operations](../../platform/docs/OPERATIONS.md) |

**Backup state:** encrypted Digi backups are active for PostgreSQL WAL/base/logical data, all four
VM images and both host configurations. Daily verification passes on both nodes, and an isolated
VM 1021 restore from Digi passed. The remaining recovery proofs are an isolated logical restore,
an actual PITR replay and the Fiscal counter/key-ring procedure; see [Recovery](RECOVERY.md).

`docker`, `k3s`, `k3s-proxmox` and `hyper-v` are alternative reference setups. They are outside this
production operating path; do not mirror production documentation into them.
