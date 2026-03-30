#!/usr/bin/env python3
"""
metrics_exporter.py - Prometheus Metrics Exporter v1.0

Exportă metrici blockchain pentru Prometheus/Grafana:
  - Block height, timestamp, difficulty
  - Mempool size, transaction count
  - Peer connections
  - Mining statistics
  - Memory and CPU usage

Usage:
  python tools/MONITORING/metrics_exporter.py           # Print metrics
  python tools/MONITORING/metrics_exporter.py --http    # Start HTTP server
  python tools/MONITORING/metrics_exporter.py --port 9090
"""

import sys
import time
import json
import argparse
import http.server
import socketserver
from pathlib import Path
from dataclasses import dataclass
from typing import Dict, Optional
from datetime import datetime
import urllib.request

RPC_HOST = "127.0.0.1"
RPC_PORT = 8332

@dataclass
class BlockchainMetrics:
    block_height: int = 0
    mempool_size: int = 0
    total_transactions: int = 0
    active_miners: int = 0
    registered_miners: int = 0
    total_supply: float = 0.0
    timestamp: float = 0.0

def rpc_call(method: str, params: list = None) -> Optional[dict]:
    """Make RPC call to blockchain node."""
    try:
        req = urllib.request.Request(
            f"http://{RPC_HOST}:{RPC_PORT}",
            data=json.dumps({
                "jsonrpc": "2.0",
                "method": method,
                "params": params or [],
                "id": 1
            }).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode())
            return data.get("result")
    except Exception as e:
        return None

def collect_metrics() -> BlockchainMetrics:
    """Collect metrics from blockchain node."""
    metrics = BlockchainMetrics()
    metrics.timestamp = time.time()
    
    # Get pool stats
    pool_stats = rpc_call("getpoolstats")
    if pool_stats:
        metrics.block_height = pool_stats.get("blockHeight", 0)
        metrics.registered_miners = pool_stats.get("registeredMiners", 0)
        metrics.total_supply = pool_stats.get("totalRewards", 0.0)
    
    # Get mempool
    mempool = rpc_call("getmempoolsize")
    if mempool is not None:
        metrics.mempool_size = mempool
    
    # Get miner connections
    connections = rpc_call("getminerconnections")
    if connections:
        metrics.active_miners = connections.get("active", 0)
    
    # Get transaction count
    tx_count = rpc_call("gettransactioncount")
    if tx_count is not None:
        metrics.total_transactions = tx_count
    
    return metrics

def format_prometheus(metrics: BlockchainMetrics) -> str:
    """Format metrics in Prometheus exposition format."""
    lines = [
        "# HELP omnibus_block_height Current block height",
        "# TYPE omnibus_block_height gauge",
        f"omnibus_block_height {metrics.block_height}",
        "",
        "# HELP omnibus_mempool_size Number of transactions in mempool",
        "# TYPE omnibus_mempool_size gauge",
        f"omnibus_mempool_size {metrics.mempool_size}",
        "",
        "# HELP omnibus_active_miners Number of active miners",
        "# TYPE omnibus_active_miners gauge",
        f"omnibus_active_miners {metrics.active_miners}",
        "",
        "# HELP omnibus_registered_miners Total registered miners",
        "# TYPE omnibus_registered_miners gauge",
        f"omnibus_registered_miners {metrics.registered_miners}",
        "",
        "# HELP omnibus_total_transactions Total transactions",
        "# TYPE omnibus_total_transactions counter",
        f"omnibus_total_transactions {metrics.total_transactions}",
        "",
        "# HELP omnibus_total_supply Total OMNI supply",
        "# TYPE omnibus_total_supply gauge",
        f"omnibus_total_supply {metrics.total_supply}",
    ]
    return "\n".join(lines)

class MetricsHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics."""
    
    def do_GET(self):
        if self.path == "/metrics":
            metrics = collect_metrics()
            data = format_prometheus(metrics).encode()
            
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        pass  # Suppress logs

def start_server(port: int):
    """Start HTTP server for metrics."""
    with socketserver.TCPServer(("", port), MetricsHandler) as httpd:
        print(f"\nMetrics server started on http://localhost:{port}/metrics")
        print("Press Ctrl+C to stop\n")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopping server...")

def main():
    parser = argparse.ArgumentParser(description="Metrics Exporter")
    parser.add_argument("--http", action="store_true", help="Start HTTP server")
    parser.add_argument("--port", type=int, default=9090, help="HTTP port")
    parser.add_argument("--once", action="store_true", help="Print once and exit")
    args = parser.parse_args()
    
    if args.http:
        start_server(args.port)
    else:
        metrics = collect_metrics()
        print("\n" + "=" * 60)
        print("  OmniBus Blockchain Metrics")
        print("=" * 60)
        print(f"\n  Block Height:       {metrics.block_height}")
        print(f"  Mempool Size:       {metrics.mempool_size}")
        print(f"  Active Miners:      {metrics.active_miners}")
        print(f"  Registered Miners:  {metrics.registered_miners}")
        print(f"  Total Transactions: {metrics.total_transactions}")
        print(f"  Total Supply:       {metrics.total_supply:.4f} OMNI")
        print(f"  Timestamp:          {datetime.fromtimestamp(metrics.timestamp)}")
        print("=" * 60 + "\n")
        
        if not args.once:
            print("\nPrometheus format:\n")
            print(format_prometheus(metrics))

if __name__ == "__main__":
    main()
