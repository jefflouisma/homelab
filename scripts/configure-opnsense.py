#!/usr/bin/env python3
"""
OPNsense Configuration Script - IaC for HomePractice Environment
Configures: LAN interface, DHCP server, WireGuard VPN
"""

import requests
import json
import urllib3
import sys
import time

# Disable SSL warnings for self-signed cert
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
OPNSENSE_HOST = "https://192.168.1.1"
USERNAME = "root"
PASSWORD = "opnsense"  # Default password - change after setup

# Network Configuration
LAN_IP = "10.10.10.1"
LAN_SUBNET = "24"
DHCP_START = "10.10.10.100"
DHCP_END = "10.10.10.199"

# WireGuard Configuration
WG_PORT = "51820"
WG_TUNNEL_ADDRESS = "10.8.0.1/24"


class OPNsenseAPI:
    def __init__(self, host, username, password):
        self.host = host
        self.session = requests.Session()
        self.session.verify = False
        self.session.auth = (username, password)
        
    def get(self, endpoint):
        """GET request to OPNsense API"""
        url = f"{self.host}/api{endpoint}"
        try:
            r = self.session.get(url, timeout=30)
            return r.json() if r.status_code == 200 else {"error": r.status_code, "text": r.text}
        except Exception as e:
            return {"error": str(e)}
    
    def post(self, endpoint, data=None):
        """POST request to OPNsense API"""
        url = f"{self.host}/api{endpoint}"
        try:
            r = self.session.post(url, json=data or {}, timeout=30)
            return r.json() if r.status_code == 200 else {"error": r.status_code, "text": r.text}
        except Exception as e:
            return {"error": str(e)}


def configure_lan_interface(api):
    """Configure LAN interface with static IP"""
    print("Configuring LAN interface...")
    
    # Get current interface config
    result = api.get("/interfaces/overview/export")
    print(f"  Current interfaces: {json.dumps(result, indent=2)[:200]}...")
    
    # Set LAN IP via interfaces API
    lan_config = {
        "interface": {
            "if": "vtnet1",
            "ipaddr": LAN_IP,
            "subnet": LAN_SUBNET,
            "enable": "1"
        }
    }
    
    result = api.post("/interfaces/lan/set", lan_config)
    print(f"  LAN config result: {result}")
    
    return result


def configure_dhcp_server(api):
    """Enable DHCP server on LAN"""
    print("Configuring DHCP server on LAN...")
    
    dhcp_config = {
        "dhcpd": {
            "enable": "1",
            "range": {
                "from": DHCP_START,
                "to": DHCP_END
            },
            "gateway": LAN_IP
        }
    }
    
    result = api.post("/dhcpv4/settings/set", dhcp_config)
    print(f"  DHCP config result: {result}")
    
    return result


def configure_wireguard(api):
    """Configure WireGuard VPN server"""
    print("Configuring WireGuard VPN...")
    
    # Check if WireGuard plugin is installed
    result = api.get("/core/firmware/status")
    print(f"  Firmware status: checking plugins...")
    
    # Generate WireGuard server keys
    keygen_result = api.post("/wireguard/server/keyPair")
    print(f"  Generated keys: {keygen_result}")
    
    if "error" not in keygen_result:
        pubkey = keygen_result.get("pubkey", "")
        privkey = keygen_result.get("privkey", "")
        
        # Create WireGuard server instance
        wg_server = {
            "server": {
                "enabled": "1",
                "name": "wg-homepractice",
                "pubkey": pubkey,
                "privkey": privkey,
                "port": WG_PORT,
                "tunneladdress": WG_TUNNEL_ADDRESS,
                "dns": LAN_IP
            }
        }
        
        result = api.post("/wireguard/server/addServer", wg_server)
        print(f"  WireGuard server created: {result}")
        
        return {"pubkey": pubkey, "result": result}
    
    return keygen_result


def apply_changes(api):
    """Apply all pending changes"""
    print("Applying changes...")
    
    # Reconfigure interfaces
    result = api.post("/interfaces/overview/reconfigure")
    print(f"  Interfaces reconfigured: {result}")
    
    # Restart services
    result = api.post("/dhcpv4/service/restart")
    print(f"  DHCP service restarted: {result}")
    
    return result


def main():
    print("=" * 50)
    print("OPNsense IaC Configuration")
    print("=" * 50)
    print(f"Host: {OPNSENSE_HOST}")
    print(f"LAN: {LAN_IP}/{LAN_SUBNET}")
    print(f"DHCP Range: {DHCP_START} - {DHCP_END}")
    print("=" * 50)
    
    api = OPNsenseAPI(OPNSENSE_HOST, USERNAME, PASSWORD)
    
    # Test connection
    print("\nTesting API connection...")
    result = api.get("/core/firmware/status")
    if "error" in result:
        print(f"ERROR: Cannot connect to OPNsense API: {result}")
        print("\nPossible issues:")
        print("  1. Default password may have been changed")
        print("  2. API may not be enabled")
        print("  3. Initial wizard may not be completed")
        sys.exit(1)
    
    print(f"  Connected! OPNsense version: {result.get('product_version', 'unknown')}")
    
    # Configure LAN
    configure_lan_interface(api)
    time.sleep(2)
    
    # Configure DHCP
    configure_dhcp_server(api)
    time.sleep(2)
    
    # Configure WireGuard
    wg_result = configure_wireguard(api)
    
    # Apply changes
    apply_changes(api)
    
    print("\n" + "=" * 50)
    print("Configuration Complete!")
    print("=" * 50)
    print(f"LAN IP: {LAN_IP}/{LAN_SUBNET}")
    print(f"DHCP: {DHCP_START} - {DHCP_END}")
    if "pubkey" in wg_result:
        print(f"WireGuard Public Key: {wg_result['pubkey']}")
    print("\nNext steps:")
    print("  1. Access OPNsense at https://10.10.10.1 (via LAN)")
    print("  2. Configure WireGuard peer for remote access")
    print("  3. Test K3s VM connectivity at 10.10.10.10")


if __name__ == "__main__":
    main()
