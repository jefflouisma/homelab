# Barleta Infrastructure Variables

variable "harvester_kubeconfig" {
  description = "Path to the Harvester kubeconfig file"
  type        = string
  default     = "~/.kube/harvester.yaml"
}

variable "cluster_network_name" {
  description = "Name of the Harvester cluster network"
  type        = string
  default     = "mgmt"
}

variable "vlan_id" {
  description = "VLAN ID for the barleta network (0 for no VLAN)"
  type        = number
  default     = 0
}

variable "gateway" {
  description = "Network gateway IP"
  type        = string
  default     = "192.168.1.254"
}

variable "dns_servers" {
  description = "DNS server IPs"
  type        = list(string)
  default     = ["192.168.1.254", "8.8.8.8"]
}

variable "freeipa_ip" {
  description = "Static IP for FreeIPA VM (CIDR notation)"
  type        = string
  default     = "192.168.1.212/24"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key file"
  type        = string
  default     = "../../id_rsa.pub"
}
