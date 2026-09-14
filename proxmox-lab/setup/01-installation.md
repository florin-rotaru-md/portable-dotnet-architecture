# Stage 1 — Proxmox installation (identical on both nodes)

*Part of the [Proxmox lab guide](../README.md).*

1. Boot from the stick → **Install Proxmox VE (Graphical)** → accept the EULA.
2. **Target Harddisk: disk 1 (OS).** Careful not to pick the data disks. Default filesystem (ext4/LVM).
   - **Options** (beside the disk) → Filesystem `ext4` → **`maxvz` = `0`**; leave the other fields as they are. Every VM disk lives on the ZFS pools (Stage 6), so the installer's default `local-lvm` thin pool would only hold space hostage: with `maxvz 0` it is never created, and the OS disk belongs to `local`, where backups stage ([17.2](../backup/17-backup-restore.md#172-local-staging--local-on-each-node)). The installer still caps the root volume at about a quarter of the disk plus 12 GB whatever `maxroot` says, and leaves the rest free in the volume group — step 7 hands it over.
3. Romania / Europe/Bucharest.
4. Root password + email.
5. Network: pick the **onboard 1G NIC** (that's the management network). Hostname `pve1.local` / `pve2.local`, IP 192.168.0.11 / .12, gateway 192.168.0.1, DNS.
   - The 10G interface is configured afterwards, in Stage 5.2 — the installer doesn't need it.
6. Install → reboot → remove the stick.
7. First login (node → **Shell**): give the root volume the rest of the OS disk. The ext4 filesystem grows online.
   ```bash
   lvs pve                              # root and swap only — no data volume
   lvextend -r -l +100%FREE pve/root
   df -h /                              # ~360G on pve1, ~465G on pve2
   ```

Web access: `https://192.168.0.11:8006` (login `root`; the certificate warning is normal).
