# Proxmox VM Module
# Creates a VM using bpg/proxmox provider with cloud-init support

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
  }
}

locals {
  k3s_install_script = var.install_k3s ? <<-EOF
    #!/bin/bash
    set -euo pipefail
    LOG_FILE="/var/log/k3s-bootstrap.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    echo "=== K3s Bootstrap Started at $(date) ==="
    
    # Install required packages
    apt-get update && apt-get install -y curl open-iscsi nfs-common jq
    
    # Create data directories
    mkdir -p /mnt/data/nexus
    chown -R 200:200 /mnt/data/nexus
    
    # Install K3s with disabled components (Cilium replaces them)
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
      --flannel-backend=none \
      --disable-network-policy \
      --disable-kube-proxy \
      --disable servicelb \
      --disable traefik \
      --write-kubeconfig-mode 644" ${var.k3s_version != "" ? "INSTALL_K3S_VERSION=${var.k3s_version}" : ""} sh -
    
    # Wait for K3s API
    echo "Waiting for K3s API..."
    until /usr/local/bin/k3s kubectl get node &>/dev/null; do sleep 5; done
    
    # Setup kubeconfig for ubuntu user
    mkdir -p /home/ubuntu/.kube
    cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
    chown -R ubuntu:ubuntu /home/ubuntu/.kube
    
    echo "=== K3s Bootstrap Complete at $(date) ==="
    EOF
  : null
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.vm_name
  node_name = var.proxmox_node

  # VM Settings
  vm_id       = var.vm_id
  description = var.description
  tags        = var.tags

  # Hardware
  cpu {
    cores   = var.cpu_cores
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = var.memory_mb
  }

  # Boot disk from cloud image
  disk {
    datastore_id = var.datastore_id
    file_id      = var.cloud_image_id
    interface    = "scsi0"
    size         = var.disk_size_gb
    discard      = "on"
    ssd          = true
  }

  # Network interfaces
  dynamic "network_device" {
    for_each = var.network_interfaces
    content {
      bridge      = network_device.value.bridge
      mac_address = lookup(network_device.value, "mac_address", null)
      vlan_id     = lookup(network_device.value, "vlan_id", null)
    }
  }

  # Cloud-init configuration
  initialization {
    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_account {
      username = var.username
      keys     = var.ssh_keys
    }

    # Use inline user_data for K3s install, otherwise use file_id
    user_data_file_id = var.install_k3s ? null : var.cloud_init_user_data_id
    
    dynamic "user_data" {
      for_each = var.install_k3s ? [1] : []
      content {
        content = <<-YAML
          #cloud-config
          package_update: true
          package_upgrade: true
          runcmd:
            - |
              ${indent(14, local.k3s_install_script)}
        YAML
      }
    }
  }

  # Agent - enabled but don't wait for it
  agent {
    enabled = true
    timeout = "60s"
  }

  # Start on boot
  on_boot = var.start_on_boot

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].keys,
    ]
  }
}
