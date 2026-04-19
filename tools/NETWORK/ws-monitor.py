#!/usr/bin/env python3
"""
OmniBus Blockchain Core — WebSocket Monitor

Connects to ws://host:8334, logs all events to stdout and optionally a file.
"""

import argparse
import json
import sys
import time
import websocket

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


class WSMonitor:
    def __init__(self, url: str = "ws://127.0.0.1:8334", output: Optional[str] = None):
        self.url = url
        self.output = output
        self.file = None
        self.msg_count = 0

    def on_open(self, ws):
        cprint(GREEN, f"Connected to {self.url}")
        # Subscribe to all channels
        ws.send(json.dumps({"subscribe": ["blocks", "txs", "peers"]}))

    def on_message(self, ws, message):
        self.msg_count += 1
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{ts}] #{self.msg_count} {message}"
        cprint(YELLOW, line)
        if self.file:
            self.file.write(line + "\n")
            self.file.flush()

    def on_error(self, ws, error):
        cprint(RED, f"WS Error: {error}")

    def on_close(self, ws, close_status_code, close_msg):
        cprint(YELLOW, f"Closed: {close_status_code} {close_msg}")

    def run(self) -> None:
        cprint(GREEN, f"=== OmniBus WS Monitor ===")
        if self.output:
            self.file = open(self.output, "a", encoding="utf-8")
        try:
            ws = websocket.WebSocketApp(
                self.url,
                on_open=self.on_open,
                on_message=self.on_message,
                on_error=self.on_error,
                on_close=self.on_close,
            )
            ws.run_forever(ping_interval=30, ping_timeout=10)
        except KeyboardInterrupt:
            cprint(YELLOW, "\nInterrupted by user")
        finally:
            if self.file:
                self.file.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Monitor OmniBus WebSocket events")
    parser.add_argument("--host", default="127.0.0.1", help="WS host")
    parser.add_argument("--port", type=int, default=8334, help="WS port")
    parser.add_argument("--output", help="Append events to file")
    args = parser.parse_args()

    url = f"ws://{args.host}:{args.port}"
    mon = WSMonitor(url=url, output=args.output)
    mon.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
