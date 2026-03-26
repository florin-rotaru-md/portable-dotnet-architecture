terraform {
  required_version = ">= 1.6"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Recommended: use remote state (e.g. Terraform Cloud, S3+DynamoDB, etc.)
  # backend "s3" { ... }
}

# ── Providers ─────────────────────────────────────────────────────────────────
provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ── SSH key ───────────────────────────────────────────────────────────────────
resource "hcloud_ssh_key" "default" {
  name       = "${var.cluster_name}-key"
  public_key = var.ssh_public_key
}

# ── k3s server nodes ──────────────────────────────────────────────────────────
resource "hcloud_server" "k3s_server" {
  count       = var.server_count
  name        = "${var.cluster_name}-server-${count.index + 1}"
  server_type = var.server_type
  image       = var.server_image
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  user_data = templatefile("${path.module}/../cloud-init/user-data.yml", {
    ssh_public_key = var.ssh_public_key
    hostname       = "${var.cluster_name}-server-${count.index + 1}"
  })

  labels = {
    role    = "k3s-server"
    cluster = var.cluster_name
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

# ── Postgres VPS (external, separate from k3s cluster) ───────────────────────
resource "hcloud_server" "postgres" {
  name        = "${var.cluster_name}-db-1"
  server_type = var.db_server_type
  image       = var.server_image
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.default.id]

  user_data = templatefile("${path.module}/../cloud-init/user-data.yml", {
    ssh_public_key = var.ssh_public_key
    hostname       = "${var.cluster_name}-db-1"
  })

  labels = {
    role    = "postgres"
    cluster = var.cluster_name
  }
}

# ── Private network ───────────────────────────────────────────────────────────
resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-net"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "cluster" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.0.1.0/24"
}

resource "hcloud_server_network" "k3s_server" {
  count     = var.server_count
  server_id = hcloud_server.k3s_server[count.index].id
  network_id = hcloud_network.cluster.id
}

resource "hcloud_server_network" "postgres" {
  server_id  = hcloud_server.postgres.id
  network_id = hcloud_network.cluster.id
}

# ── DNS records ───────────────────────────────────────────────────────────────
resource "cloudflare_record" "k3s_server" {
  count   = var.server_count
  zone_id = var.cloudflare_zone_id
  name    = "${var.cluster_name}-server-${count.index + 1}"
  value   = hcloud_server.k3s_server[count.index].ipv4_address
  type    = "A"
  proxied = false
}
