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
# Prerequisites:
#   1. Golden template (VM 9000) with SSH + API key baked in
#   2. Syshook script at /usr/local/etc/rc.syshook.d/early/20-instance-config
#
# This Terraform:
#   1. Clones golden template
#   2. Creates seed disk with instance-specific config.xml
#   3. Attaches seed disk - syshook imports on first boot
#   4. OPNsense boots with instance config, immediately accessible via API

# Render instance-specific config.xml
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
    file_name = "opnsense-instance-config.xml"
  }
}

# Create FAT-formatted seed disk with instance config
resource "null_resource" "opnsense_seed_disk" {
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
      "echo 'Creating OPNsense seed disk...'",
      "rm -f /var/lib/vz/images/opnsense-seed.raw",
      "dd if=/dev/zero of=/var/lib/vz/images/opnsense-seed.raw bs=1M count=32 2>/dev/null",
      "echo 'type=0c' | sfdisk /var/lib/vz/images/opnsense-seed.raw",
      "LOOPDEV=$(losetup -fP --show /var/lib/vz/images/opnsense-seed.raw)",
      "mkfs.vfat -F 16 -n OPSEED $${LOOPDEV}p1",
      "mkdir -p /tmp/opseed",
      "mount $${LOOPDEV}p1 /tmp/opseed",
      "mkdir -p /tmp/opseed/conf",
      "cp /var/lib/vz/snippets/opnsense-instance-config.xml /tmp/opseed/conf/config.xml",
      "sync",
      "umount /tmp/opseed",
      "losetup -d $LOOPDEV",
      "rmdir /tmp/opseed",
      "echo 'Seed disk ready'"
    ]
  }
}

# Clone OPNsense from golden template
resource "proxmox_virtual_environment_vm" "opnsense" {
  depends_on = [null_resource.opnsense_seed_disk]
  name      = "practice-opnsense"
  node_name = var.proxmox_node
  vm_id     = 200

  description = "OPNsense firewall for HomePractice isolated network"
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

# Attach seed disk to cloned VM - syshook imports on first boot
resource "null_resource" "attach_seed_disk" {
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
      "echo 'Attaching seed disk to OPNsense VM...'",
      "qm set 200 --args '-drive file=/var/lib/vz/images/opnsense-seed.raw,format=raw,if=none,id=seed -device usb-storage,drive=seed'",
      "echo 'Seed disk attached as USB storage'"
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
