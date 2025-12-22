# Proxmox VM Module Variables

variable "vm_name" {
  description = "Name of the VM"
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node to create VM on"
  type        = string
  default     = "pve"
}

variable "vm_id" {
  description = "VM ID (must be unique)"
  type        = number
  default     = null
}

variable "description" {
  description = "VM description"
  type        = string
  default     = "Managed by Terraform"
}

variable "tags" {
  description = "Tags for the VM"
  type        = list(string)
  default     = ["terraform"]
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Memory in MB"
  type        = number
  default     = 2048
}

variable "datastore_id" {
  description = "Datastore for VM disk"
  type        = string
  default     = "local-lvm"
}

variable "cloud_image_id" {
  description = "File ID of the cloud image (e.g., local:iso/ubuntu-24.04-server-cloudimg-amd64.img)"
  type        = string
}

variable "disk_size_gb" {
  description = "Disk size in GB"
  type        = number
  default     = 32
}

variable "network_interfaces" {
  description = "List of network interfaces"
  type = list(object({
    bridge      = string
    mac_address = optional(string)
    vlan_id     = optional(number)
  }))
  default = [{ bridge = "vmbr0" }]
}

variable "ip_address" {
  description = "IP address with CIDR (e.g., 192.168.1.50/24) or 'dhcp'"
  type        = string
  default     = "dhcp"
}

variable "gateway" {
  description = "Default gateway IP"
  type        = string
  default     = null
}

variable "username" {
  description = "Default user for cloud-init"
  type        = string
  default     = "ubuntu"
}

variable "ssh_keys" {
  description = "List of SSH public keys"
  type        = list(string)
  default     = []
}

variable "cloud_init_user_data_id" {
  description = "File ID for cloud-init user data snippet"
  type        = string
  default     = null
}

variable "start_on_boot" {
  description = "Start VM on Proxmox boot"
  type        = bool
  default     = true
}

variable "install_k3s" {
  description = "Install K3s via cloud-init"
  type        = bool
  default     = false
}

variable "k3s_version" {
  description = "K3s version to install (empty for latest)"
  type        = string
  default     = ""
}
