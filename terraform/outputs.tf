# Outputs for Homelab Terraform Configuration

output "argocd_server_url" {
  description = "URL to access ArgoCD (may take a moment to get external IP)"
  value       = "Run: kubectl get svc argocd-server -n argocd -o jsonpath='http://{.status.loadBalancer.ingress[0].ip}'"
}

output "argocd_admin_password_command" {
  description = "Command to retrieve the ArgoCD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "metallb_ip_range" {
  description = "IP range configured for MetalLB LoadBalancer services"
  value       = var.metallb_ip_range
}

output "deploy_key_configured" {
  description = "Whether the ArgoCD deploy key was configured"
  value       = var.argocd_deploy_key != "" ? "Yes" : "No - configure manually or re-run with -var='argocd_deploy_key=...'"
}

output "next_steps" {
  description = "Next steps after Terraform apply"
  value       = <<-EOT
    
    ✅ Terraform apply complete!
    
    ArgoCD will now automatically sync the apps/ directory.
    
    To access ArgoCD:
      1. Get the URL: kubectl get svc argocd-server -n argocd
      2. Get the password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
      3. Username: admin
    
    If deploy key was not configured, add it manually:
      kubectl create secret generic homelab-repo -n argocd \
        --from-literal=type=git \
        --from-literal=url=git@github.com:jefflouisma/homelab.git \
        --from-file=sshPrivateKey=/path/to/deploy-key
      kubectl label secret homelab-repo -n argocd argocd.argoproj.io/secret-type=repository
  EOT
}
