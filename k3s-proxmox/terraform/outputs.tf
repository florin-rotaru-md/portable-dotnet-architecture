output "k3s_server_ips_external" {
  description = "External (LAN) IPs of k3s server VMs"
  value       = proxmox_virtual_environment_vm.k3s_server[*].ipv4_addresses[0][0]
}

output "k3s_server_ips_internal" {
  description = "Internal cluster IPs of k3s server VMs"
  value       = proxmox_virtual_environment_vm.k3s_server[*].ipv4_addresses[1][0]
}

output "postgres_ip_external" {
  description = "External (LAN) IP of the Postgres VM"
  value       = proxmox_virtual_environment_vm.postgres.ipv4_addresses[0][0]
}

output "postgres_ip_internal" {
  description = "Internal cluster IP of the Postgres VM (use this in k3s Secrets)"
  value       = proxmox_virtual_environment_vm.postgres.ipv4_addresses[1][0]
}
