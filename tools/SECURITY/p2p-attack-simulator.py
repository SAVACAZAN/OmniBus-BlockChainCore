#!/usr/bin/env python3
"""
OmniBus Blockchain Core — P2P Attack Simulator

Simulates:
  - Eclipse attack (fake peers monopolize connections)
  - Sybil attack (many fake identities)
  - Transaction replay attack

Outputs: attack-report.json
"""

import argparse
import json
import random
import sys
import time
from typing import Any, Dict, List

# ANSI colors
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


class P2PAttackSimulator:
    def __init__(self, num_honest: int = 8, num_malicious: int = 4):
        self.num_honest = num_honest
        self.num_malicious = num_malicious
        self.results: Dict[str, Any] = {"attacks": []}

    def _log(self, attack: str, result: str, details: str, severity: str = "INFO") -> None:
        entry = {"attack": attack, "result": result, "details": details, "severity": severity}
        self.results["attacks"].append(entry)
        color = GREEN if result == "DEFENDED" else RED if result == "VULNERABLE" else YELLOW
        cprint(color, f"[{attack}] {result}: {details}")

    def simulate_eclipse(self) -> None:
        """Simulate eclipse attack: malicious peers try to surround target."""
        cprint(YELLOW, "\n--- Eclipse Attack Simulation ---")
        target = "node-victim"
        # Victim connects to 8 outbound peers
        outbound = [f"peer-{i}" for i in range(self.num_honest)]
        malicious = [f"malicious-{i}" for i in range(self.num_malicious)]
        # Replace 6 of 8 honest with malicious
        compromised = outbound[:2] + malicious[:6]
        eclipse_rate = len(malicious) / (len(outbound) + len(malicious))
        if eclipse_rate > 0.5:
            self._log("Eclipse", "VULNERABLE",
                      f"Target {target} surrounded: {len(malicious)}/{len(compromised)} peers malicious", "HIGH")
        else:
            self._log("Eclipse", "DEFENDED",
                      f"Target {target} retains honest majority", "LOW")
        self.results["eclipse_rate"] = eclipse_rate

    def simulate_sybil(self) -> None:
        """Simulate Sybil attack: many identities from few IPs."""
        cprint(YELLOW, "\n--- Sybil Attack Simulation ---")
        real_identities = self.num_honest
        fake_identities = self.num_malicious * 10  # one host spawns many IDs
        sybil_ratio = fake_identities / (real_identities + fake_identities)
        if sybil_ratio > 0.6:
            self._log("Sybil", "VULNERABLE",
                      f"Fake IDs dominate: {fake_identities} fake vs {real_identities} real", "HIGH")
        else:
            self._log("Sybil", "DEFENDED",
                      f"Sybil ratio {sybil_ratio:.2%} within tolerance", "LOW")
        self.results["sybil_ratio"] = sybil_ratio

    def simulate_replay(self) -> None:
        """Simulate transaction replay."""
        cprint(YELLOW, "\n--- Replay Attack Simulation ---")
        tx = {"txid": "a" * 64, "inputs": [{"prevout": "b" * 64, "vout": 0}], "outputs": [{"addr": "om1xyz", "value": 1000}]}
        # Without replay protection (no unique nonce/chain-id per tx)
        replay_protection = False  # heuristic: real chain should have it
        if not replay_protection:
            self._log("Replay", "VULNERABLE",
                      "Transaction lacks explicit replay protection nonce", "MEDIUM")
        else:
            self._log("Replay", "DEFENDED", "Transaction includes chain-specific nonce", "LOW")
        self.results["replay_protection"] = replay_protection

    def run(self) -> Dict[str, Any]:
        cprint(GREEN, "=== OmniBus P2P Attack Simulator ===")
        self.simulate_eclipse()
        self.simulate_sybil()
        self.simulate_replay()
        vulnerable = sum(1 for a in self.results["attacks"] if a["result"] == "VULNERABLE")
        defended = sum(1 for a in self.results["attacks"] if a["result"] == "DEFENDED")
        self.results["summary"] = f"Vulnerable: {vulnerable}, Defended: {defended}"
        return self.results


def main() -> int:
    parser = argparse.ArgumentParser(description="Simulate P2P attacks against OmniBus network model")
    parser.add_argument("--honest", type=int, default=8, help="Number of honest peers")
    parser.add_argument("--malicious", type=int, default=4, help="Number of malicious peers")
    parser.add_argument("--output", default="attack-report.json", help="Output JSON report path")
    args = parser.parse_args()

    sim = P2PAttackSimulator(num_honest=args.honest, num_malicious=args.malicious)
    report = sim.run()

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    cprint(GREEN, f"\nReport written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
