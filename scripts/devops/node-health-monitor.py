#!/usr/bin/env python3
"""
OmniBus Blockchain Core — Node Health Monitor Daemon

Every 30s pings RPC port with getblockcount (JSON-RPC 2.0).
Alerts if node appears stuck (same block height for 3+ consecutive checks).
Takes --host and --port args.
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime

# ANSI colors
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"


def timestamp() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def rpc_call(url: str, method: str, params: list = None, timeout: int = 10) -> dict:
    """Make a JSON-RPC 2.0 call. Uses only stdlib (no requests dependency)."""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params or [],
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


class HealthMonitor:
    def __init__(self, host: str, port: int, interval: int = 30, stuck_threshold: int = 3):
        self.url = f"http://{host}:{port}"
        self.interval = interval
        self.stuck_threshold = stuck_threshold

        self.last_block_height: int | None = None
        self.same_height_count: int = 0
        self.consecutive_failures: int = 0
        self.total_checks: int = 0
        self.total_ok: int = 0

    def check_health(self) -> dict:
        """Returns {"ok": bool, "block_height": int|None, "error": str|None}"""
        try:
            result = rpc_call(self.url, "getblockcount")
            if "result" in result:
                return {"ok": True, "block_height": result["result"], "error": None}
            elif "error" in result:
                return {"ok": False, "block_height": None, "error": result["error"].get("message", "RPC error")}
            else:
                return {"ok": False, "block_height": None, "error": "Unexpected response"}
        except urllib.error.URLError as e:
            return {"ok": False, "block_height": None, "error": f"Connection failed: {e.reason}"}
        except Exception as e:
            return {"ok": False, "block_height": None, "error": str(e)}

    def run(self) -> None:
        print(f"{BOLD}{CYAN}=== OmniBus Node Health Monitor ==={RESET}")
        print(f"{DIM}Target:    {self.url}{RESET}")
        print(f"{DIM}Interval:  {self.interval}s{RESET}")
        print(f"{DIM}Stuck threshold: {self.stuck_threshold} checks{RESET}")
        print()

        while True:
            self.total_checks += 1
            status = self.check_health()

            if status["ok"]:
                self.consecutive_failures = 0
                self.total_ok += 1
                height = status["block_height"]

                # Check if block height is advancing
                if self.last_block_height is not None and height == self.last_block_height:
                    self.same_height_count += 1
                else:
                    self.same_height_count = 0

                self.last_block_height = height

                if self.same_height_count >= self.stuck_threshold:
                    print(
                        f"{RED}[{timestamp()}] ALERT: Node stuck at block {height} "
                        f"for {self.same_height_count} consecutive checks!{RESET}"
                    )
                else:
                    advancing = ""
                    if self.same_height_count > 0:
                        advancing = f" {YELLOW}(unchanged x{self.same_height_count}){RESET}"
                    print(
                        f"{GREEN}[{timestamp()}] OK{RESET} "
                        f"block={height}{advancing} "
                        f"{DIM}uptime={self.total_ok}/{self.total_checks}{RESET}"
                    )
            else:
                self.consecutive_failures += 1
                self.same_height_count = 0  # reset since we can't check height
                print(
                    f"{RED}[{timestamp()}] FAIL ({self.consecutive_failures}x){RESET} "
                    f"{status['error']}"
                )

                if self.consecutive_failures >= self.stuck_threshold:
                    print(
                        f"{RED}{BOLD}[{timestamp()}] CRITICAL: Node unreachable "
                        f"for {self.consecutive_failures} consecutive checks!{RESET}"
                    )

            try:
                time.sleep(self.interval)
            except KeyboardInterrupt:
                break

        print(f"\n{YELLOW}Monitor stopped. Total checks: {self.total_checks}, "
              f"OK: {self.total_ok}, Failed: {self.total_checks - self.total_ok}{RESET}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="OmniBus Node Health Monitor — pings RPC and alerts if stuck"
    )
    parser.add_argument("--host", default="127.0.0.1", help="RPC host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8332, help="RPC port (default: 8332)")
    parser.add_argument("--interval", type=int, default=30, help="Check interval in seconds (default: 30)")
    parser.add_argument("--stuck-threshold", type=int, default=3,
                        help="Number of same-height checks before alerting (default: 3)")
    args = parser.parse_args()

    monitor = HealthMonitor(
        host=args.host,
        port=args.port,
        interval=args.interval,
        stuck_threshold=args.stuck_threshold,
    )
    try:
        monitor.run()
    except KeyboardInterrupt:
        print(f"\n{YELLOW}Interrupted.{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
