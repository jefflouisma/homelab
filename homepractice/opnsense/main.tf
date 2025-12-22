# HomePractice OPNsense Configuration - Declarative IaC
# This layer configures OPNsense via its API after initial installation
# The desired state is defined here and applied to OPNsense

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    opnsense = {
      source  = "browningluke/opnsense"
      version = "~> 0.11"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "opnsense" {
  uri            = var.opnsense_url
  api_key        = var.opnsense_api_key
  api_secret     = var.opnsense_api_secret
  allow_insecure = true
}

# =============================================================================
# System Configuration
# =============================================================================

resource "opnsense_unbound_host_override" "k3s" {
  enabled     = true
  hostname    = "k3s"
  domain      = "practice.homelab.local"
  server      = "10.10.10.10"
  description = "HomePractice K3s node"
}

# =============================================================================
# Gateway Configuration  
# =============================================================================

resource "opnsense_gateway" "wan_gw" {
  name            = "WAN_GW"
  interface       = "wan"
  gateway         = var.wan_gateway
  default_gw      = true
  ip_protocol     = "inet"
  monitor_disable = false
  priority        = 255
}

# =============================================================================
# Firewall Aliases
# =============================================================================

resource "opnsense_firewall_alias" "lan_network" {
  name        = "LAN_Network"
  type        = "network"
  content     = [var.lan_network]
  description = "HomePractice LAN network"
  enabled     = true
}

resource "opnsense_firewall_alias" "management_network" {
  name        = "Management_Network"
  type        = "network"
  content     = [var.management_network]
  description = "Home network for management access"
  enabled     = true
}

# =============================================================================
# Firewall Rules
# =============================================================================

resource "opnsense_firewall_filter" "lan_to_any" {
  enabled       = true
  sequence      = 1
  action        = "pass"
  direction     = "in"
  ip_protocol   = "inet"
  interface     = ["lan"]
  protocol      = "any"
  source_net    = "lan"
  destination_net = "any"
  description   = "Allow LAN to any"
  quick         = true
  log           = false
}

resource "opnsense_firewall_filter" "wan_ssh" {
  enabled          = true
  sequence         = 10
  action           = "pass"
  direction        = "in"
  ip_protocol      = "inet"
  interface        = ["wan"]
  protocol         = "TCP"
  source_net       = var.management_network
  destination_net  = "(self)"
  destination_port = "22"
  description      = "Allow SSH from management network"
  quick            = true
  log              = true
}

resource "opnsense_firewall_filter" "wan_https" {
  enabled          = true
  sequence         = 11
  action           = "pass"
  direction        = "in"
  ip_protocol      = "inet"
  interface        = ["wan"]
  protocol         = "TCP"
  source_net       = var.management_network
  destination_net  = "(self)"
  destination_port = "443"
  description      = "Allow HTTPS from management network"
  quick            = true
  log              = false
}

# =============================================================================
# NAT Rules - Outbound
# =============================================================================

resource "opnsense_firewall_nat_source" "lan_outbound" {
  enabled          = true
  sequence         = 1
  interface        = "wan"
  ip_protocol      = "inet"
  protocol         = "any"
  source_net       = var.lan_network
  source_port      = ""
  destination_net  = "any"
  destination_port = ""
  target           = "wan_ip"
  target_port      = ""
  description      = "Outbound NAT for LAN network"
  log              = false
}
