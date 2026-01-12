#!/usr/bin/env python3
"""
Moonlight Test Client for Fenrir

Tests the Moonlight/GameStream API endpoints on the Fenrir moonlight-proxy.
Can be used for automated verification of the streaming setup.

Usage:
    python moonlight-test.py --host 192.168.1.223 --action list-apps
    python moonlight-test.py --host 192.168.1.223 --action server-info
    python moonlight-test.py --host 192.168.1.223 --action pair
"""

import argparse
import requests
import xml.etree.ElementTree as ET
from urllib.parse import urljoin
import sys
import json


class MoonlightTestClient:
    """Test client for Moonlight/GameStream HTTP API"""
    
    def __init__(self, host: str, http_port: int = 47989, https_port: int = 47984):
        self.host = host
        self.http_port = http_port
        self.https_port = https_port
        self.http_base = f"http://{host}:{http_port}"
        self.https_base = f"https://{host}:{https_port}"
        self.session = requests.Session()
        # Disable SSL verification for self-signed certs
        self.session.verify = False
        
    def get_server_info(self) -> dict:
        """Get server information (works without pairing)"""
        url = f"{self.http_base}/serverinfo"
        try:
            response = self.session.get(url, timeout=10)
            response.raise_for_status()
            return self._parse_xml(response.text)
        except requests.exceptions.RequestException as e:
            return {"error": str(e)}
    
    def get_app_list(self) -> list:
        """Get list of available apps (requires pairing)"""
        # This requires HTTPS with client certificate
        url = f"{self.https_base}/applist"
        try:
            response = self.session.get(url, timeout=10)
            response.raise_for_status()
            return self._parse_app_list(response.text)
        except requests.exceptions.RequestException as e:
            return {"error": str(e)}
    
    def get_dashboard(self) -> str:
        """Get the pairing dashboard HTML"""
        url = f"{self.http_base}/dashboard"
        try:
            response = self.session.get(url, timeout=10)
            response.raise_for_status()
            return response.text
        except requests.exceptions.RequestException as e:
            return f"Error: {e}"
    
    def check_connectivity(self) -> dict:
        """Quick connectivity check"""
        results = {}
        
        # Check HTTP
        try:
            response = self.session.get(
                f"{self.http_base}/livez", 
                timeout=5
            )
            results["http"] = response.status_code == 200
        except:
            results["http"] = False
        
        # Check HTTPS
        try:
            response = self.session.get(
                f"{self.https_base}/serverinfo", 
                timeout=5
            )
            results["https"] = response.status_code in [200, 401]
        except:
            results["https"] = False
        
        return results
    
    def _parse_xml(self, xml_text: str) -> dict:
        """Parse XML response into dictionary"""
        try:
            root = ET.fromstring(xml_text)
            result = {"status_code": root.get("status_code")}
            for child in root:
                if len(child) == 0:
                    result[child.tag] = child.text
                else:
                    result[child.tag] = self._element_to_dict(child)
            return result
        except ET.ParseError as e:
            return {"error": f"XML parse error: {e}", "raw": xml_text[:500]}
    
    def _element_to_dict(self, element) -> dict:
        """Recursively convert XML element to dict"""
        result = {}
        for child in element:
            if len(child) == 0:
                result[child.tag] = child.text
            else:
                result[child.tag] = self._element_to_dict(child)
        return result
    
    def _parse_app_list(self, xml_text: str) -> list:
        """Parse app list XML"""
        try:
            root = ET.fromstring(xml_text)
            apps = []
            for app in root.findall('.//App'):
                apps.append({
                    'id': app.findtext('ID'),
                    'name': app.findtext('AppTitle'),
                })
            return apps
        except ET.ParseError as e:
            return [{"error": f"XML parse error: {e}"}]


def main():
    parser = argparse.ArgumentParser(description='Moonlight Test Client for Fenrir')
    parser.add_argument('--host', default='192.168.1.223', help='Moonlight proxy host')
    parser.add_argument('--http-port', type=int, default=47989, help='HTTP port')
    parser.add_argument('--https-port', type=int, default=47984, help='HTTPS port')
    parser.add_argument('--action', choices=['server-info', 'list-apps', 'dashboard', 'check'],
                        default='server-info', help='Action to perform')
    parser.add_argument('--json', action='store_true', help='Output as JSON')
    
    args = parser.parse_args()
    
    # Suppress SSL warnings
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    
    client = MoonlightTestClient(args.host, args.http_port, args.https_port)
    
    if args.action == 'server-info':
        result = client.get_server_info()
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print("=== Server Info ===")
            if "error" in result:
                print(f"Error: {result['error']}")
                sys.exit(1)
            print(f"Hostname: {result.get('hostname', 'N/A')}")
            print(f"State: {result.get('state', 'N/A')}")
            print(f"Pair Status: {'Paired' if result.get('PairStatus') == '1' else 'Not Paired'}")
            print(f"Current Game: {result.get('currentgame', 'None')}")
            
    elif args.action == 'list-apps':
        result = client.get_app_list()
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print("=== App List ===")
            if isinstance(result, list):
                if not result:
                    print("No apps found")
                else:
                    for app in result:
                        if 'error' in app:
                            print(f"Error: {app['error']}")
                        else:
                            print(f"  [{app['id']}] {app['name']}")
            else:
                print(f"Error: {result.get('error', 'Unknown error')}")
            
    elif args.action == 'dashboard':
        html = client.get_dashboard()
        if 'pending' in html.lower():
            print("Dashboard loaded - pending pairing requests found")
        elif 'no pending' in html.lower():
            print("Dashboard loaded - no pending pairing requests")
        else:
            print("Dashboard loaded")
        if args.json:
            print(json.dumps({"html_length": len(html)}))
            
    elif args.action == 'check':
        result = client.check_connectivity()
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            print("=== Connectivity Check ===")
            print(f"HTTP (:{args.http_port}):  {'✅ OK' if result['http'] else '❌ Failed'}")
            print(f"HTTPS (:{args.https_port}): {'✅ OK' if result['https'] else '❌ Failed'}")
            
            if result['http'] and result['https']:
                print("\n✅ All checks passed!")
                sys.exit(0)
            else:
                print("\n❌ Some checks failed")
                sys.exit(1)


if __name__ == '__main__':
    main()
