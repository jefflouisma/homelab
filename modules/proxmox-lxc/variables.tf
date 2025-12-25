# Proxmox LXC Container Module - Variables

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
}

variable "vm_id" {
  description = "Unique VM ID for the container"
  type        = number
}

variable "hostname" {
  description = "Container hostname"
  type        = string
}

variable "description" {
  description = "Container description"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags for the container"
  type        = list(string)
  default     = []
}

variable "unprivileged" {
  description = "Run as unprivileged container"
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Start container on Proxmox boot"
  type        = bool
  default     = true
}

variable "template_file_id" {
  description = "Container template file ID"
  type        = string
}

variable "os_type" {
  description = "Operating system type (debian, ubuntu, alpine, etc)"
  type        = string
  default     = "debian"
}

variable "cpu_cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 1
}

variable "memory_mb" {
  description = "Memory in MB"
  type        = number
  default     = 512
}

variable "swap_mb" {
  description = "Swap in MB"
  type        = number
  default     = 512
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 8
}

variable "datastore_id" {
  description = "Datastore for container storage"
  type        = string
}

variable "network_bridge" {
  description = "Network bridge for container"
  type        = string
  default     = "vmbr0"
}

variable "ip_address" {
  description = "Static IP address with CIDR (e.g., 192.168.1.100/24)"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "ssh_keys" {
  description = "SSH public keys for root access"
  type        = list(string)
  default     = []
}

variable "root_password" {
  description = "Root password for the container"
  type        = string
  default     = ""
  sensitive   = true
}

variable "nesting" {
  description = "Enable nesting (for Docker in LXC)"
  type        = bool
  default     = false
}

variable "fuse" {
  description = "Enable FUSE"
  type        = bool
  default     = false
}

variable "startup_order" {
  description = "Startup order (lower = earlier)"
  type        = number
  default     = 0
}

variable "startup_delay" {
  description = "Delay in seconds before starting next container"
  type        = number
  default     = 0
}

variable "shutdown_delay" {
  description = "Delay in seconds before stopping container"
  type        = number
  default     = 0
}
