# ── Proxmox connection ────────────────────────────────────────────────────────
variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://192.168.1.10:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token — format: user@realm!tokenid=uuid"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification (for self-signed certs)"
  type        = bool
  default     = false
}

variable "proxmox_ssh_user" {
  description = "SSH user for Proxmox host (used by provider for file uploads)"
  type        = string
  default     = "root"
}

variable "proxmox_node" {
  description = "Name of the Proxmox node that will host the VMs"
  type        = string
  default     = "pve"
}

# ── VM template ───────────────────────────────────────────────────────────────
variable "vm_template_id" {
  description = "VMID of the Ubuntu cloud-init template (see docs/proxmox-setup.md)"
  type        = number
  default     = 9000
}

variable "snippets_datastore" {
  description = "Proxmox datastore with snippets content enabled"
  type        = string
  default     = "local"
}

variable "storage_pool" {
  description = "Proxmox storage pool for VM disks"
  type        = string
  default     = "local-lvm"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "bridge_external" {
  description = "Proxmox bridge for external (LAN) traffic"
  type        = string
  default     = "vmbr0"
}

variable "bridge_internal" {
  description = "Proxmox bridge for internal cluster traffic"
  type        = string
  default     = "vmbr1"
}

# ── Cluster ───────────────────────────────────────────────────────────────────
variable "cluster_name" {
  description = "Short identifier used to name all resources"
  type        = string
  default     = "prod"
}

variable "ssh_public_key" {
  description = "SSH public key injected into VMs via cloud-init"
  type        = string
}

# ── k3s server VMs ────────────────────────────────────────────────────────────
variable "server_count" {
  description = "Number of k3s server (control-plane) nodes"
  type        = number
  default     = 1
}

variable "server_vmid_start" {
  description = "Starting VMID for k3s server VMs"
  type        = number
  default     = 200
}

variable "server_cores" {
  type    = number
  default = 2
}

variable "server_memory_mb" {
  type    = number
  default = 4096
}

variable "server_disk_gb" {
  type    = number
  default = 40
}

# ── Postgres VM ───────────────────────────────────────────────────────────────
variable "db_vmid" {
  description = "VMID for the Postgres VM"
  type        = number
  default     = 210
}

variable "db_cores" {
  type    = number
  default = 2
}

variable "db_memory_mb" {
  type    = number
  default = 4096
}

variable "db_disk_gb" {
  description = "Disk size for Postgres VM — size generously, Postgres data lives here"
  type        = number
  default     = 80
}

# ── Cloudflare (optional) ─────────────────────────────────────────────────────
variable "cloudflare_api_token" {
  description = "Cloudflare API token — leave empty to skip DNS record creation"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID — leave empty to skip DNS record creation"
  type        = string
  default     = ""
}
