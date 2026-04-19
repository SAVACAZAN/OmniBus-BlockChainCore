#!/usr/bin/env python3
"""OmniBus BlockChainCore — P2P Connection Flood Test.

Opens 200 TCP connections to P2P port 9000 simultaneously.
For each: sends partial handshake (magic bytes), holds connection open.
Monitors: how many the node accepts, when it starts rejecting, if it crashes.
Uses socket + threading.
"""

import argparse
import json
import socket
import struct
import sys
import threading
import time

# ---------------------------------------------------------------------------
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"

# OmniBus BlockChainCore P2P
P2P_PORT = 9000
RPC_PORT = 8332
WS_PORT = 8334
SHARDS = 4
# OmniBus magic bytes (Bitcoin-style network magic)
OMNIBUS_MAGIC = b"\x4f\x4d\x4e\x49"  # "OMNI"
NODE_BINARY = "zig-out/bin/omnibus-node.exe"


class ConnectionTracker:
    def __init__(self):
        self.lock = threading.Lock()
        self.connected = 0
        self.rejected = 0
        self.errors = 0
        self.timeouts = 0
        self.sockets = []
        self.connect_times = []
        self.first_reject_at = None

    def record_connect(self, sock, connect_time_ms: float):
        with self.lock:
            self.connected += 1
            self.sockets.append(sock)
            self.connect_times.append(connect_time_ms)

    def record_reject(self):
        with self.lock:
            self.rejected += 1
            if self.first_reject_at is None:
                self.first_reject_at = self.connected

    def record_error(self):
        with self.lock:
            self.errors += 1

    def record_timeout(self):
        with self.lock:
            self.timeouts += 1

    def close_all(self):
        with self.lock:
            for sock in self.sockets:
                try:
                    sock.close()
                except Exception:
                    pass
            self.sockets.clear()


def build_handshake_partial() -> bytes:
    """Build a partial OmniBus P2P handshake message.

    Structure (Bitcoin-inspired):
        4 bytes: magic (OMNI)
        12 bytes: command (version\x00...)
        4 bytes: payload length
        4 bytes: checksum (first 4 bytes of double-SHA256)
        ... partial payload (intentionally incomplete)
    """
    magic = OMNIBUS_MAGIC
    command = b"version\x00\x00\x00\x00\x00"  # 12 bytes
    # Claim large payload but only send partial
    payload_len = struct.pack("<I", 1024)
    checksum = b"\x00\x00\x00\x00"  # fake checksum

    # Send just the header + a few bytes of "payload"
    partial_payload = b"\x00" * 20  # Only 20 of claimed 1024 bytes

    return magic + command + payload_len + checksum + partial_payload


def connection_worker(host: str, port: int, conn_id: int,
                      tracker: ConnectionTracker, hold_time: float):
    """Open one connection, send partial handshake, hold open."""
    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)

        t0 = time.time()
        sock.connect((host, port))
        connect_ms = (time.time() - t0) * 1000

        # Send partial handshake
        handshake = build_handshake_partial()
        sock.sendall(handshake)

        tracker.record_connect(sock, connect_ms)

        # Hold connection open
        sock.settimeout(hold_time + 1)
        try:
            # Try to read response (node might send version back)
            data = sock.recv(1024)
        except socket.timeout:
            pass

        # Keep alive
        time.sleep(hold_time)

    except ConnectionRefusedError:
        tracker.record_reject()
    except socket.timeout:
        tracker.record_timeout()
    except OSError as e:
        if "refused" in str(e).lower() or "reset" in str(e).lower():
            tracker.record_reject()
        else:
            tracker.record_error()
    except Exception:
        tracker.record_error()
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass


def check_node_alive(host: str, port: int) -> bool:
    """Quick TCP connect to verify node is accepting connections."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((host, port))
        sock.close()
        return True
    except Exception:
        return False


def check_rpc_alive(host: str) -> bool:
    """Check if RPC port is responding."""
    import http.client
    try:
        conn = http.client.HTTPConnection(host, RPC_PORT, timeout=3)
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "getblockcount"})
        conn.request("POST", "/", payload, {"Content-Type": "application/json"})
        resp = conn.getresponse()
        conn.close()
        return resp.status == 200
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — P2P Connection Flood Test"
    )
    parser.add_argument("--host", default="127.0.0.1", help="Node host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=P2P_PORT,
                        help=f"P2P port (default: {P2P_PORT})")
    parser.add_argument("--connections", "-n", type=int, default=200,
                        help="Number of simultaneous connections (default: 200)")
    parser.add_argument("--hold-time", type=float, default=10.0,
                        help="Seconds to hold each connection (default: 10)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — P2P Connection Flood")
    print(f" Target: {args.host}:{args.port}")
    print(f" Connections: {args.connections}")
    print(f" Hold time: {args.hold_time}s")
    print(f" Shards: {SHARDS} | RPC: {RPC_PORT} | WS: {WS_PORT}")
    print(f"{'='*60}{RESET}\n")

    # Pre-check
    print(f"{GREEN}[PREFLIGHT] Checking P2P port ...{RESET}")
    alive_before = check_node_alive(args.host, args.port)
    if not alive_before:
        print(f"{RED}[ERROR] Cannot connect to {args.host}:{args.port}{RESET}")
        print(f"{YELLOW}  Start: {NODE_BINARY} --mode seed --port {args.port}{RESET}")
        if not args.json:
            sys.exit(1)

    rpc_before = check_rpc_alive(args.host)
    print(f"  P2P: {'UP' if alive_before else 'DOWN'} | RPC: {'UP' if rpc_before else 'DOWN'}")

    tracker = ConnectionTracker()
    t_start = time.time()

    # Launch all connections
    print(f"\n{GREEN}[FLOOD] Launching {args.connections} connections ...{RESET}")
    threads = []
    for i in range(args.connections):
        t = threading.Thread(
            target=connection_worker,
            args=(args.host, args.port, i, tracker, args.hold_time),
            daemon=True,
        )
        threads.append(t)

    # Stagger launch slightly to avoid local port exhaustion
    batch_size = 50
    for batch_start in range(0, len(threads), batch_size):
        batch = threads[batch_start:batch_start + batch_size]
        for t in batch:
            t.start()

        # Quick status
        time.sleep(0.5)
        print(f"  {CYAN}Launched {min(batch_start + batch_size, len(threads))}/{args.connections} "
              f"| Connected: {tracker.connected} | Rejected: {tracker.rejected}{RESET}")

    # Wait for all threads
    for t in threads:
        t.join(timeout=args.hold_time + 10)

    elapsed = time.time() - t_start

    # Post-check
    print(f"\n{GREEN}[POST-CHECK] Verifying node health ...{RESET}")
    time.sleep(1)
    alive_after = check_node_alive(args.host, args.port)
    rpc_after = check_rpc_alive(args.host)

    # Clean up
    tracker.close_all()

    # Report
    report = {
        "target": f"{args.host}:{args.port}",
        "connections_attempted": args.connections,
        "connections_accepted": tracker.connected,
        "connections_rejected": tracker.rejected,
        "connection_errors": tracker.errors,
        "connection_timeouts": tracker.timeouts,
        "first_reject_at_connection": tracker.first_reject_at,
        "avg_connect_ms": round(sum(tracker.connect_times) / max(len(tracker.connect_times), 1), 2),
        "node_alive_before": alive_before,
        "node_alive_after": alive_after,
        "rpc_alive_before": rpc_before,
        "rpc_alive_after": rpc_after,
        "node_crashed": alive_before and not alive_after,
        "elapsed_seconds": round(elapsed, 2),
        "verdict": "PASS" if alive_after else "FAIL — NODE CRASHED",
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" RESULTS")
        print(f"{'='*60}{RESET}")
        print(f"  Attempted:      {report['connections_attempted']}")
        print(f"  Accepted:       {GREEN}{report['connections_accepted']}{RESET}")
        print(f"  Rejected:       {YELLOW}{report['connections_rejected']}{RESET}")
        print(f"  Errors:         {RED}{report['connection_errors']}{RESET}")
        print(f"  Timeouts:       {YELLOW}{report['connection_timeouts']}{RESET}")

        if report["first_reject_at_connection"] is not None:
            print(f"  First reject:   at connection #{report['first_reject_at_connection']}")

        print(f"  Avg connect:    {report['avg_connect_ms']}ms")
        print(f"  Node alive:     {'before' if alive_before else 'DEAD before'} -> "
              f"{'after' if alive_after else 'CRASHED'}")

        crashed = report["node_crashed"]
        vc = RED if crashed else GREEN
        verdict = report["verdict"]
        print(f"\n  Verdict:        {vc}{BOLD}{verdict}{RESET}")

    sys.exit(0 if not report["node_crashed"] else 1)


if __name__ == "__main__":
    main()
