# HomePractice Infrastructure Outputs

output "opnsense_vm_id" {
  description = "OPNsense VM ID"
  value       = proxmox_virtual_environment_vm.opnsense.vm_id
}

output "k3s_vm_id" {
  description = "K3s VM ID"
  value       = module.practice_k3s.vm_id
}

output "k3s_ip_address" {
  description = "K3s VM IP address"
  value       = "10.10.10.10"
}

output "next_steps" {
  description = "Manual steps after terraform apply"
  value       = <<-EOT
    
    ============================================
    HomePractice Infrastructure Created!
    ============================================
    
    Next Steps:
    
    1. Console into OPNsense VM and complete initial setup:
       - Assign interfaces: WAN (vtnet0), LAN (vtnet1)
       - Set LAN IP: 10.10.10.1/24
       - Enable DHCP on LAN: 10.10.10.100-199
    
    2. Configure WireGuard VPN in OPNsense for remote access
    
    3. SSH to K3s VM (via WireGuard or Proxmox console):
       ssh ubuntu@10.10.10.10
    
    4. Run K3s bootstrap:
       sudo /opt/homelab/modules/k8s-bootstrap/pre-kubernetes.sh
    
    5. Apply Kubernetes terraform:
       cd ../kubernetes && terraform apply
    
  EOT
}
