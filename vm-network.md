# VM Network - Static IP Setup

This guide configures a static IP on a Linux VM (Ubuntu/Debian) using the following values:

- IP: `192.168.0.32`
- Netmask: `255.255.255.0` (`/24`)
- Gateway: `192.168.0.1`
- DNS: `192.168.0.1`

## 1) Identify the network interface

Run:

```bash
ip a
```

Note the active interface name (for example `ens18`, `eth0`, or `enp0s3`).

## 2) Configure Netplan (Ubuntu 20.04+)

Edit the Netplan file (for example `/etc/netplan/00-installer-config.yaml`):

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      addresses:
        - 192.168.0.32/24
      routes:
        - to: default
          via: 192.168.0.1
      nameservers:
        addresses:
          - 192.168.0.1
```

Important: replace `ens18` with your actual interface name.

Apply the settings:

```bash
sudo netplan try
sudo netplan apply
```

## 3) Verify the configuration

```bash
ip a
ip route
resolvectl status
ping -c 4 192.168.0.1
ping -c 4 1.1.1.1
```

## 4) (Optional) Alternative for /etc/network/interfaces

If your VM uses `ifupdown` instead of Netplan, add this to `/etc/network/interfaces`:

```ini
auto ens18
iface ens18 inet static
  address 192.168.0.32
  netmask 255.255.255.0
  gateway 192.168.0.1
  dns-nameservers 192.168.0.1
```

Then run:

```bash
sudo systemctl restart networking
```
