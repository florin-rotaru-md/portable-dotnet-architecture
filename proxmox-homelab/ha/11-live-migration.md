# Stage 11 — First live migration 🎯

*Part of the [waa Proxmox homelab guide](../README.md).*

1. From another computer: `ping -t 192.168.0.20`.
2. Right-click on the VM → **Migrate** → Target: the other node → Migrate.
3. "migration finished successfully" — the ping continues uninterrupted (at most 1 lost packet). Migrate it back as well.
