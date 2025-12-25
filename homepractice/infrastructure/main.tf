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
# OPNsense Firewall - Golden Template Clone Pattern
# =============================================================================
# Golden template (VM 9000) has:
#   - 3 NICs (Management, WAN, Internal) all on DHCP
#   - SSH enabled with root login
#   - API key pre-configured
#
# Deployment flow:
#   1. Terraform clones golden template
#   2. VM boots with DHCP on all interfaces
#   3. Post-boot: Configure IPs via OPNsense API
#   4. GitOps layer manages firewall rules

# Clone OPNsense from golden template
resource "proxmox_virtual_environment_vm" "opnsense" {
  name      = "perimeter-fw"
  node_name = var.proxmox_node
  vm_id     = 200

  description = "OPNsense perimeter firewall for HomePractice (perimeter-fw.local)"
  tags        = ["terraform", "homepractice", "firewall"]

  # Clone from golden template (VM 9000)
  clone {
    vm_id = var.opnsense_template_id
  }

  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 4096
  }

  # WAN interface (vmbr0) - DHCP, gateway, WireGuard + management
  network_device {
    bridge = "vmbr0"
  }

  # LAN interface (vmbr1) - internal network 10.10.10.1/24
  network_device {
    bridge = "vmbr1"
  }

  operating_system {
    type = "other"
  }

  # Don't wait for guest agent - OPNsense boots fast but agent takes time
  started = true
  timeout_create = 120
  timeout_clone  = 120

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

# =============================================================================
# FreeIPA Identity Server
# =============================================================================
# FreeIPA requires systemd and cannot run in K8s containers.
# Deployed as a standalone VM with static IP on the internal network.

module "freeipa" {
  source = "../../modules/proxmox-vm"

  vm_name      = "freeipa"
  proxmox_node = var.proxmox_node
  vm_id        = 202
  description  = "FreeIPA Identity Server for HomePractice"
  tags         = ["terraform", "homepractice", "identity"]

  cpu_cores    = 2
  memory_mb    = 4096
  disk_size_gb = 50

  datastore_id   = var.datastore_id
  cloud_image_id = var.fedora_cloud_image_id

  network_interfaces = [
    { bridge = "vmbr1" }  # Connected to isolated network
  ]

  ip_address = "10.10.10.212/24"
  gateway    = "10.10.10.1"
  username   = "fedora"
  ssh_keys   = var.ssh_public_keys

  install_k3s = false
  
  # GitOps: Auto-install FreeIPA via cloud-init on first boot
  custom_user_data = file("${path.module}/freeipa-cloudinit.yaml")
}

# =============================================================================
# AdGuard Home DNS Server
# =============================================================================
# Provides DNS resolution for the home network (192.168.1.0/24)
# Forwards practice.local → OPNsense, everything else → home router
# Deployed as LXC container on the home network for accessibility

resource "proxmox_virtual_environment_container" "adguard" {
  count = var.debian_lxc_template_id != "" ? 1 : 0

  node_name   = var.proxmox_node
  vm_id       = 203
  description = "AdGuard Home DNS Server - forwards practice.local to OPNsense"
  tags        = ["terraform", "homepractice", "dns"]

  unprivileged  = true
  start_on_boot = true

  operating_system {
    template_file_id = var.debian_lxc_template_id
    type             = "debian"
  }

  cpu {
    architecture = "amd64"
    cores        = 1
  }

  memory {
    dedicated = 512
    swap      = 256
  }

  disk {
    datastore_id = var.datastore_id
    size         = 8
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"  # Home network, not isolated network
  }

  initialization {
    hostname = "adguard"

    ip_config {
      ipv4 {
        address = "${var.adguard_ip}/24"
        gateway = "192.168.1.254"
      }
    }

    user_account {
      keys = var.ssh_public_keys
    }
  }

  features {
    nesting = false
  }

  startup {
    order      = 1
    up_delay   = 0
    down_delay = 0
  }
}

# Null resource to install AdGuard Home after container is created
resource "null_resource" "adguard_install" {
  count = var.debian_lxc_template_id != "" ? 1 : 0

  depends_on = [proxmox_virtual_environment_container.adguard]

  triggers = {
    container_id = proxmox_virtual_environment_container.adguard[0].vm_id
  }

  connection {
    type        = "ssh"
    host        = var.adguard_ip
    user        = "root"
    private_key = file("~/.ssh/id_cloudstack_ed25519")
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for container to be ready...'",
      "sleep 30",
      "apt-get update",
      "apt-get install -y curl ca-certificates",
      "mkdir -p /opt/AdGuardHome",
      "cd /opt/AdGuardHome",
      "curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v",
      "systemctl enable AdGuardHome",
      "systemctl start AdGuardHome",
      "echo 'AdGuard Home installed successfully'"
    ]
  }

  # Copy the configuration file
  provisioner "file" {
    source      = "${path.module}/adguard-home/AdGuardHome.yaml"
    destination = "/opt/AdGuardHome/AdGuardHome.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "systemctl restart AdGuardHome",
      "echo 'AdGuard Home configured with practice.local forwarding'"
    ]
  }
}
