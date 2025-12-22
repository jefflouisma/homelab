# HomePractice Kubernetes Outputs

output "argocd_server_url" {
  description = "ArgoCD server URL (get actual IP with: kubectl get svc -n argocd)"
  value       = "https://<metallb-ip>"
}

output "metallb_ip_range" {
  description = "MetalLB IP address pool"
  value       = "10.10.10.200-10.10.10.250"
}

output "next_steps" {
  description = "Post-installation steps"
  value       = <<-EOT
    
    ============================================
    HomePractice Kubernetes Configured!
    ============================================
    
    Get ArgoCD admin password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    
    Get ArgoCD LoadBalancer IP:
      kubectl get svc -n argocd argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    
    ArgoCD will auto-sync apps from: homepractice/apps/
    
    Runner labels for this environment: [self-hosted, homepractice]
    
  EOT
}
