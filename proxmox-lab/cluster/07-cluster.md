# Stage 7 — Cluster

*Part of the [Proxmox lab guide](../README.md).*

**On pve1:** Datacenter → Cluster → **Create Cluster** → name `lab`:
- **Link 0** = `10.10.10.1` (the 10G direct link — corosync's primary ring)
- **Link 1** = `192.168.0.11` (the management network — backup ring)

→ Create → **Join Information → Copy**.

**On pve2:** Datacenter → Cluster → **Join Cluster** → paste the info, pve1's root password:
- **Link 0** = `10.10.10.2`
- **Link 1** = `192.168.0.12`

→ Join. The page will "freeze" (certificates change) — reload the browser.

Verify both rings are up:
```bash
corosync-cfgtool -s     # LINK ID 0 and LINK ID 1 both "status = OK"
```

**Migration Settings:** Datacenter → Options → Migration Settings → Network = `10.10.10.0/24`.

Set a bandwidth limit of ~800 MB/s there. The link is dedicated, so you don't need to protect VM traffic — but leaving headroom keeps corosync's primary ring free of jitter during a large replication.
