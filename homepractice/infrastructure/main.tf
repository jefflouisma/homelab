# HomePractice Infrastructure - Tier 0
# Creates OPNsense firewall + K3s VM on isolated network

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
    agent       = true
    username    = "root"
    private_key = file("~/.ssh/id_cloudstack_ed25519")
  }
}

# =============================================================================
# OPNsense Firewall VM
# =============================================================================
# Note: OPNsense requires initial installation from ISO.
# After installation, configuration is managed via opnsense-config module.

resource "proxmox_virtual_environment_vm" "opnsense" {
  name      = "practice-opnsense"
  node_name = var.proxmox_node
  vm_id     = 200

  description = "OPNsense firewall for HomePractice isolated network"
  tags        = ["terraform", "homepractice", "firewall"]

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 4096
  }

  # Boot from OPNsense ISO for initial install
  cdrom {
    file_id   = var.opnsense_iso_id
    interface = "ide2"
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = 32
    discard      = "on"
    ssd          = true
  }

  # WAN interface - connected to home network (192.168.1.x)
  network_device {
    bridge = "vmbr0"
  }

  # LAN interface - isolated lab network (10.10.10.x)
  network_device {
    bridge = "vmbr1"
  }

  operating_system {
    type = "other"
  }

  on_boot = true
}

# K3s VM using shared module
module "practice_k3s" {
  source = "../../modules/proxmox-vm"

  vm_name      = "practice-k3s"
  proxmox_node = var.proxmox_node
  vm_id        = 201
  description  = "K3s node for HomePractice environment"
  tags         = ["terraform", "homepractice", "kubernetes"]

  cpu_cores    = 4
  memory_mb    = 32768
  disk_size_gb = 100

  datastore_id   = var.datastore_id
  cloud_image_id = var.ubuntu_cloud_image_id

  network_interfaces = [
    { bridge = "vmbr1" }  # Only connected to isolated network
  ]

  ip_address = "10.10.10.10/24"
  gateway    = "10.10.10.1"
  username   = "ubuntu"
  ssh_keys   = var.ssh_public_keys

  # Install K3s via cloud-init (following terraform/ patterns)
  install_k3s = true
}
