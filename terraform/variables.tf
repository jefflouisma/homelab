# Input Variables for Homelab Terraform Configuration

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file for K3s"
  type        = string
  default     = "/etc/rancher/k3s/k3s.yaml"
}

variable "metallb_ip_range" {
  description = "IP address range for MetalLB to assign to LoadBalancer services"
  type        = list(string)
  default     = ["192.168.1.40-192.168.1.50"]
}

variable "github_repo_https_url" {
  description = "HTTPS URL of the homelab GitHub repository"
  type        = string
  default     = "https://github.com/jefflouisma/homelab.git"
}

variable "github_repo_ssh_url" {
  description = "SSH URL of the homelab GitHub repository (for ArgoCD)"
  type        = string
  default     = "git@github.com:jefflouisma/homelab.git"
}

variable "argocd_deploy_key" {
  description = "SSH private key for ArgoCD to access private repo. Leave empty to skip."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_app_id" {
  description = "GitHub App ID for Actions Runner Controller"
  type        = string
  default     = ""
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID for Actions Runner Controller"
  type        = string
  default     = ""
}

variable "github_app_private_key" {
  description = "GitHub App private key (PEM format) for Actions Runner Controller"
  type        = string
  default     = ""
  sensitive   = true
}
