# Terraform Configuration for Homelab Kubernetes Bootstrap
# This installs foundational cluster components that ArgoCD depends on.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }

  # Local backend - state stored on the server
  # For DR: ensure this file is included in your backup strategy
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "kubectl" {
  config_path = var.kubeconfig_path
}

# =============================================================================
# CILIUM - CNI (Must be first - cluster can't network without it)
# =============================================================================

resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = "1.17.0"
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }
  set {
    name  = "k8sServiceHost"
    value = "127.0.0.1"
  }
  set {
    name  = "k8sServicePort"
    value = "6443"
  }
  set {
    name  = "hubble.enabled"
    value = "true"
  }
  set {
    name  = "hubble.relay.enabled"
    value = "true"
  }
  set {
    name  = "hubble.ui.enabled"
    value = "true"
  }
  # Single-node cluster: only need 1 operator replica
  set {
    name  = "operator.replicas"
    value = "1"
  }

  timeout = 600

  # Wait for Cilium to be ready before proceeding
  wait = true
}

# Give Cilium time to initialize networking
resource "time_sleep" "wait_for_cilium" {
  depends_on      = [helm_release.cilium]
  create_duration = "30s"
}

# =============================================================================
# METALLB - Load Balancer
# =============================================================================

resource "helm_release" "metallb" {
  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  namespace        = "metallb-system"
  create_namespace = true

  depends_on = [time_sleep.wait_for_cilium]

  timeout = 300
  wait    = true
}

# MetalLB IP Address Pool - using kubectl provider for apply-time CRD validation
resource "kubectl_manifest" "metallb_ip_pool" {
  yaml_body = <<-YAML
    apiVersion: metallb.io/v1beta1
    kind: IPAddressPool
    metadata:
      name: production-pool
      namespace: metallb-system
    spec:
      addresses:
        ${indent(8, yamlencode(var.metallb_ip_range))}
  YAML

  depends_on = [helm_release.metallb]
}

# MetalLB L2 Advertisement
resource "kubectl_manifest" "metallb_l2_advertisement" {
  yaml_body = <<-YAML
    apiVersion: metallb.io/v1beta1
    kind: L2Advertisement
    metadata:
      name: production-l2
      namespace: metallb-system
    spec:
      ipAddressPools:
        - production-pool
  YAML

  depends_on = [kubectl_manifest.metallb_ip_pool]
}

# =============================================================================
# ARGOCD - GitOps Controller
# =============================================================================

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }

  depends_on = [time_sleep.wait_for_cilium]
}

resource "kubernetes_namespace" "devops" {
  metadata {
    name = "devops"
  }

  depends_on = [time_sleep.wait_for_cilium]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.55.0"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Expose via LoadBalancer (MetalLB will assign an IP)
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  # Disable TLS on ArgoCD server (optional, simplifies access)
  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }

  depends_on = [kubectl_manifest.metallb_l2_advertisement]

  timeout = 600
  wait    = true
}

# =============================================================================
# ARGOCD REPOSITORY SECRET (for private repo access)
# =============================================================================

resource "kubernetes_secret" "argocd_repo" {
  count = var.argocd_deploy_key != "" ? 1 : 0

  metadata {
    name      = "homelab-repo"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type          = "git"
    url           = var.github_repo_ssh_url
    sshPrivateKey = var.argocd_deploy_key
  }

  depends_on = [helm_release.argocd]
}

# =============================================================================
# ARGOCD ROOT APPLICATION (triggers GitOps sync)
# =============================================================================

# ArgoCD Root Application - using kubectl provider for apply-time CRD validation
resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: root
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: ${var.github_repo_ssh_url}
        targetRevision: HEAD
        path: apps
        directory:
          recurse: false
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
  YAML

  depends_on = [helm_release.argocd]
}

# =============================================================================
# ACTIONS RUNNER CONTROLLER - GitHub App Secret
# =============================================================================

resource "kubernetes_namespace" "actions_runner_system" {
  count = var.github_app_id != "" ? 1 : 0

  metadata {
    name = "actions-runner-system"
  }

  depends_on = [time_sleep.wait_for_cilium]
}

resource "kubernetes_secret" "arc_controller_manager" {
  count = var.github_app_id != "" ? 1 : 0

  metadata {
    name      = "controller-manager"
    namespace = kubernetes_namespace.actions_runner_system[0].metadata[0].name
  }

  data = {
    github_app_id              = var.github_app_id
    github_app_installation_id = var.github_app_installation_id
    github_app_private_key     = var.github_app_private_key
  }

  depends_on = [kubernetes_namespace.actions_runner_system]
}
