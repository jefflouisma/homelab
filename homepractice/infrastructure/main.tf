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
# OPNsense Configuration - USB-based Importer
# =============================================================================
# OPNsense Importer detects /conf/config.xml on attached FAT disk at first boot.
# This injects: interfaces, gateway, NAT, firewall rules, and API credentials.
# Post-boot configuration is managed via OPNsense Terraform provider.

# Render config.xml template with API credentials
locals {
  opnsense_config = templatefile("${path.module}/opnsense-config.xml.tpl", {
    api_key            = var.opnsense_api_key
    api_secret_hash    = var.opnsense_api_secret_hash
    wan_ip             = var.opnsense_wan_ip
    wan_subnet         = "24"
    wan_gateway        = var.opnsense_wan_gateway
    lan_ip             = var.opnsense_lan_ip
    lan_subnet         = "24"
    management_network = "192.168.1.0/24"
  })
}

# Upload rendered config.xml to Proxmox
resource "proxmox_virtual_environment_file" "opnsense_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = local.opnsense_config
    file_name = "opnsense-config.xml"
  }
}

# Create FAT-formatted config disk on Proxmox host
resource "null_resource" "opnsense_config_disk" {
  depends_on = [proxmox_virtual_environment_file.opnsense_config]

  triggers = {
    config_hash = sha256(local.opnsense_config)
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host
    user        = "root"
    private_key = file("~/.ssh/id_cloudstack_ed25519")
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'Creating OPNsense config disk for Importer...'",
      "rm -f /var/lib/vz/images/opnsense-config.raw",
      "dd if=/dev/zero of=/var/lib/vz/images/opnsense-config.raw bs=1M count=8 2>/dev/null",
      "mkfs.vfat -n CONFIG /var/lib/vz/images/opnsense-config.raw",
      "mkdir -p /tmp/opnsense-cfg",
      "mount -o loop /var/lib/vz/images/opnsense-config.raw /tmp/opnsense-cfg",
      "mkdir -p /tmp/opnsense-cfg/conf",
      "cp /var/lib/vz/snippets/opnsense-config.xml /tmp/opnsense-cfg/conf/config.xml",
      "sync",
      "umount /tmp/opnsense-cfg",
      "rmdir /tmp/opnsense-cfg",
      "echo 'Config disk ready at /var/lib/vz/images/opnsense-config.raw'"
    ]
  }
}

# OPNsense Firewall VM
resource "proxmox_virtual_environment_vm" "opnsense" {
  depends_on = [null_resource.opnsense_config_disk]
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

  # Main OS disk
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

# Attach config disk to OPNsense VM for Importer
resource "null_resource" "attach_config_disk" {
  depends_on = [proxmox_virtual_environment_vm.opnsense]

  triggers = {
    vm_id       = proxmox_virtual_environment_vm.opnsense.vm_id
    config_hash = sha256(local.opnsense_config)
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host
    user        = "root"
    private_key = file("~/.ssh/id_cloudstack_ed25519")
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "echo 'Attaching config disk to OPNsense VM...'",
      "qm set 200 --scsi1 local:0,import-from=/var/lib/vz/images/opnsense-config.raw,format=raw",
      "echo 'Config disk attached as scsi1'"
    ]
  }
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
