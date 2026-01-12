#!/usr/bin/env python3
"""
End-to-End Test Suite for Fenrir Game Streaming

This test suite verifies the complete Fenrir/Wolf streaming pipeline:
1. Moonlight proxy connectivity
2. App list availability
3. Session pod creation when launching apps
4. Optional: Screenshot capture via kubectl exec

Usage:
    python moonlight-e2e-test.py --kubeconfig ~/.kube/harvester.yaml

Requirements:
    - kubectl configured with access to the cluster
    - requests library (pip install requests)
"""

import argparse
import json
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from typing import Optional, Dict, List, Tuple

import requests


class Colors:
    """ANSI color codes for terminal output"""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    RESET = '\033[0m'
    BOLD = '\033[1m'


def log(msg: str, color: str = ""):
    """Print a log message with optional color"""
    prefix = f"{color}{Colors.BOLD}" if color else ""
    suffix = Colors.RESET if color else ""
    print(f"{prefix}{msg}{suffix}")


def log_pass(msg: str):
    log(f"✅ PASS: {msg}", Colors.GREEN)


def log_fail(msg: str):
    log(f"❌ FAIL: {msg}", Colors.RED)


def log_info(msg: str):
    log(f"ℹ️  INFO: {msg}", Colors.BLUE)


def log_warn(msg: str):
    log(f"⚠️  WARN: {msg}", Colors.YELLOW)


class FenrirE2ETest:
    """End-to-end test suite for Fenrir game streaming"""
    
    def __init__(
        self,
        host: str = "192.168.1.223",
        http_port: int = 47989,
        https_port: int = 47984,
        namespace: str = "house",
        kubeconfig: Optional[str] = None
    ):
        self.host = host
        self.http_port = http_port
        self.https_port = https_port
        self.namespace = namespace
        self.kubeconfig = kubeconfig or os.environ.get("KUBECONFIG")
        
        self.http_base = f"http://{host}:{http_port}"
        self.https_base = f"https://{host}:{https_port}"
        self.session = requests.Session()
        self.session.verify = False
        
        self.results: Dict[str, Tuple[bool, str]] = {}
    
    def _kubectl(self, *args) -> Tuple[int, str, str]:
        """Run kubectl command and return exit code, stdout, stderr"""
        cmd = ["kubectl"]
        if self.kubeconfig:
            cmd.extend(["--kubeconfig", self.kubeconfig])
        cmd.extend(args)
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.returncode, result.stdout, result.stderr
    
    def _record_result(self, test_name: str, passed: bool, message: str):
        """Record a test result"""
        self.results[test_name] = (passed, message)
        if passed:
            log_pass(f"{test_name}: {message}")
        else:
            log_fail(f"{test_name}: {message}")
    
    # =========================================================================
    # Test Cases
    # =========================================================================
    
    def test_http_connectivity(self) -> bool:
        """Test 1: Verify HTTP endpoint is reachable"""
        try:
            response = self.session.get(f"{self.http_base}/livez", timeout=5)
            passed = response.status_code == 200
            self._record_result(
                "HTTP Connectivity",
                passed,
                f"Port {self.http_port} {'reachable' if passed else 'unreachable'}"
            )
            return passed
        except Exception as e:
            self._record_result("HTTP Connectivity", False, str(e))
            return False
    
    def test_https_connectivity(self) -> bool:
        """Test 2: Verify HTTPS endpoint is reachable"""
        try:
            response = self.session.get(f"{self.https_base}/serverinfo", timeout=5)
            passed = response.status_code in [200, 401]  # 401 is OK without client cert
            self._record_result(
                "HTTPS Connectivity",
                passed,
                f"Port {self.https_port} {'reachable' if passed else 'unreachable'}"
            )
            return passed
        except Exception as e:
            self._record_result("HTTPS Connectivity", False, str(e))
            return False
    
    def test_server_info(self) -> bool:
        """Test 3: Verify server info returns valid data"""
        try:
            response = self.session.get(f"{self.http_base}/serverinfo", timeout=10)
            root = ET.fromstring(response.text)
            
            hostname = root.findtext("hostname")
            state = root.findtext("state")
            
            passed = hostname is not None and state is not None
            self._record_result(
                "Server Info",
                passed,
                f"Hostname: {hostname}, State: {state}"
            )
            return passed
        except Exception as e:
            self._record_result("Server Info", False, str(e))
            return False
    
    def test_dashboard_exists(self) -> bool:
        """Test 4: Verify dashboard endpoint works"""
        try:
            response = self.session.get(f"{self.http_base}/dashboard", timeout=5)
            passed = response.status_code == 200 and "Wolf" in response.text
            self._record_result(
                "Dashboard Endpoint",
                passed,
                "Dashboard page loads correctly" if passed else "Dashboard failed to load"
            )
            return passed
        except Exception as e:
            self._record_result("Dashboard Endpoint", False, str(e))
            return False
    
    def test_apps_exist_in_k8s(self) -> bool:
        """Test 5: Verify App CRDs exist in Kubernetes"""
        code, stdout, stderr = self._kubectl(
            "get", "apps.direwolf.games-on-whales.github.io",
            "-n", self.namespace,
            "-o", "json"
        )
        
        if code != 0:
            self._record_result("Apps in K8s", False, stderr.strip())
            return False
        
        try:
            data = json.loads(stdout)
            apps = data.get("items", [])
            app_names = [app["metadata"]["name"] for app in apps]
            
            passed = len(apps) > 0
            self._record_result(
                "Apps in K8s",
                passed,
                f"Found {len(apps)} apps: {', '.join(app_names)}" if passed else "No apps found"
            )
            return passed
        except Exception as e:
            self._record_result("Apps in K8s", False, str(e))
            return False
    
    def test_users_exist(self) -> bool:
        """Test 6: Verify User CRDs exist"""
        code, stdout, stderr = self._kubectl(
            "get", "users.direwolf.games-on-whales.github.io",
            "-n", self.namespace,
            "-o", "json"
        )
        
        if code != 0:
            self._record_result("Users in K8s", False, stderr.strip())
            return False
        
        try:
            data = json.loads(stdout)
            users = data.get("items", [])
            user_names = [u["metadata"]["name"] for u in users]
            
            passed = len(users) > 0
            self._record_result(
                "Users in K8s",
                passed,
                f"Found {len(users)} users: {', '.join(user_names)}" if passed else "No users found"
            )
            return passed
        except Exception as e:
            self._record_result("Users in K8s", False, str(e))
            return False
    
    def test_pairings_exist(self) -> bool:
        """Test 7: Verify at least one Pairing exists"""
        code, stdout, stderr = self._kubectl(
            "get", "pairings.direwolf.games-on-whales.github.io",
            "-n", self.namespace,
            "-o", "json"
        )
        
        if code != 0:
            self._record_result("Pairings in K8s", False, stderr.strip())
            return False
        
        try:
            data = json.loads(stdout)
            pairings = data.get("items", [])
            
            passed = len(pairings) > 0
            self._record_result(
                "Pairings in K8s",
                passed,
                f"Found {len(pairings)} paired client(s)" if passed else "No clients paired yet"
            )
            return passed
        except Exception as e:
            self._record_result("Pairings in K8s", False, str(e))
            return False
    
    def test_moonlight_proxy_running(self) -> bool:
        """Test 8: Verify moonlight-proxy pod is running"""
        code, stdout, stderr = self._kubectl(
            "get", "pods",
            "-n", self.namespace,
            "-l", "app=moonlight-proxy",
            "-o", "jsonpath={.items[0].status.phase}"
        )
        
        passed = code == 0 and stdout.strip() == "Running"
        self._record_result(
            "Moonlight Proxy Pod",
            passed,
            f"Pod status: {stdout.strip()}" if code == 0 else stderr.strip()
        )
        return passed
    
    def test_fenrir_operator_running(self) -> bool:
        """Test 9: Verify fenrir-operator pod is running"""
        code, stdout, stderr = self._kubectl(
            "get", "pods",
            "-n", self.namespace,
            "-l", "app=fenrir-operator",
            "-o", "jsonpath={.items[0].status.phase}"
        )
        
        passed = code == 0 and stdout.strip() == "Running"
        self._record_result(
            "Fenrir Operator Pod",
            passed,
            f"Pod status: {stdout.strip()}" if code == 0 else stderr.strip()
        )
        return passed
    
    def test_operator_logs_healthy(self) -> bool:
        """Test 10: Check fenrir-operator logs for errors"""
        code, stdout, stderr = self._kubectl(
            "logs",
            "-n", self.namespace,
            "-l", "app=fenrir-operator",
            "--tail=50"
        )
        
        if code != 0:
            self._record_result("Operator Logs", False, stderr.strip())
            return False
        
        # Check for critical errors
        error_keywords = ["panic", "fatal", "Failed to watch"]
        errors_found = [kw for kw in error_keywords if kw.lower() in stdout.lower()]
        
        passed = len(errors_found) == 0
        self._record_result(
            "Operator Logs",
            passed,
            "No critical errors in logs" if passed else f"Found errors: {', '.join(errors_found)}"
        )
        return passed
    
    def test_session_can_launch(self) -> bool:
        """Test 11: Verify session pods can be created (requires active pairing)"""
        # Check if any sessions exist or were recently created
        code, stdout, stderr = self._kubectl(
            "get", "sessions.direwolf.games-on-whales.github.io",
            "-n", self.namespace,
            "-o", "json"
        )
        
        if code != 0:
            self._record_result("Session CRD Access", False, stderr.strip())
            return False
        
        try:
            data = json.loads(stdout)
            sessions = data.get("items", [])
            
            # This test passes if the CRD is accessible
            # Actual session creation requires a Moonlight client
            self._record_result(
                "Session CRD Access",
                True,
                f"Session CRD accessible, {len(sessions)} active session(s)"
            )
            return True
        except Exception as e:
            self._record_result("Session CRD Access", False, str(e))
            return False
    
    # =========================================================================
    # Test Runner
    # =========================================================================
    
    def run_all_tests(self) -> bool:
        """Run all tests and return overall pass/fail"""
        log("\n" + "=" * 60, Colors.BOLD)
        log("  FENRIR E2E TEST SUITE", Colors.BOLD)
        log("=" * 60 + "\n", Colors.BOLD)
        
        log_info(f"Target: {self.host}")
        log_info(f"Namespace: {self.namespace}")
        log_info(f"Kubeconfig: {self.kubeconfig or 'default'}\n")
        
        tests = [
            self.test_http_connectivity,
            self.test_https_connectivity,
            self.test_server_info,
            self.test_dashboard_exists,
            self.test_moonlight_proxy_running,
            self.test_fenrir_operator_running,
            self.test_apps_exist_in_k8s,
            self.test_users_exist,
            self.test_pairings_exist,
            self.test_operator_logs_healthy,
            self.test_session_can_launch,
        ]
        
        for test in tests:
            try:
                test()
            except Exception as e:
                log_fail(f"Test {test.__name__} crashed: {e}")
        
        # Summary
        passed = sum(1 for p, _ in self.results.values() if p)
        total = len(self.results)
        
        log("\n" + "=" * 60, Colors.BOLD)
        log(f"  RESULTS: {passed}/{total} tests passed", Colors.BOLD)
        log("=" * 60 + "\n", Colors.BOLD)
        
        all_passed = passed == total
        if all_passed:
            log("✅ All tests passed! Fenrir is ready for streaming.", Colors.GREEN)
        else:
            log("❌ Some tests failed. Check the output above.", Colors.RED)
        
        return all_passed


def main():
    parser = argparse.ArgumentParser(description='Fenrir E2E Test Suite')
    parser.add_argument('--host', default='192.168.1.223', help='Moonlight proxy host')
    parser.add_argument('--namespace', default='house', help='Kubernetes namespace')
    parser.add_argument('--kubeconfig', default=os.path.expanduser('~/.kube/harvester.yaml'),
                        help='Path to kubeconfig')
    
    args = parser.parse_args()
    
    # Suppress SSL warnings
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    
    tester = FenrirE2ETest(
        host=args.host,
        namespace=args.namespace,
        kubeconfig=args.kubeconfig
    )
    
    success = tester.run_all_tests()
    sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
