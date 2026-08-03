# Stage 8 — QDevice (mandatory for maintenance with one node down)

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

The QDevice earns its keep twice: besides the third vote, it later receives the continuous Postgres WAL stream ([Stage 13](../ha/13-wal-stream.md)) — the box (Core Ultra 5 225U, 16GB, 2TB NVMe) has headroom for both without noticing.

Give it the same firmware baseline the nodes got in [2.2](../setup/02-post-install.md#22-update-microcode-and-reboot) — it's a full third of the cluster's quorum, not an accessory:

```bash
apt install -y intel-microcode fwupd    # stock Debian repos already carry both
fwupdmgr get-devices                    # is this box on LVFS at all? (16.3)
```

Most mini PCs are *not* on LVFS, and [16.3](../operations/16-maintenance.md#163-firmware--detect-always-flash-rarely) covers what that means for it — including the reason it's the machine you flash *first* when a firmware round comes: with both nodes up, losing the QDevice for a reboot still leaves the cluster quorate.
