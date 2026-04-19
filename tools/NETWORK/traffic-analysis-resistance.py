#!/usr/bin/env python3
"""OmniBus BlockChainCore — Traffic Analysis Resistance Test.

Connects to P2P port 9000 directly.  Sends 100 messages at random intervals.
Records exact send/receive timestamps.  Calculates:
  - Timing correlation coefficient
  - Packet size variance
Reports if messages are padded (good) or have predictable sizes (bad for privacy).
Heuristic analysis only.
"""

import argparse
import json
import math
import os
import random
import secrets
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
P2P_PORT = 9000
RPC_PORT = 8332
WS_PORT = 8334
SHARDS = 4
SUB_BLOCKS = 10
OMNIBUS_MAGIC = b"\x4f\x4d\x4e\x49"  # "OMNI"


def build_p2p_message(msg_type: str, payload_size: int) -> bytes:
    """Build an OmniBus-format P2P message."""
    magic = OMNIBUS_MAGIC
    command = msg_type.encode().ljust(12, b"\x00")[:12]
    payload = secrets.token_bytes(payload_size)
    length = struct.pack("<I", len(payload))
    # Fake checksum (first 4 bytes of double-SHA256)
    import hashlib
    checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    return magic + command + length + checksum + payload


def pearson_correlation(x: list, y: list) -> float:
    """Compute Pearson correlation coefficient."""
    n = len(x)
    if n < 2:
        return 0.0

    mean_x = sum(x) / n
    mean_y = sum(y) / n

    cov = sum((x[i] - mean_x) * (y[i] - mean_y) for i in range(n))
    std_x = math.sqrt(sum((xi - mean_x) ** 2 for xi in x))
    std_y = math.sqrt(sum((yi - mean_y) ** 2 for yi in y))

    if std_x == 0 or std_y == 0:
        return 0.0

    return cov / (std_x * std_y)


def coefficient_of_variation(values: list) -> float:
    """CV = std_dev / mean. High CV = high variance (good for privacy)."""
    if not values:
        return 0.0
    mean = sum(values) / len(values)
    if mean == 0:
        return 0.0
    variance = sum((v - mean) ** 2 for v in values) / len(values)
    return math.sqrt(variance) / mean


def analyze_padding(sizes: list) -> dict:
    """Analyze if message sizes show padding patterns."""
    if not sizes:
        return {"padded": False, "note": "no data"}

    unique_sizes = set(sizes)
    # Good padding: few distinct sizes (messages padded to fixed blocks)
    # Bad: many distinct sizes correlating with content

    # Check if sizes are multiples of common block sizes
    block_sizes = [16, 32, 64, 128, 256, 512, 1024]
    alignment_scores = {}
    for bs in block_sizes:
        aligned = sum(1 for s in sizes if s % bs == 0)
        alignment_scores[bs] = aligned / len(sizes)

    best_alignment = max(alignment_scores.items(), key=lambda x: x[1])

    is_padded = best_alignment[1] > 0.8 or len(unique_sizes) <= 5

    return {
        "unique_sizes": len(unique_sizes),
        "total_messages": len(sizes),
        "size_min": min(sizes),
        "size_max": max(sizes),
        "size_mean": round(sum(sizes) / len(sizes), 1),
        "cv": round(coefficient_of_variation(sizes), 4),
        "best_alignment_block": best_alignment[0],
        "alignment_ratio": round(best_alignment[1], 3),
        "padded": is_padded,
        "privacy_assessment": "GOOD — sizes appear padded" if is_padded
                              else "WEAK — predictable size distribution",
    }


def run_traffic_analysis(host: str, port: int, message_count: int) -> dict:
    """Send messages and record timing/size data."""
    send_times = []
    recv_times = []
    send_sizes = []
    recv_sizes = []
    errors = 0

    # Message types to send
    msg_types = ["ping", "getaddr", "inv", "getdata", "getblocks", "version"]

    for i in range(message_count):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(5)
            sock.connect((host, port))

            # Random message
            msg_type = random.choice(msg_types)
            payload_size = random.randint(20, 500)
            message = build_p2p_message(msg_type, payload_size)

            # Random delay (0-200ms)
            delay = random.uniform(0.001, 0.200)
            time.sleep(delay)

            # Send
            t_send = time.time()
            sock.sendall(message)
            send_times.append(t_send)
            send_sizes.append(len(message))

            # Receive (with timeout)
            try:
                sock.settimeout(2)
                response = sock.recv(4096)
                t_recv = time.time()
                recv_times.append(t_recv)
                recv_sizes.append(len(response))
            except socket.timeout:
                recv_times.append(time.time())
                recv_sizes.append(0)

            sock.close()

        except Exception:
            errors += 1
            send_times.append(time.time())
            recv_times.append(time.time())
            send_sizes.append(0)
            recv_sizes.append(0)

        if (i + 1) % 25 == 0:
            print(f"  {CYAN}Sent {i+1}/{message_count} messages ...{RESET}")

    return {
        "send_times": send_times,
        "recv_times": recv_times,
        "send_sizes": send_sizes,
        "recv_sizes": recv_sizes,
        "errors": errors,
    }


def main():
    parser = argparse.ArgumentParser(
        description="OmniBus BlockChainCore — Traffic Analysis Resistance Test"
    )
    parser.add_argument("--host", default="127.0.0.1", help="Node host")
    parser.add_argument("--port", type=int, default=P2P_PORT,
                        help=f"P2P port (default: {P2P_PORT})")
    parser.add_argument("--messages", "-n", type=int, default=100,
                        help="Messages to send (default: 100)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    print(f"{CYAN}{BOLD}{'='*60}")
    print(f" OmniBus BlockChainCore — Traffic Analysis Resistance")
    print(f" Target: {args.host}:{args.port}")
    print(f" Messages: {args.messages}")
    print(f" Shards: {SHARDS} | Sub-blocks: {SUB_BLOCKS}")
    print(f"{'='*60}{RESET}\n")

    # Check connectivity
    print(f"{GREEN}[PREFLIGHT] Checking P2P port ...{RESET}")
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((args.host, args.port))
        sock.close()
        print(f"  {GREEN}Connected{RESET}")
    except Exception:
        print(f"  {RED}Cannot connect to {args.host}:{args.port}{RESET}")
        if not args.json:
            sys.exit(1)

    # Run analysis
    print(f"\n{GREEN}[ANALYSIS] Sending {args.messages} messages ...{RESET}")
    data = run_traffic_analysis(args.host, args.port, args.messages)

    # Compute timing analysis
    print(f"\n{GREEN}[COMPUTING] Analyzing traffic patterns ...{RESET}")

    # Inter-message timing
    send_intervals = [data["send_times"][i+1] - data["send_times"][i]
                      for i in range(len(data["send_times"]) - 1)]
    recv_intervals = [data["recv_times"][i+1] - data["recv_times"][i]
                      for i in range(len(data["recv_times"]) - 1)
                      if data["recv_sizes"][i] > 0 and data["recv_sizes"][i+1] > 0]

    # Timing correlation
    min_len = min(len(send_intervals), len(recv_intervals))
    if min_len > 2:
        timing_corr = pearson_correlation(send_intervals[:min_len],
                                          recv_intervals[:min_len])
    else:
        timing_corr = 0.0

    # Size analysis
    non_zero_recv = [s for s in data["recv_sizes"] if s > 0]
    padding_analysis = analyze_padding(non_zero_recv)
    send_padding = analyze_padding([s for s in data["send_sizes"] if s > 0])

    # Timing predictability
    timing_cv = coefficient_of_variation(send_intervals) if send_intervals else 0

    report = {
        "target": f"{args.host}:{args.port}",
        "messages_sent": args.messages,
        "messages_received": len(non_zero_recv),
        "errors": data["errors"],
        "timing": {
            "correlation_coefficient": round(timing_corr, 4),
            "timing_cv": round(timing_cv, 4),
            "assessment": (
                "GOOD — low timing correlation"
                if abs(timing_corr) < 0.3
                else "WEAK — high timing correlation (predictable)"
            ),
        },
        "send_sizes": send_padding,
        "recv_sizes": padding_analysis,
        "overall_privacy": "GOOD" if (abs(timing_corr) < 0.3 and
                                       padding_analysis.get("padded", False))
                           else "NEEDS IMPROVEMENT",
    }

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"\n{CYAN}{'='*60}")
        print(f" TRAFFIC ANALYSIS RESULTS")
        print(f"{'='*60}{RESET}")
        print(f"  Messages sent:     {report['messages_sent']}")
        print(f"  Messages received: {report['messages_received']}")
        print(f"  Errors:            {report['errors']}")
        print(f"\n  {BOLD}Timing Analysis:{RESET}")
        tc = abs(timing_corr)
        color = GREEN if tc < 0.3 else (YELLOW if tc < 0.6 else RED)
        print(f"    Correlation:     {color}{timing_corr:.4f}{RESET}")
        print(f"    CV:              {timing_cv:.4f}")
        print(f"    Assessment:      {report['timing']['assessment']}")
        print(f"\n  {BOLD}Size Analysis (responses):{RESET}")
        pc = GREEN if padding_analysis.get("padded") else RED
        print(f"    Unique sizes:    {padding_analysis.get('unique_sizes', 0)}")
        print(f"    Size range:      {padding_analysis.get('size_min', 0)}-{padding_analysis.get('size_max', 0)}")
        print(f"    Padded:          {pc}{padding_analysis.get('padded', False)}{RESET}")
        print(f"    Assessment:      {padding_analysis.get('privacy_assessment', 'N/A')}")
        oc = GREEN if report["overall_privacy"] == "GOOD" else YELLOW
        print(f"\n  Overall:           {oc}{BOLD}{report['overall_privacy']}{RESET}")

    sys.exit(0 if report["overall_privacy"] == "GOOD" else 1)


if __name__ == "__main__":
    main()
