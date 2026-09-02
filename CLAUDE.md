# CLAUDE.md

Infrastructure for the Waa/Educa platform. The application repositories are siblings:
`platform/` (backend, start at `platform/docs/START-HERE.md`) and `ui/waa-src/` (frontend).

## What is live, and what is a reference

- **`native/infra/ansible`** — everything inside the VMs: users, .NET runtime, Nginx, PostgreSQL,
  the blue/green deploy script, cloudflared. This is what production runs.
- **`proxmox-lab/`** — the two hosts those VMs live on: cluster, QDevice, ZFS replication, HA,
  backups, the WAL stream, the drill book. A build-and-operate guide, written to be followed
  top-to-bottom the first time and used by symptom afterwards (see its README's *Reading paths*).
- **`perf/`** — load-testing harness; applies to whichever setup is running.
- **`docker/`, `k3s/`, `k3s-proxmox/`, `hyper-v/`** — alternatives. Nothing serves traffic from
  them. They are kept as references and their example files are mirrored **by hand**, which is why
  they drift.

## Rules that are easy to get wrong here

- **The inventory is not in this repository.** It lives at `d:/git/ansible/inventory` on the
  workstation and `~/app-inventory` on the control VM, deliberately outside the clone so a
  `git pull` cannot collide with operator edits. `vault.yml` there is **plaintext** and holds real
  credentials — treat a copy of that directory as a credential.
- **A `group_vars` or role change must be mirrored** into `native/example` and the other setups'
  example files. Nothing enforces it; `hyper-v/example` has already drifted hundreds of lines from
  the `native` one it is supposed to mirror.
- **The hosts are hand-managed and this guide is their documentation** — there is no Ansible for
  Proxmox itself. If you change a host, the guide is where that change is recorded, in the same
  commit.
- **The `native` postgres role is the only PostgreSQL configuration.** A hand-written
  `postgres.md` used to sit at the root with a pasted stock `postgresql.conf`; it did strictly less
  than the role (no tuning, no observability, no backups, no WAL stream) and was deleted. Tuning
  lives in `roles/postgres/templates/tuning.conf.j2`, derived from the VM's RAM.
- Application-side operations (deploy order, restart-required settings, reading a failed boot) live
  in `platform/docs/OPERATIONS.md` §1 and §5, not here.

## Citing across repositories

Prefix the path: `platform/docs/adr/0015-…md`, `waa-src/cloudflare/README.md`. An unqualified
`docs/…` is ambiguous between three repositories and has already gone stale twice.
