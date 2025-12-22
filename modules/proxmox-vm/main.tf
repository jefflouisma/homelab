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

# Cloud-init user-data snippet for K3s installation
resource "proxmox_virtual_environment_file" "k3s_cloudinit" {
  count = var.install_k3s ? 1 : 0

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = yamlencode({
      package_update  = true
      package_upgrade = true
      packages        = ["curl", "open-iscsi", "nfs-common", "jq", "qemu-guest-agent"]
      runcmd = [
        "systemctl enable qemu-guest-agent && systemctl start qemu-guest-agent",
        "mkdir -p /mnt/data/nexus && chown -R 200:200 /mnt/data/nexus",
        "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --flannel-backend=none --disable-network-policy --disable-kube-proxy --disable servicelb --disable traefik --write-kubeconfig-mode 644' sh -",
        "until /usr/local/bin/k3s kubectl get node; do sleep 5; done",
        "mkdir -p /home/${var.username}/.kube",
        "cp /etc/rancher/k3s/k3s.yaml /home/${var.username}/.kube/config",
        "chown -R ${var.username}:${var.username} /home/${var.username}/.kube"
      ]
    })
    file_name = "${var.vm_name}-cloudinit.yaml"
  }
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

    # Use K3s cloud-init snippet if install_k3s is true, otherwise use provided file_id
    user_data_file_id = var.install_k3s ? proxmox_virtual_environment_file.k3s_cloudinit[0].id : var.cloud_init_user_data_id
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
