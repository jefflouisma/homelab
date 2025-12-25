# Proxmox LXC Container Module - Outputs

output "container_id" {
  description = "Container VM ID"
  value       = proxmox_virtual_environment_container.container.vm_id
}

output "hostname" {
  description = "Container hostname"
  value       = var.hostname
}

output "ip_address" {
  description = "Container IP address"
  value       = var.ip_address
}
