# Cloudflare Tunnel — placement in the new setup

*Part of the [waa Proxmox homelab guide](../README.md).*

Run `cloudflared` **inside the app VM (1020)**, not on the Proxmox host. That way the tunnel migrates together with the VM, and on an HA failover it restarts automatically on the healthy node — public exposure follows the application with zero intervention.
