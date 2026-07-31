# Stage 4 — Network interfaces

*Part of the [Proxmox homelab guide](../README.md).*

All of this is done from the Proxmox UI: select the node → **System → Network**.

## 4.1 Management network — `vmbr0` on the onboard NIC

The installer already built this. Verify (and fix if needed):

1. Select the row **`vmbr0`** → **Edit**:
   - **IPv4/CIDR**: `192.168.0.11/24` (pve1) / `192.168.0.12/24` (pve2)
   - **Gateway (IPv4)**: `192.168.0.1`
   - **Bridge ports**: the onboard interface name (e.g. `eno1`, `enp0s31f6`)
   - **Autostart**: checked · **VLAN aware**: unchecked
2. **System → DNS** → Edit → DNS server 1: `192.168.0.1` (or `1.1.1.1`).

## 4.2 The 10G direct link

1. Connect pve1's X550 **port 1** to pve2's Thunderbolt adapter with a Cat6a cable. No switch.
2. On each node: **System → Network** → find the 10G interface (pve1: `enp…f0`; pve2: the adapter, name like `enx…`) → **Edit**:
   - **IPv4/CIDR**: `10.10.10.1/24` (pve1) / `10.10.10.2/24` (pve2)
   - **Gateway (IPv4)**: **leave empty** — a node must have exactly one default gateway, and `vmbr0` already has it
   - **Autostart**: checked
3. Press **Apply Configuration** (the yellow banner at the top). No reboot needed — Proxmox applies live via ifupdown2.

## 4.3 Verify

Node → **Shell**:
```bash
ip -br a                      # each interface with the expected address
ip route | grep default       # exactly ONE line, via vmbr0
ping -c3 10.10.10.2           # the direct link (from pve1)
ping -c3 8.8.8.8              # the default route
ethtool <10g-interface> | grep -i speed    # expect 10000Mb/s
```

Two default routes is the classic mistake here, and it produces a cluster that misbehaves for no obvious reason. If `ip route` shows more than one, remove the gateway from the 10G interface.

## 4.4 For reference — the resulting config

`/etc/network/interfaces` on pve1 ends up looking like this. Useful for verification, and editable directly if you prefer (apply with `ifreload -a`):

```
auto lo
iface lo inet loopback

iface eno1 inet manual              # onboard — bridge port, no IP of its own

auto vmbr0
iface vmbr0 inet static
    address 192.168.0.11/24
    gateway 192.168.0.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

auto enp2s0f0
iface enp2s0f0 inet static
    address 10.10.10.1/24           # 10G direct link — no gateway
```

pve2 is identical with `.12` / `10.10.10.2`, and different interface names.

> If you lose the web UI after Apply Configuration, you changed the wrong bridge port. Go to the machine's physical console, fix `/etc/network/interfaces` with `nano`, then `ifreload -a`.
