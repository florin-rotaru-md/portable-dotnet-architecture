terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.61"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Recommended: use remote state
  # backend "s3" { ... }
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "proxmox" {
  endpoint  = var.proxmox_endpoint   # e.g. "https://192.168.1.10:8006/"
  api_token = var.proxmox_api_token  # e.g. "root@pam!terraform=<uuid>"
  insecure  = var.proxmox_insecure   # true if using self-signed TLS

  ssh {
    agent    = true
    username = var.proxmox_ssh_user
    # private_key = file("~/.ssh/id_ed25519_devops")  # uncomment if agent not available
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── cloud-init snippet files ───────────────────────────────────────────────────
# Proxmox must have snippets enabled on the target datastore.
# See docs/proxmox-setup.md — "Enable snippets storage".

resource "proxmox_virtual_environment_file" "cloud_init_server" {
  count        = var.server_count
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/../cloud-init/user-data.yml", {
      ssh_public_key = var.ssh_public_key
      hostname       = "${var.cluster_name}-server-${count.index + 1}"
    })
    file_name = "${var.cluster_name}-server-${count.index + 1}-ci.yml"
  }
}

resource "proxmox_virtual_environment_file" "cloud_init_db" {
  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/../cloud-init/user-data.yml", {
      ssh_public_key = var.ssh_public_key
      hostname       = "${var.cluster_name}-db-1"
    })
    file_name = "${var.cluster_name}-db-1-ci.yml"
  }
}

# ── k3s server VMs ────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "k3s_server" {
  count     = var.server_count
  name      = "${var.cluster_name}-server-${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = var.server_vmid_start + count.index

  tags = ["k3s-server", var.cluster_name]

  # Clone from the Ubuntu cloud-init template (see docs/proxmox-setup.md)
  clone {
    vm_id = var.vm_template_id
    full  = true
  }

  cpu {
    cores = var.server_cores
    type  = "host"
  }

  memory {
    dedicated = var.server_memory_mb
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.server_disk_gb
    interface    = "scsi0"
    discard      = "on"
    iothread     = true
  }

  # External bridge (access from LAN / cloudflared)
  network_device {
    bridge = var.bridge_external
    model  = "virtio"
  }

  # Internal bridge for cluster communication (k3s etcd, flannel)
  network_device {
    bridge = var.bridge_internal
    model  = "virtio"
  }

  agent {
    enabled = true   # requires qemu-guest-agent in the template
  }

  initialization {
    ip_config {
      ipv4 {
        # Static: "192.168.10.1${count.index + 1}/24"  gw = "192.168.10.1"
        # DHCP:
        address = "dhcp"
      }
    }
    # Internal NIC — static IP on cluster subnet
    ip_config {
      ipv4 {
        address = "10.10.0.1${count.index + 1}/24"
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_server[count.index].id
  }

  lifecycle {
    ignore_changes = [clone, initialization]
  }
}

# ── Postgres VM ───────────────────────────────────────────────────────────────
resource "proxmox_virtual_environment_vm" "postgres" {
  name      = "${var.cluster_name}-db-1"
  node_name = var.proxmox_node
  vm_id     = var.db_vmid

  tags = ["postgres", var.cluster_name]

  clone {
    vm_id = var.vm_template_id
    full  = true
  }

  cpu {
    cores = var.db_cores
    type  = "host"
  }

  memory {
    dedicated = var.db_memory_mb
  }

  disk {
    datastore_id = var.storage_pool
    size         = var.db_disk_gb
    interface    = "scsi0"
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = var.bridge_external
    model  = "virtio"
  }

  # Same internal bridge so k3s nodes can reach Postgres privately
  network_device {
    bridge = var.bridge_internal
    model  = "virtio"
  }

  agent {
    enabled = true
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    ip_config {
      ipv4 {
        address = "10.10.0.50/24"   # static internal IP for DB
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_db.id
  }

  lifecycle {
    ignore_changes = [clone, initialization]
  }
}

# ── Cloudflare DNS (optional — skip if VMs have no public IPs) ────────────────
resource "cloudflare_record" "k3s_server" {
  count   = var.cloudflare_zone_id != "" ? var.server_count : 0
  zone_id = var.cloudflare_zone_id
  name    = "${var.cluster_name}-server-${count.index + 1}"
  value   = proxmox_virtual_environment_vm.k3s_server[count.index].ipv4_addresses[0][0]
  type    = "A"
  proxied = false
}
