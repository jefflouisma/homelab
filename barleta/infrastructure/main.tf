# Barleta Infrastructure - Harvester HCI
# Creates VMs on Harvester only for workloads that require systemd (FreeIPA)
# All other workloads run natively on Harvester's RKE2 cluster

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "~> 0.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig
}

provider "kubernetes" {
  config_path = var.harvester_kubeconfig
}

# =============================================================================
# Cloud Images
# =============================================================================

resource "harvester_image" "fedora41" {
  name         = "fedora-cloud-41"
  namespace    = "harvester-public"
  display_name = "Fedora Cloud 41"
  source_type  = "download"
  url          = "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
}

# =============================================================================
# SSH Keys
# =============================================================================

resource "harvester_ssh_key" "barleta" {
  name       = "barleta-ssh-key"
  namespace  = "default"
  public_key = file("${path.module}/../../id_rsa.pub")
}

# =============================================================================
# VM Network
# =============================================================================

resource "harvester_network" "barleta_lan" {
  name      = "barleta-lan"
  namespace = "default"

  vlan_id = var.vlan_id

  route_mode           = "auto"
  route_dhcp_server_ip = ""

  cluster_network_name = var.cluster_network_name
}

# =============================================================================
# FreeIPA VM
# =============================================================================

resource "harvester_virtualmachine" "freeipa" {
  name      = "freeipa"
  namespace = "default"

  description = "FreeIPA Identity Server for Barleta"
  tags = {
    environment = "barleta"
    role        = "identity"
  }

  cpu    = 2
  memory = "4Gi"

  efi         = true
  secure_boot = false

  run_strategy = "RerunOnFailure"
  hostname     = "ipa"
  machine_type = "q35"

  ssh_keys = [
    harvester_ssh_key.barleta.id
  ]

  network_interface {
    name           = "nic-1"
    wait_for_lease = true
    type           = "bridge"
    network_name   = harvester_network.barleta_lan.id
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = "50Gi"
    bus        = "virtio"
    boot_order = 1

    image       = harvester_image.fedora41.id
    auto_delete = true
  }

  cloudinit {
    user_data_secret_name    = kubernetes_secret.freeipa_cloudinit.metadata[0].name
    network_data_secret_name = kubernetes_secret.freeipa_network.metadata[0].name
  }
}

# Cloud-init secrets for FreeIPA
resource "kubernetes_secret" "freeipa_cloudinit" {
  metadata {
    name      = "freeipa-cloudinit"
    namespace = "default"
  }

  data = {
    userdata = file("${path.module}/freeipa-cloudinit.yaml")
  }
}

resource "kubernetes_secret" "freeipa_network" {
  metadata {
    name      = "freeipa-network"
    namespace = "default"
  }

  data = {
    networkdata = yamlencode({
      version = 2
      ethernets = {
        enp1s0 = {
          dhcp4 = false
          addresses = [var.freeipa_ip]
          gateway4  = var.gateway
          nameservers = {
            addresses = var.dns_servers
          }
        }
      }
    })
  }
}

