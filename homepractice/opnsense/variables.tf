# HomePractice OPNsense Configuration Variables
# Credentials from golden template (VM 9000)

variable "opnsense_url" {
  description = "OPNsense API URL (use current DHCP IP initially)"
  type        = string
  default     = "https://192.168.1.1"
}

variable "opnsense_current_ip" {
  description = "Current OPNsense IP (DHCP on first boot)"
  type        = string
  default     = "192.168.1.1"
}

variable "opnsense_password" {
  description = "OPNsense root password for SSH"
  type        = string
  sensitive   = true
  default     = "opnsense"
}

variable "opnsense_api_key" {
  description = "OPNsense API key (baked into golden template)"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNsense API secret (baked into golden template)"
  type        = string
  sensitive   = true
}

# Interface IP Configuration
variable "management_ip" {
  description = "Management interface IP (vtnet0)"
  type        = string
  default     = "192.168.1.41"
}

variable "wan_ip" {
  description = "WAN interface IP (vtnet1)"
  type        = string
  default     = "192.168.1.1"
}

variable "wan_gateway" {
  description = "WAN gateway IP"
  type        = string
  default     = "192.168.1.254"
}

variable "internal_ip" {
  description = "Internal/LAN interface IP (vtnet2)"
  type        = string
  default     = "10.10.10.1"
}

variable "lan_network" {
  description = "LAN network CIDR"
  type        = string
  default     = "10.10.10.0/24"
}

variable "management_network" {
  description = "Management network for firewall rules"
  type        = string
  default     = "192.168.1.0/24"
}

# WireGuard VPN
variable "wireguard_port" {
  description = "WireGuard VPN listen port"
  type        = number
  default     = 51820
}

variable "wireguard_network" {
  description = "WireGuard VPN network CIDR"
  type        = string
  default     = "10.10.20.0/24"
}
