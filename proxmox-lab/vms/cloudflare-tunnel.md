# Cloudflare Tunnel — placement in the new setup

*Part of the [Proxmox lab guide](../README.md).*

Run `cloudflared` **inside the app VM (1021)**, not on the Proxmox host. That way the tunnel migrates together with the VM, and on an HA failover it restarts automatically on the healthy node — public exposure follows the application with zero intervention.

Upgrading it is a variable bump, not an `apt install` on the box: `cloudflared_version` in `group_vars`, then `bootstrap.yml --limit app --tags cloudflared`. Nothing moves it on its own — the unit runs `--no-autoupdate` and unattended-upgrades covers only the PGDG origin — so [20.5](../operations/20-upgrades.md#205-the-same-pattern-applied-elsewhere) has the window, the visible-restart caveat and the rollback.
