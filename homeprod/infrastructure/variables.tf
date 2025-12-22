# HomeProd Infrastructure Variables

variable "proxmox_api_url" {
  description = "Proxmox API URL (e.g., https://192.168.1.100:8006/api2/json)"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token ID (e.g., root@pam!terraform)"
  type        = string
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "datastore_id" {
  description = "Datastore for VM disks"
  type        = string
  default     = "local-lvm"
}

variable "ubuntu_cloud_image_id" {
  description = "File ID of Ubuntu cloud image (e.g., local:iso/ubuntu-24.04-server-cloudimg-amd64.img)"
  type        = string
}

variable "ssh_public_keys" {
  description = "List of SSH public keys for VM access"
  type        = list(string)
}
