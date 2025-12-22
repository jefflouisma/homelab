# HomeProd Kubernetes Variables

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "github_repo_ssh_url" {
  description = "SSH URL for the homelab repo"
  type        = string
  default     = "git@github.com:jefflouisma/homelab.git"
}

variable "argocd_deploy_key" {
  description = "SSH private key for ArgoCD to access the repo"
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_app_id" {
  description = "GitHub App ID for Actions Runner Controller"
  type        = string
  default     = ""
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID"
  type        = string
  default     = ""
}

variable "github_app_private_key" {
  description = "GitHub App private key (PEM format)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "k8s_api_host" {
  description = "Kubernetes API server host IP"
  type        = string
  default     = "192.168.1.50"
}
