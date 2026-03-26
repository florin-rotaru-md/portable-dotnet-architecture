output "k3s_server_ips" {
  description = "Public IPs of k3s server nodes"
  value       = hcloud_server.k3s_server[*].ipv4_address
}

output "postgres_ip" {
  description = "Public IP of the Postgres server"
  value       = hcloud_server.postgres.ipv4_address
}

output "postgres_private_ip" {
  description = "Private (cluster network) IP of the Postgres server"
  value       = hcloud_server_network.postgres.ip
}
