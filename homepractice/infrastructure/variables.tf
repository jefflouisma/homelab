# HomePractice Infrastructure Variables

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

variable "opnsense_iso_id" {
  description = "File ID of OPNsense ISO (e.g., local:iso/OPNsense-24.7-dvd-amd64.iso)"
  type        = string
}

variable "ubuntu_cloud_image_id" {
  description = "File ID of Ubuntu cloud image (e.g., local:iso/ubuntu-24.04-server-cloudimg-amd64.img)"
  type        = string
}

variable "fedora_cloud_image_id" {
  description = "File ID of Fedora cloud image for FreeIPA (e.g., local:iso/Fedora-Cloud-Base-41.qcow2)"
  type        = string
  default     = ""
}

variable "ssh_public_keys" {
  description = "List of SSH public keys for VM access"
  type        = list(string)
}

# =============================================================================
# OPNsense Configuration Variables
# =============================================================================

variable "proxmox_host" {
  description = "Proxmox host IP for SSH connection"
  type        = string
  default     = "192.168.1.30"
}

variable "opnsense_api_key" {
  description = "OPNsense API key (injected via config.xml)"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNsense API secret (plain text, for OPNsense Terraform provider)"
  type        = string
  sensitive   = true
}

variable "opnsense_wan_ip" {
  description = "OPNsense WAN interface IP"
  type        = string
  default     = "192.168.1.1"
}

variable "opnsense_wan_gateway" {
  description = "OPNsense WAN gateway"
  type        = string
  default     = "192.168.1.254"
}

variable "opnsense_lan_ip" {
  description = "OPNsense LAN interface IP"
  type        = string
  default     = "10.10.10.1"
}

variable "opnsense_template_id" {
  description = "VM ID of the OPNsense golden template"
  type        = number
  default     = 9000
}

# =============================================================================
# AdGuard Home DNS Server
# =============================================================================

variable "debian_lxc_template_id" {
  description = "File ID of Debian LXC template (e.g., local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst)"
  type        = string
  default     = ""
}

variable "adguard_ip" {
  description = "Static IP for AdGuard Home DNS server"
  type        = string
  default     = "192.168.1.53"
}
