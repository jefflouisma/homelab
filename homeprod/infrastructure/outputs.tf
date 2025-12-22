# HomeProd Infrastructure Outputs

output "k3s_vm_id" {
  description = "K3s VM ID"
  value       = module.prod_k3s.vm_id
}

output "k3s_ip_address" {
  description = "K3s VM IP address"
  value       = "192.168.1.50"
}

output "next_steps" {
  description = "Manual steps after terraform apply"
  value       = <<-EOT
    
    ============================================
    HomeProd Infrastructure Created!
    ============================================
    
    Next Steps:
    
    1. SSH to K3s VM:
       ssh ubuntu@192.168.1.50
    
    2. Run K3s bootstrap:
       sudo /opt/homelab/modules/k8s-bootstrap/pre-kubernetes.sh
    
    3. Apply Kubernetes terraform:
       cd ../kubernetes && terraform apply
    
  EOT
}
