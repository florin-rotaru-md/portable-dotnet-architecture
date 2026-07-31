# Stage 7 — QDevice (mandatory for maintenance with one node down)

*Part of the [Proxmox homelab guide](../README.md).*

On the third device (Debian/Ubuntu, fixed IP reachable from both nodes):
```bash
apt update && apt install corosync-qnetd
```

On BOTH Proxmox nodes:
```bash
apt install corosync-qdevice
```

On pve1 ONLY:
```bash
pvecm qdevice setup <third-device-IP>
```

Verify:
```bash
pvecm status    # Total votes: 3, Quorate: Yes
```

The QDevice earns its keep twice: besides the third vote, it later receives the continuous Postgres WAL stream ([Stage 11](../ha/11-wal-stream.md)) — the box (Core Ultra 5 225U, 16GB, 2TB NVMe) has headroom for both without noticing.
