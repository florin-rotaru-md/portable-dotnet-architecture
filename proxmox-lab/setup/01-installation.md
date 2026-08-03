# Stage 1 — Proxmox installation (identical on both nodes)

*Part of the [Proxmox lab guide](../README.md).*

1. Boot from the stick → **Install Proxmox VE (Graphical)** → accept the EULA.
2. **Target Harddisk: disk 1 (OS).** Careful not to pick the data disks. Default filesystem (ext4/LVM).
3. Romania / Europe/Bucharest.
4. Root password + email.
5. Network: pick the **onboard 1G NIC** (that's the management network). Hostname `pve1.local` / `pve2.local`, IP 192.168.0.11 / .12, gateway 192.168.0.1, DNS.
   - The 10G interface is configured afterwards, in Stage 5.2 — the installer doesn't need it.
6. Install → reboot → remove the stick.

Web access: `https://192.168.0.11:8006` (login `root`; the certificate warning is normal).
