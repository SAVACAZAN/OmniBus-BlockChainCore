#!/usr/bin/env python3
"""
protocol-fuzzer.py

Fuzz the P2P protocol of a BlockChainCore node over TCP.
Sends malformed messages:
  - oversized payloads
  - invalid headers / magic bytes
  - truncated data
  - random garbage

Detects crashes, hangs, and unexpected responses.

Outputs: fuzz-results.json
"""

import argparse
import json
import os
import random
import socket
import struct
import sys
import time
from datetime import datetime, timezone
from typing import Any

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
RESET = "\033[0m"


def log_info(msg: str) -> None:
    print(f"{CYAN}[INFO]{RESET} {msg}")


def log_pass(msg: str) -> None:
    print(f"{GREEN}[PASS]{RESET} {msg}")


def log_fail(msg: str) -> None:
    print(f"{RED}[FAIL]{RESET} {msg}")


def log_warn(msg: str) -> None:
    print(f"{YELLOW}[WARN]{RESET} {msg}")


# ---------------------------------------------------------------------------
# Message construction helpers
# ---------------------------------------------------------------------------
MAGIC = b"\x4f\x4d\x4e\x49"  # "OMNI"
COMMANDS = [b"version", b"verack", b"ping", b"pong", b"getblocks", b"inv", b"tx", b"block"]


def make_valid_header(command: bytes, payload_len: int) -> bytes:
    """Build a minimal valid P2P header."""
    cmd = command.ljust(12, b"\x00")
    checksum = b"\x00\x00\x00\x00"  # simplified
    return MAGIC + cmd + struct.pack("<I", payload_len) + checksum


def make_message(command: bytes, payload: bytes) -> bytes:
    return make_valid_header(command, len(payload)) + payload


def random_payload(min_size: int = 0, max_size: int = 4096) -> bytes:
    size = random.randint(min_size, max_size)
    return bytes(random.randint(0, 255) for _ in range(size))


# ---------------------------------------------------------------------------
# Fuzz cases
# ---------------------------------------------------------------------------
def fuzz_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []

    # 1. Valid handshake baseline
    cases.append(
        {
            "name": "valid_version",
            "data": make_message(b"version", b"\x7f\x11\x01\x00" + b"\x00" * 80),
            "expect_disconnect": False,
        }
    )

    # 2. Oversized message
    cases.append(
        {
            "name": "oversized_payload",
            "data": make_valid_header(b"version", 0x02000000) + random_payload(1024 * 1024, 1024 * 1024),
            "expect_disconnect": True,
        }
    )

    # 3. Invalid magic bytes
    bad_magic = b"\xDE\xAD\xBE\xEF" + b"version".ljust(12, b"\x00") + struct.pack("<I", 0) + b"\x00" * 4
    cases.append({"name": "bad_magic", "data": bad_magic, "expect_disconnect": True})

    # 4. Truncated header
    cases.append({"name": "truncated_header", "data": MAGIC + b"\x00" * 10, "expect_disconnect": True})

    # 5. Truncated payload (header says 1000, send 10 bytes)
    cases.append(
        {
            "name": "truncated_payload",
            "data": make_valid_header(b"version", 1000) + b"\x00" * 10,
            "expect_disconnect": True,
        }
    )

    # 6. Unknown command
    cases.append(
        {
            "name": "unknown_command",
            "data": make_message(b"\x00evil\x00", b"\x00" * 20),
            "expect_disconnect": False,
        }
    )

    # 7. Null-byte injection in command
    cases.append(
        {
            "name": "null_command",
            "data": make_message(b"\x00\x00\x00\x00\x00\x00\x00\x00", b"\x00" * 4),
            "expect_disconnect": False,
        }
    )

    # 8. Random garbage
    cases.append(
        {
            "name": "random_garbage",
            "data": random_payload(64, 512),
            "expect_disconnect": True,
        }
    )

    # 9. Very small payload
    cases.append(
        {
            "name": "zero_payload_valid_header",
            "data": make_message(b"verack", b""),
            "expect_disconnect": False,
        }
    )

    # 10. Negative-length-like header (uint32 max)
    cases.append(
        {
            "name": "max_uint32_length",
            "data": make_valid_header(b"version", 0xFFFFFFFF) + b"\x00" * 16,
            "expect_disconnect": True,
        }
    )

    # 11. Flood of small messages
    flood = b""
    for _ in range(100):
        flood += make_message(random.choice(COMMANDS), random_payload(8, 64))
    cases.append({"name": "message_flood", "data": flood, "expect_disconnect": False})

    return cases


# ---------------------------------------------------------------------------
# Network interaction
# ---------------------------------------------------------------------------
def send_and_probe(host: str, port: int, data: bytes, timeout: float = 5.0) -> dict[str, Any]:
    result: dict[str, Any] = {
        "connected": False,
        "sent_bytes": len(data),
        "response_bytes": 0,
        "response_hex": "",
        "hang": False,
        "crash_guess": False,
        "elapsed_ms": 0.0,
    }
    start = time.perf_counter()
    sock: socket.socket | None = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        result["connected"] = True
        sock.sendall(data)

        # Try to read response
        try:
            resp = sock.recv(8192)
            result["response_bytes"] = len(resp)
            result["response_hex"] = resp[:256].hex()
        except socket.timeout:
            result["hang"] = True
        except ConnectionResetError:
            result["crash_guess"] = True
    except ConnectionRefusedError:
        result["connected"] = False
    except socket.timeout:
        result["hang"] = True
    except OSError:
        result["crash_guess"] = True
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass
    result["elapsed_ms"] = round((time.perf_counter() - start) * 1000, 2)
    return result


def is_node_alive(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description="Fuzz BlockChainCore P2P protocol.")
    parser.add_argument("--host", default="127.0.0.1", help="Target node host")
    parser.add_argument("--port", type=int, default=9333, help="Target P2P port")
    parser.add_argument("--timeout", type=float, default=5.0, help="Socket timeout")
    parser.add_argument("--output", default="tools/REVERSE/fuzz-results.json", help="Output path")
    parser.add_argument("--cooldown", type=float, default=0.5, help="Seconds between cases")
    args = parser.parse_args()

    if not is_node_alive(args.host, args.port):
        log_warn(f"Node {args.host}:{args.port} is not responding to TCP probe.")
        # Continue anyway — node might accept later

    cases = fuzz_cases()
    log_info(f"Running {len(cases)} fuzz cases against {args.host}:{args.port}")

    results: list[dict[str, Any]] = []
    for case in cases:
        log_info(f"Case: {case['name']} ({case['sent_bytes']} bytes)")
        probe = send_and_probe(args.host, args.port, case["data"], args.timeout)

        # Determine if node is still alive after case
        time.sleep(0.2)
        alive_after = is_node_alive(args.host, args.port, timeout=2.0)

        issue = False
        if probe["crash_guess"] or not alive_after:
            issue = True
            log_fail(f"  Possible crash / disconnect on {case['name']}")
        elif probe["hang"]:
            issue = True
            log_warn(f"  Hang detected on {case['name']}")
        else:
            log_pass(f"  Completed in {probe['elapsed_ms']} ms")

        results.append(
            {
                "name": case["name"],
                "expected_disconnect": case["expect_disconnect"],
                "probe": probe,
                "alive_after": alive_after,
                "issue": issue,
            }
        )
        time.sleep(args.cooldown)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "target": f"{args.host}:{args.port}",
        "cases_run": len(cases),
        "issues_found": sum(1 for r in results if r["issue"]),
        "results": results,
    }

    out_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)

    log_pass(f"Fuzz report written to {out_path}")
    log_info(f"Issues found: {report['issues_found']}")
    return 0 if report["issues_found"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
