# HomePractice Infrastructure Outputs

output "opnsense_vm_id" {
  description = "OPNsense VM ID"
  value       = proxmox_virtual_environment_vm.opnsense.vm_id
}

output "opnsense_wan_ip" {
  description = "OPNsense WAN IP"
  value       = var.opnsense_wan_ip
}

output "opnsense_lan_ip" {
  description = "OPNsense LAN IP"
  value       = var.opnsense_lan_ip
}

output "opnsense_api_url" {
  description = "OPNsense API URL for Terraform provider"
  value       = "https://${var.opnsense_wan_ip}"
}

output "k3s_vm_id" {
  description = "K3s VM ID"
  value       = module.practice_k3s.vm_id
}

output "k3s_ip_address" {
  description = "K3s VM IP address"
  value       = "10.10.10.10"
}

output "adguard_ip" {
  description = "AdGuard Home DNS server IP"
  value       = var.adguard_ip
}

output "adguard_web_ui" {
  description = "AdGuard Home Web UI URL"
  value       = var.debian_lxc_template_id != "" ? "http://${var.adguard_ip}:3000" : "Not deployed (debian_lxc_template_id not set)"
}

output "next_steps" {
  description = "Post-deployment steps"
  value       = <<-EOT
    
    ============================================
    HomePractice Infrastructure Created!
    ============================================
    
    OPNsense VM is configured via USB Importer with:
    - WAN: ${var.opnsense_wan_ip}/24 (gateway: ${var.opnsense_wan_gateway})
    - LAN: ${var.opnsense_lan_ip}/24
    - API credentials: Pre-configured for Terraform
    
    Next Steps:
    
    1. Boot OPNsense VM and install to disk (select option 8 from menu)
       - OPNsense Importer will detect config disk and import settings
    
    2. After reboot, apply OPNsense Terraform layer:
       cd ../opnsense && terraform init && terraform apply
    
    3. Wait for K3s cloud-init to complete (~5 min), then:
       cd ../kubernetes && terraform apply
    
  EOT
}
