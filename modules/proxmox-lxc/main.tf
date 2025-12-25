# Proxmox LXC Container Module
# Creates an LXC container using bpg/proxmox provider

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.70"
    }
  }
}

resource "proxmox_virtual_environment_container" "container" {
  node_name   = var.proxmox_node
  vm_id       = var.vm_id
  description = var.description
  tags        = var.tags

  # Unprivileged container (more secure)
  unprivileged = var.unprivileged

  # Start on Proxmox boot
  start_on_boot = var.start_on_boot

  # OS Template
  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  # CPU
  cpu {
    architecture = "amd64"
    cores        = var.cpu_cores
  }

  # Memory
  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  # Root filesystem
  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size_gb
  }

  # Network interface
  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  # Initialization (cloud-init style)
  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_account {
      keys     = var.ssh_keys
      password = var.root_password
    }
  }

  # Container features
  features {
    nesting = var.nesting
    fuse    = var.fuse
  }

  # Startup behavior
  startup {
    order      = var.startup_order
    up_delay   = var.startup_delay
    down_delay = var.shutdown_delay
  }

  lifecycle {
    ignore_changes = [
      initialization[0].user_account[0].password,
    ]
  }
}
