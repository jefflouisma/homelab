# HomePractice OPNsense Configuration Variables

variable "opnsense_url" {
  description = "OPNsense API URL"
  type        = string
  default     = "https://192.168.1.1"
}

variable "opnsense_api_key" {
  description = "OPNsense API key"
  type        = string
  sensitive   = true
}

variable "opnsense_api_secret" {
  description = "OPNsense API secret"
  type        = string
  sensitive   = true
}

variable "wan_gateway" {
  description = "WAN gateway IP address"
  type        = string
  default     = "192.168.1.254"
}

variable "lan_network" {
  description = "LAN network CIDR"
  type        = string
  default     = "10.10.10.0/24"
}

variable "management_network" {
  description = "Management network allowed to access OPNsense"
  type        = string
  default     = "192.168.1.0/24"
}
