#!/bin/bash
# OPNsense Configuration Script - IaC for HomePractice
# Configures: Interface swap, LAN IP, DHCP, WireGuard

set -e

OPNSENSE_IP="192.168.1.1"
OPNSENSE_PASS="opnsense"

echo "=== OPNsense IaC Configuration ==="

# Backup current config
echo "Backing up config..."
sshpass -p "$OPNSENSE_PASS" ssh -o StrictHostKeyChecking=no root@$OPNSENSE_IP "cp /conf/config.xml /conf/config.xml.bak"

# Create new interface config section
# WAN: vtnet0 (vmbr0 - home network) with DHCP
# LAN: vtnet1 (vmbr1 - isolated) with 10.10.10.1/24
echo "Configuring interfaces..."

sshpass -p "$OPNSENSE_PASS" ssh root@$OPNSENSE_IP 'cat > /tmp/fix-interfaces.php << "EOFPHP"
<?php
require_once("config.inc");
require_once("interfaces.inc");
require_once("util.inc");

// Load config
$config = parse_config(true);

// Fix interface assignments
// WAN = vtnet0 (home network bridge vmbr0)
$config["interfaces"]["wan"]["if"] = "vtnet0";
$config["interfaces"]["wan"]["ipaddr"] = "dhcp";
$config["interfaces"]["wan"]["ipaddrv6"] = "dhcp6";
$config["interfaces"]["wan"]["enable"] = "1";
unset($config["interfaces"]["wan"]["subnet"]);

// LAN = vtnet1 (isolated bridge vmbr1)
$config["interfaces"]["lan"]["if"] = "vtnet1";
$config["interfaces"]["lan"]["ipaddr"] = "10.10.10.1";
$config["interfaces"]["lan"]["subnet"] = "24";
$config["interfaces"]["lan"]["enable"] = "1";

// Configure DHCP on LAN
if (!isset($config["dhcpd"])) {
    $config["dhcpd"] = array();
}
$config["dhcpd"]["lan"] = array(
    "enable" => "",
    "range" => array(
        "from" => "10.10.10.100",
        "to" => "10.10.10.199"
    ),
    "gateway" => "10.10.10.1"
);

// Save config
write_config("IaC: Configured interfaces and DHCP");

echo "Configuration updated successfully\n";
echo "WAN: vtnet0 (DHCP)\n";
echo "LAN: vtnet1 (10.10.10.1/24)\n";
echo "DHCP: 10.10.10.100-199\n";
?>
EOFPHP'

# Run the PHP config script
echo "Applying configuration..."
sshpass -p "$OPNSENSE_PASS" ssh root@$OPNSENSE_IP "php /tmp/fix-interfaces.php"

# Reload interfaces
echo "Reloading interfaces..."
sshpass -p "$OPNSENSE_PASS" ssh root@$OPNSENSE_IP "configctl interface reload"

echo ""
echo "=== Configuration Complete ==="
echo "OPNsense will get new WAN IP via DHCP from your router."
echo "LAN is now 10.10.10.1/24 with DHCP 10.10.10.100-199"
echo ""
echo "K3s VM at 10.10.10.10 should now have network access."
