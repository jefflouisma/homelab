# HomeProd Infrastructure - Tier 0
# Creates K3s VM directly on home network

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true

  ssh {
    agent    = true
    username = "root"
  }
}

# K3s VM using shared module
module "prod_k3s" {
  source = "../../modules/proxmox-vm"

  vm_name      = "prod-k3s"
  proxmox_node = var.proxmox_node
  vm_id        = 100
  description  = "K3s node for HomeProd stable environment"
  tags         = ["terraform", "homeprod", "kubernetes"]

  cpu_cores    = 4
  memory_mb    = 16384
  disk_size_gb = 100

  datastore_id   = var.datastore_id
  cloud_image_id = var.ubuntu_cloud_image_id

  network_interfaces = [
    { bridge = "vmbr0" }  # Directly on home LAN
  ]

  ip_address = "192.168.1.50/24"
  gateway    = "192.168.1.1"
  username   = "ubuntu"
  ssh_keys   = var.ssh_public_keys
}
