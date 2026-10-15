output "public_ip" {
  description = "Reserved (static) public IPv4 — point DNS A records here."
  value       = digitalocean_reserved_ip.gpu.ip_address
}

output "droplet_ipv4" {
  description = "Droplet's own public IPv4 (changes if the droplet is rebuilt)."
  value       = digitalocean_droplet.gpu.ipv4_address
}

output "droplet_ipv6" {
  value = digitalocean_droplet.gpu.ipv6_address
}

output "private_ip" {
  value = digitalocean_droplet.gpu.ipv4_address_private
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@${digitalocean_reserved_ip.gpu.ip_address}"
}

output "data_volume" {
  value = {
    name        = digitalocean_volume.data.name
    size_gib    = digitalocean_volume.data.size
    mount_point = var.data_mount_point
  }
}

output "backup_bucket_endpoint" {
  value = var.create_backup_bucket ? "https://${var.backup_spaces_region}.digitaloceanspaces.com/${var.backup_bucket_name}" : null
}

output "dns_records_to_create" {
  description = "If DNS is managed elsewhere, create these A records manually."
  value       = { for r in var.dns_records : (r == "@" ? var.domain : "${r}.${var.domain}") => digitalocean_reserved_ip.gpu.ip_address }
}
