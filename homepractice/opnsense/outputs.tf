# HomePractice OPNsense Configuration Outputs

output "gateway_configured" {
  description = "WAN gateway configuration status"
  value       = opnsense_gateway.wan_gw.name
}

output "firewall_rules" {
  description = "Configured firewall rules"
  value = [
    opnsense_firewall_filter.lan_to_any.description,
    opnsense_firewall_filter.wan_ssh.description,
    opnsense_firewall_filter.wan_https.description,
  ]
}

output "nat_rules" {
  description = "Configured NAT rules"
  value = [
    opnsense_firewall_nat_source.lan_outbound.description,
  ]
}
