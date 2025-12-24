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
    data = join("\n", [
      "#cloud-config",
      yamlencode({
        users = [{
          name   = var.username
          sudo   = "ALL=(ALL) NOPASSWD:ALL"
          shell  = "/bin/bash"
          groups = ["sudo", "adm"]
          ssh_authorized_keys = var.ssh_keys
        }]
        package_update  = true
        package_upgrade = true
        packages        = ["curl", "open-iscsi", "nfs-common", "jq", "qemu-guest-agent"]
        write_files = [{
          path        = "/usr/local/bin/install-k3s.sh"
          permissions = "0755"
          content     = <<-EOF
#!/bin/bash
set -euo pipefail
LOG=/var/log/k3s-install.log
exec > >(tee -a $LOG) 2>&1
echo "=== K3s Install Started $(date) ==="

# Wait for network connectivity (up to 5 minutes)
echo "Waiting for network connectivity..."
for i in $(seq 1 60); do
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "Network is up after $i attempts"
    break
  fi
  echo "Attempt $i: Network not ready, waiting..."
  sleep 5
done

# Wait for DNS resolution
echo "Waiting for DNS resolution..."
for i in $(seq 1 30); do
  if host github.com >/dev/null 2>&1 || nslookup github.com >/dev/null 2>&1; then
    echo "DNS is working after $i attempts"
    break
  fi
  echo "Attempt $i: DNS not ready, waiting..."
  sleep 5
done

# Install K3s with retries
echo "Installing K3s..."
for i in $(seq 1 5); do
  if curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --flannel-backend=none --disable-network-policy --disable-kube-proxy --disable servicelb --disable traefik --write-kubeconfig-mode 644' sh -; then
    echo "K3s installed successfully on attempt $i"
    break
  fi
  echo "K3s install attempt $i failed, retrying in 30s..."
  sleep 30
done

# Wait for K3s API
echo "Waiting for K3s API..."
until /usr/local/bin/k3s kubectl get node; do sleep 5; done

# Setup kubeconfig for user
echo "Setting up kubeconfig..."
mkdir -p /home/${var.username}/.kube
cp /etc/rancher/k3s/k3s.yaml /home/${var.username}/.kube/config
chown -R ${var.username}:${var.username} /home/${var.username}/.kube
chmod 600 /home/${var.username}/.kube/config

echo "=== K3s Install Complete $(date) ==="
EOF
        }]
        runcmd = [
          "echo '127.0.0.1 $(hostname)' >> /etc/hosts",
          "systemctl enable qemu-guest-agent && systemctl start qemu-guest-agent",
          "mkdir -p /mnt/data/nexus && chown -R 200:200 /mnt/data/nexus",
          "/usr/local/bin/install-k3s.sh"
        ]
      })
    ])
    file_name = "${var.vm_name}-cloudinit.yaml"
  }
}

# Custom cloud-init user-data snippet (for FreeIPA, etc.)
resource "proxmox_virtual_environment_file" "custom_cloudinit" {
  count = var.custom_user_data != "" ? 1 : 0

  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data      = var.custom_user_data
    file_name = "${var.vm_name}-custom-cloudinit.yaml"
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

    # Priority: custom_user_data > install_k3s > cloud_init_user_data_id
    user_data_file_id = var.custom_user_data != "" ? proxmox_virtual_environment_file.custom_cloudinit[0].id : (var.install_k3s ? proxmox_virtual_environment_file.k3s_cloudinit[0].id : var.cloud_init_user_data_id)
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
