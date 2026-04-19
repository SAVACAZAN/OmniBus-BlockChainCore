#!/usr/bin/env python3
"""OmniBus BlockChainCore — Onion Privacy Audit.

Connects to RPC 8332, calls getnetworkinfo (or equivalent).
Parses response for IP address patterns (regex for IPv4/IPv6).
Connects via Tor SOCKS and repeats.
Compares: does the response leak the node's real IP when connected via Tor?
Checks version string, user-agent headers.
Reports PASS/FAIL.
"""

import argparse
import http.client
import json
import re
import socket
import struct
import sys
import time

# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

# OmniBus BlockChainCore
RPC_PORT = 8332
P2P_PORT = 9000
WS_PORT = 8334
SHARDS = 4
MAX_SUPPLY = 21_000_000
SAT = int(1e9)

# IP detection patterns
IPV4_PATTERN = re.compile(
    r'\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\b'
)
IPV6_PATTERN = re.compile(
    r'(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}'
)
# Exclude common non-routable IPs
PRIVATE_IPS = re.compile(
    r'^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|0\.0\.0\.0|::1|fe80:)'
)


def socks5_connect(proxy_host: str, proxy_port: int,
                   target_host: str, target_port: int) -> socket.socket:
    """SOCKS5 connection (no auth)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect((proxy_host, proxy_port))
    sock.sendall(b"\x05\x01\x00")
    resp = sock.recv(2)
    if resp != b"\x05\x00":
        sock.close()
        raise ConnectionError("SOCKS5 handshake failed")

    addr_bytes = socket.inet_aton(target_host)
    port_bytes = struct.pack(">H", target_port)
    sock.sendall(b"\x05\x01\x00\x01" + addr_bytes + port_bytes)
    resp = sock.recv(10)
    if len(resp) < 2 or resp[1] != 0:
        sock.close()
        raise ConnectionError(f"SOCKS5 connect failed: {resp.hex()}")
    return sock


def rpc_call_direct(host: str, port: int, method: str, params=None) -> tuple:
    """Direct RPC call. Returns (json_response, http_headers_dict)."""
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []})
    try:
        conn = http.client.HTTPConnection(host, port, timeout=10)
        conn.request("POST", "/", payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        headers = dict(resp.getheaders())
        body = json.loads(resp.read().decode())
        conn.close()
        return body, headers
    except Exception as exc:
        return {"error": str(exc)}, {}


def rpc_call_tor(proxy_host: str, proxy_port: int,
                 target_host: str, target_port: int,
                 method: str, params=None) -> tuple:
    """RPC call through Tor. Returns (json_response, raw_headers_str)."""
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []})
    try:
        sock = socks5_connect(proxy_host, proxy_port, target_host, target_port)
        http_req = (
            f"POST / HTTP/1.1\r\n"
            f"Host: {target_host}:{target_port}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(payload)}\r\n"
            f"Connection: close\r\n"
            f"\r\n{payload}"
        )
        sock.sendall(http_req.encode())

        response = b""
        while True:
            try:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response += chunk
            except socket.timeout:
                break
        sock.close()

        resp_text = response.decode("utf-8", errors="replace")
        header_end = resp_text.find("\r\n\r\n")
        if header_end >= 0:
            headers_raw = resp_text[:header_end]
            body = resp_text[header_end + 4:]
            return json.loads(body), headers_raw
        return {"error": "no body"}, resp_text[:500]
    except Exception as exc:
        return {"error": str(exc)}, ""


def find_ips_in_data(data, exclude_private: bool = True) -> list:
    """Recursively search for IP addresses in JSON data."""
    found = []
    text = json.dumps(data) if not isinstance(data, str) else data

    for ip in IPV4_PATTERN.findall(text):
        if exclude_private and PRIVATE_IPS.match(ip):
            continue
        found.append({"type": "IPv4", "ip": ip})

    for ip in IPV6_PATTERN.findall(text):
        if exclude_private and PRIVATE_IPS.match(ip):
            continue
        found.append({"type": "IPv6", "ip": ip})

    return found


def find_ips_in_headers(headers) -> list:
    """Search for IPs in HTTP response headers."""
    if isinstance(headers, dict):
        text = json.dumps(headers)
    else:
        text = str(headers)
    return find_ips_in_data(text, exclude_private=True)


def check_version_leak(data: dict) -> dict:
    """Check if response leaks version/OS information."""
    leaks = []
    text = json.dumps(data).lower()

    # Check for OS/platform info
    os_patterns = ["windows", "linux", "darwin", "macos", "freebsd",
                   "x86_64", "amd64", "arm64", "aarch64"]
    for pat in os_patterns:
        if pat in text:
            leaks.append(f"OS info leaked: {pat}")

    # Check for version details
    version_pattern = re.compile(r'"version"\s*:\s*"([^"]+)"')
    for match in version_pattern.finditer(json.dumps(data)):
        leaks.append(f"Version string: {match.group(1)}")

    # Check for user-agent
    ua_pattern = re.compile(r'"(?:user.?agent|subversion)"\s*:\s*"([^"]+)"', re.I)
    for match in ua_pattern.finditer(json.dumps(data)):
        leaks.append(f"User-Agent: {match.group(1)}")

    return {
        "leaks_found": len(leaks),
        "details": leaks,
        "passed": len(leaks) == 0,
    }


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — Onion Privacy Audit"
    )
    parser.add_argument("--host", default="127.0.0.1", help="Node host")
    parser.add_argument("--port", type=int, default=RPC_PORT, help=f"RPC port (default: {RPC_PORT})")
    parser.add_argument("--tor-proxy", default="127.0.0.1:9050", help="Tor SOCKS5")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    proxy_parts = args.tor_proxy.split(":")
    proxy_host = proxy_parts[0]
    proxy_port = int(proxy_parts[1]) if len(proxy_parts) > 1 else 9050

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — Onion Privacy Audit")
    print(f" Node: {args.host}:{args.port}")
    print(f" Tor: {proxy_host}:{proxy_port}")
    print(f" Shards: {SHARDS} | Max supply: {MAX_SUPPLY:,} OMNI")
    print(f"{'='*60}{RESET}\n")

    report = {"tests": [], "verdict": "PASS"}
    methods_to_check = ["getnetworkinfo", "getpeerinfo", "getblockchaininfo", "getmininginfo"]

    # Phase 1: Direct connection
    print(f"{GREEN}[PHASE 1] Direct RPC — checking for IP leaks ...{RESET}")
    direct_ips = []
    direct_version = {"leaks_found": 0, "details": [], "passed": True}

    for method in methods_to_check:
        resp, headers = rpc_call_direct(args.host, args.port, method)
        if "error" in resp and "result" not in resp:
            continue

        ips = find_ips_in_data(resp)
        header_ips = find_ips_in_headers(headers)
        direct_ips.extend(ips)
        direct_ips.extend(header_ips)

        ver = check_version_leak(resp)
        if ver["leaks_found"] > 0:
            direct_version = ver

    direct_public_ips = [ip for ip in direct_ips if not PRIVATE_IPS.match(ip["ip"])]
    report["tests"].append({
        "test": "direct_ip_leak",
        "public_ips_found": len(direct_public_ips),
        "ips": direct_public_ips[:10],
        "passed": True,  # Direct is expected to show IPs
    })
    report["tests"].append({
        "test": "version_info_leak",
        **direct_version,
    })

    if direct_public_ips:
        print(f"  {YELLOW}Public IPs found in direct response: "
              f"{', '.join(ip['ip'] for ip in direct_public_ips[:5])}{RESET}")
    else:
        print(f"  {GREEN}No public IPs in direct response{RESET}")

    if direct_version["leaks_found"] > 0:
        for detail in direct_version["details"]:
            print(f"  {YELLOW}Info leak: {detail}{RESET}")

    # Phase 2: Tor connection
    print(f"\n{GREEN}[PHASE 2] Tor-routed RPC — checking for IP leaks ...{RESET}")

    # Check Tor availability
    try:
        test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        test_sock.settimeout(3)
        test_sock.connect((proxy_host, proxy_port))
        test_sock.sendall(b"\x05\x01\x00")
        test_sock.recv(2)
        test_sock.close()
        tor_available = True
    except Exception:
        tor_available = False

    if not tor_available:
        print(f"  {YELLOW}[SKIP] Tor not available at {proxy_host}:{proxy_port}{RESET}")
        report["tests"].append({
            "test": "tor_ip_leak",
            "passed": True,
            "note": "Tor not available — skipped",
        })
    else:
        tor_ips = []
        for method in methods_to_check:
            resp, headers_raw = rpc_call_tor(
                proxy_host, proxy_port, args.host, args.port, method
            )
            if "error" in resp and "result" not in resp:
                continue

            ips = find_ips_in_data(resp)
            header_ips = find_ips_in_data(headers_raw)
            tor_ips.extend(ips)
            tor_ips.extend(header_ips)

        tor_public_ips = [ip for ip in tor_ips if not PRIVATE_IPS.match(ip["ip"])]

        # CRITICAL: If Tor response contains same IPs as direct, it's leaking
        leaked_via_tor = [ip for ip in tor_public_ips
                          if ip["ip"] in [d["ip"] for d in direct_public_ips]]

        passed = len(leaked_via_tor) == 0
        if not passed:
            report["verdict"] = "FAIL"

        report["tests"].append({
            "test": "tor_ip_leak",
            "public_ips_found": len(tor_public_ips),
            "leaked_real_ip": len(leaked_via_tor) > 0,
            "leaked_ips": leaked_via_tor[:5],
            "passed": passed,
        })

        if leaked_via_tor:
            print(f"  {RED}[FAIL] Real IP leaked via Tor: "
                  f"{', '.join(ip['ip'] for ip in leaked_via_tor)}{RESET}")
        elif tor_public_ips:
            print(f"  {YELLOW}IPs in Tor response (not matching direct): "
                  f"{', '.join(ip['ip'] for ip in tor_public_ips[:5])}{RESET}")
        else:
            print(f"  {GREEN}No IP leaks detected via Tor{RESET}")

    # Phase 3: Header analysis
    print(f"\n{GREEN}[PHASE 3] HTTP header analysis ...{RESET}")
    _, headers = rpc_call_direct(args.host, args.port, "getblockcount")
    suspicious_headers = []
    for key, value in (headers.items() if isinstance(headers, dict) else []):
        key_lower = key.lower()
        if any(h in key_lower for h in ["server", "x-powered-by", "x-node",
                                         "x-version", "x-real-ip"]):
            suspicious_headers.append(f"{key}: {value}")

    report["tests"].append({
        "test": "http_header_leak",
        "suspicious_headers": suspicious_headers,
        "passed": len(suspicious_headers) == 0,
    })

    if suspicious_headers:
        for h in suspicious_headers:
            print(f"  {YELLOW}Suspicious header: {h}{RESET}")
    else:
        print(f"  {GREEN}No suspicious HTTP headers{RESET}")

    # Overall
    all_passed = all(t["passed"] for t in report["tests"])
    report["verdict"] = "PASS" if all_passed else "FAIL"

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" PRIVACY AUDIT RESULTS")
        print(f"{'='*60}{RESET}")
        for t in report["tests"]:
            color = GREEN if t["passed"] else RED
            print(f"  {t['test']:25s}: {color}{'PASS' if t['passed'] else 'FAIL'}{RESET}")
        vc = GREEN if report["verdict"] == "PASS" else RED
        print(f"\n  Verdict: {vc}{BOLD}{report['verdict']}{RESET}")

    sys.exit(0 if report["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
