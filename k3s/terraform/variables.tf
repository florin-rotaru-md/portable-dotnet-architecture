variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit permissions"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the target domain"
  type        = string
}

variable "cluster_name" {
  description = "Short identifier used to name all resources"
  type        = string
  default     = "prod"
}

variable "server_count" {
  description = "Number of k3s server (control-plane) nodes"
  type        = number
  default     = 1
}

variable "server_type" {
  description = "Hetzner server type for k3s nodes"
  type        = string
  default     = "cx22"   # 2 vCPU, 4 GB RAM
}

variable "db_server_type" {
  description = "Hetzner server type for the Postgres node"
  type        = string
  default     = "cx22"
}

variable "server_image" {
  description = "OS image for all servers"
  type        = string
  default     = "ubuntu-24.04"
}

variable "location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"   # Nuremberg
}

variable "ssh_public_key" {
  description = "SSH public key to install on all servers"
  type        = string
}
