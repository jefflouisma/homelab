# Barleta Infrastructure Outputs

output "freeipa_vm_id" {
  description = "FreeIPA VM ID"
  value       = harvester_virtualmachine.freeipa.id
}

output "freeipa_ip" {
  description = "FreeIPA VM IP address"
  value       = var.freeipa_ip
}

output "ssh_key_id" {
  description = "SSH Key ID for Barleta VMs"
  value       = harvester_ssh_key.barleta.id
}

output "network_id" {
  description = "Barleta LAN network ID"
  value       = harvester_network.barleta_lan.id
}

output "harvester_kubeconfig" {
  description = "Path to Harvester kubeconfig for native workloads"
  value       = var.harvester_kubeconfig
}
