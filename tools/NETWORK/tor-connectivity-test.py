#!/usr/bin/env python3
"""OmniBus BlockChainCore — Tor Connectivity Test.

Connects to node P2P port 9000 and RPC port 8332 through SOCKS5 proxy
(default 127.0.0.1:9050).  Sends JSON-RPC getblockcount.
If Tor not running, skips gracefully with YELLOW warning.
Measures latency: direct vs Tor.
"""

import argparse
import http.client
import json
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
WS_PORT = 8334
P2P_PORT = 9000
SHARDS = 4
MAX_SUPPLY = 21_000_000
SAT = int(1e9)


def socks5_connect(proxy_host: str, proxy_port: int,
                   target_host: str, target_port: int,
                   timeout: float = 10) -> socket.socket:
    """Connect to target through SOCKS5 proxy (no auth)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect((proxy_host, proxy_port))

    # SOCKS5 greeting: version=5, 1 method, no-auth=0
    sock.sendall(b"\x05\x01\x00")
    resp = sock.recv(2)
    if resp != b"\x05\x00":
        sock.close()
        raise ConnectionError(f"SOCKS5 auth rejected: {resp.hex()}")

    # SOCKS5 connect request
    # VER=5, CMD=1(connect), RSV=0, ATYP=1(IPv4)
    addr_bytes = socket.inet_aton(target_host)
    port_bytes = struct.pack(">H", target_port)
    sock.sendall(b"\x05\x01\x00\x01" + addr_bytes + port_bytes)

    resp = sock.recv(10)
    if len(resp) < 2 or resp[1] != 0:
        sock.close()
        status = resp[1] if len(resp) > 1 else -1
        raise ConnectionError(f"SOCKS5 connect failed, status={status}")

    return sock


def rpc_via_direct(host: str, port: int, method: str) -> tuple:
    """Direct JSON-RPC call. Returns (result_dict, latency_ms)."""
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": []})
    t0 = time.time()
    try:
        conn = http.client.HTTPConnection(host, port, timeout=10)
        conn.request("POST", "/", payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        data = json.loads(resp.read().decode())
        conn.close()
        latency = (time.time() - t0) * 1000
        return data, latency
    except Exception as exc:
        latency = (time.time() - t0) * 1000
        return {"error": str(exc)}, latency


def rpc_via_tor(proxy_host: str, proxy_port: int,
                target_host: str, target_port: int,
                method: str) -> tuple:
    """JSON-RPC call through Tor SOCKS5. Returns (result_dict, latency_ms)."""
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": []})
    t0 = time.time()
    try:
        sock = socks5_connect(proxy_host, proxy_port, target_host, target_port)

        # Build HTTP request manually
        http_req = (
            f"POST / HTTP/1.1\r\n"
            f"Host: {target_host}:{target_port}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(payload)}\r\n"
            f"Connection: close\r\n"
            f"\r\n"
            f"{payload}"
        )
        sock.sendall(http_req.encode())

        # Read response
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
        latency = (time.time() - t0) * 1000

        # Parse HTTP response
        resp_text = response.decode("utf-8", errors="replace")
        body_start = resp_text.find("\r\n\r\n")
        if body_start >= 0:
            body = resp_text[body_start + 4:]
            data = json.loads(body)
        else:
            data = {"error": "no HTTP body", "raw": resp_text[:200]}

        return data, latency
    except Exception as exc:
        latency = (time.time() - t0) * 1000
        return {"error": str(exc)}, latency


def check_tor_available(proxy_host: str, proxy_port: int) -> bool:
    """Check if Tor SOCKS5 proxy is running."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((proxy_host, proxy_port))
        # Send SOCKS5 greeting
        sock.sendall(b"\x05\x01\x00")
        resp = sock.recv(2)
        sock.close()
        return resp == b"\x05\x00"
    except Exception:
        return False


def tcp_connect_test(host: str, port: int, proxy_host: str = None,
                     proxy_port: int = None) -> tuple:
    """Test TCP connectivity. Returns (success, latency_ms)."""
    t0 = time.time()
    try:
        if proxy_host:
            sock = socks5_connect(proxy_host, proxy_port, host, port)
        else:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(10)
            sock.connect((host, port))
        sock.close()
        return True, (time.time() - t0) * 1000
    except Exception:
        return False, (time.time() - t0) * 1000


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — Tor Connectivity Test"
    )
    parser.add_argument("--tor-proxy", default="127.0.0.1:9050",
                        help="Tor SOCKS5 proxy (default: 127.0.0.1:9050)")
    parser.add_argument("--rpc-host", default="127.0.0.1",
                        help="Node RPC host (default: 127.0.0.1)")
    parser.add_argument("--rpc-port", type=int, default=RPC_PORT,
                        help=f"Node RPC port (default: {RPC_PORT})")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    proxy_parts = args.tor_proxy.split(":")
    proxy_host = proxy_parts[0]
    proxy_port = int(proxy_parts[1]) if len(proxy_parts) > 1 else 9050

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — Tor Connectivity Test")
    print(f" Node: {args.rpc_host}:{args.rpc_port}")
    print(f" P2P: {args.rpc_host}:{P2P_PORT}")
    print(f" Tor proxy: {proxy_host}:{proxy_port}")
    print(f" Shards: {SHARDS} | Max supply: {MAX_SUPPLY:,} OMNI")
    print(f"{'='*60}{RESET}\n")

    report = {
        "node": f"{args.rpc_host}:{args.rpc_port}",
        "tor_proxy": f"{proxy_host}:{proxy_port}",
        "tests": [],
    }

    # 1. Check Tor availability
    print(f"{GREEN}[1/5] Checking Tor proxy ...{RESET}")
    tor_available = check_tor_available(proxy_host, proxy_port)
    if not tor_available:
        print(f"  {YELLOW}[SKIP] Tor SOCKS5 not running at {proxy_host}:{proxy_port}{RESET}")
        print(f"  {YELLOW}  Install Tor and start: tor --SOCKSPort {proxy_port}{RESET}")
        report["tor_available"] = False
    else:
        print(f"  {GREEN}Tor SOCKS5 proxy is running{RESET}")
        report["tor_available"] = True

    # 2. Direct RPC test
    print(f"\n{GREEN}[2/5] Direct RPC connection ...{RESET}")
    direct_result, direct_latency = rpc_via_direct(args.rpc_host, args.rpc_port, "getblockcount")
    direct_ok = "error" not in direct_result or "result" in direct_result
    report["tests"].append({
        "test": "direct_rpc",
        "success": direct_ok,
        "latency_ms": round(direct_latency, 2),
    })
    color = GREEN if direct_ok else RED
    print(f"  {color}{'OK' if direct_ok else 'FAIL'} — {direct_latency:.1f}ms{RESET}")

    # 3. Direct P2P test
    print(f"\n{GREEN}[3/5] Direct P2P connection ...{RESET}")
    p2p_ok, p2p_latency = tcp_connect_test(args.rpc_host, P2P_PORT)
    report["tests"].append({
        "test": "direct_p2p",
        "success": p2p_ok,
        "latency_ms": round(p2p_latency, 2),
    })
    color = GREEN if p2p_ok else RED
    print(f"  {color}{'OK' if p2p_ok else 'FAIL'} — {p2p_latency:.1f}ms{RESET}")

    if tor_available:
        # 4. Tor RPC test
        print(f"\n{GREEN}[4/5] Tor-routed RPC connection ...{RESET}")
        tor_result, tor_latency = rpc_via_tor(
            proxy_host, proxy_port, args.rpc_host, args.rpc_port, "getblockcount"
        )
        tor_ok = "error" not in tor_result or "result" in tor_result
        report["tests"].append({
            "test": "tor_rpc",
            "success": tor_ok,
            "latency_ms": round(tor_latency, 2),
        })
        color = GREEN if tor_ok else RED
        print(f"  {color}{'OK' if tor_ok else 'FAIL'} — {tor_latency:.1f}ms{RESET}")

        # 5. Tor P2P test
        print(f"\n{GREEN}[5/5] Tor-routed P2P connection ...{RESET}")
        tor_p2p_ok, tor_p2p_latency = tcp_connect_test(
            args.rpc_host, P2P_PORT, proxy_host, proxy_port
        )
        report["tests"].append({
            "test": "tor_p2p",
            "success": tor_p2p_ok,
            "latency_ms": round(tor_p2p_latency, 2),
        })
        color = GREEN if tor_p2p_ok else RED
        print(f"  {color}{'OK' if tor_p2p_ok else 'FAIL'} — {tor_p2p_latency:.1f}ms{RESET}")

        # Latency comparison
        if direct_ok and tor_ok:
            overhead = tor_latency - direct_latency
            report["latency_overhead_ms"] = round(overhead, 2)
            print(f"\n  {CYAN}Tor overhead: {overhead:.1f}ms{RESET}")
    else:
        print(f"\n{YELLOW}[4/5] SKIPPED — Tor not available{RESET}")
        print(f"{YELLOW}[5/5] SKIPPED — Tor not available{RESET}")

    # Verdict
    all_direct_pass = all(t["success"] for t in report["tests"]
                          if not t["test"].startswith("tor"))
    report["verdict"] = "PASS" if all_direct_pass else "FAIL"
    if tor_available:
        all_tor_pass = all(t["success"] for t in report["tests"]
                           if t["test"].startswith("tor"))
        report["tor_verdict"] = "PASS" if all_tor_pass else "FAIL"

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" RESULTS")
        print(f"{'='*60}{RESET}")
        vc = GREEN if report["verdict"] == "PASS" else RED
        print(f"  Direct: {vc}{report['verdict']}{RESET}")
        if "tor_verdict" in report:
            tc = GREEN if report["tor_verdict"] == "PASS" else RED
            print(f"  Tor:    {tc}{report['tor_verdict']}{RESET}")

    sys.exit(0 if report["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
