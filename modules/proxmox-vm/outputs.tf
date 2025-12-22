# Proxmox VM Module Outputs

output "vm_id" {
  description = "The VM ID"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "vm_name" {
  description = "The VM name"
  value       = proxmox_virtual_environment_vm.vm.name
}

output "ipv4_address" {
  description = "The primary IPv4 address"
  value       = try(proxmox_virtual_environment_vm.vm.ipv4_addresses[1][0], null)
}

output "mac_addresses" {
  description = "MAC addresses of network interfaces"
  value       = proxmox_virtual_environment_vm.vm.mac_addresses
}
