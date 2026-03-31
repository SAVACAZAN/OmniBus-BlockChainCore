#!/usr/bin/env python3
"""
OmniBus Blockchain - Test Runner
=================================

Rulează teste selective pe grupe și generează rapoarte.
Mult mai rapid decât `zig build test` dacă vrei doar un grup.

Utilizare:
    python test_runner.py              # Toate testele
    python test_runner.py --group crypto    # Doar teste crypto
    python test_runner.py --group chain     # Doar teste chain
    python test_runner.py --file core/p2p.zig  # Teste pentru un fișier
    python test_runner.py --watch           # Watch mode pentru TDD

Autor: OmniBus AI Collective
Versiune: 1.0.0
"""

import os
import sys
import subprocess
import json
import time
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import List, Dict, Optional, Tuple
from collections import defaultdict


@dataclass
class TestResult:
    """Rezultatul rulării unui test."""
    name: str
    passed: bool
    duration_ms: float
    output: str = ""
    error: str = ""


@dataclass
class TestGroup:
    """Un grup de teste."""
    name: str
    description: str
    files: List[str]
    build_step: str


class TestRunner:
    """Rulează testele pentru proiectul OmniBus."""
    
    # Definiția grupurilor de teste (corespund cu build.zig)
    TEST_GROUPS = {
        'crypto': TestGroup(
            name='crypto',
            description='Teste criptografie (secp256k1, BIP32, BLS, etc.)',
            files=[
                'core/secp256k1.zig',
                'core/bip32_wallet.zig',
                'core/ripemd160.zig',
                'core/schnorr.zig',
                'core/multisig.zig',
                'core/bls_signatures.zig',
                'core/peer_scoring.zig',
            ],
            build_step='test-crypto'
        ),
        'chain': TestGroup(
            name='chain',
            description='Teste blockchain (block, mempool, consens, etc.)',
            files=[
                'core/block.zig',
                'core/blockchain.zig',
                'core/genesis.zig',
                'core/mempool.zig',
                'core/consensus.zig',
                'core/finality.zig',
                'core/governance.zig',
            ],
            build_step='test-chain'
        ),
        'net': TestGroup(
            name='net',
            description='Teste rețea (RPC, P2P, sync, etc.)',
            files=[
                'core/rpc_server.zig',
                'core/p2p.zig',
                'core/sync.zig',
                'core/network.zig',
                'core/node_launcher.zig',
            ],
            build_step='test-net'
        ),
        'shard': TestGroup(
            name='shard',
            description='Teste sharding și sub-blocuri',
            files=[
                'core/sub_block.zig',
                'core/shard_config.zig',
                'core/blockchain_v2.zig',
            ],
            build_step='test-shard'
        ),
        'storage': TestGroup(
            name='storage',
            description='Teste storage și codec',
            files=[
                'core/storage.zig',
                'core/binary_codec.zig',
                'core/archive_manager.zig',
                'core/prune_config.zig',
                'core/state_trie.zig',
            ],
            build_step='test-storage'
        ),
        'wallet': TestGroup(
            name='wallet',
            description='Teste wallet (necesită liboqs)',
            files=[
                'core/wallet.zig',
            ],
            build_step='test-wallet'
        ),
        'light': TestGroup(
            name='light',
            description='Teste light client și mining pool',
            files=[
                'core/light_client.zig',
                'core/light_miner.zig',
                'core/mining_pool.zig',
            ],
            build_step='test-light'
        ),
    }
    
    def __init__(self, project_root: Path):
        self.project_root = project_root
        self.results: List[TestResult] = []
        
    def run_build_step(self, step: str, timeout: int = 120) -> TestResult:
        """Rulează un build step de test."""
        start = time.time()
        
        cmd = ['zig', 'build', step, '-Doqs=false']
        
        try:
            result = subprocess.run(
                cmd,
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            
            duration = (time.time() - start) * 1000
            
            # Parse output pentru a găsi numărul de teste
            passed = 0
            failed = 0
            output = result.stdout + result.stderr
            
            for line in output.split('\n'):
                if 'passed' in line.lower():
                    try:
                        # Caută pattern "X passed, Y failed"
                        import re
                        match = re.search(r'(\d+)\s+passed', line, re.IGNORECASE)
                        if match:
                            passed = int(match.group(1))
                        match = re.search(r'(\d+)\s+failed', line, re.IGNORECASE)
                        if match:
                            failed = int(match.group(1))
                    except:
                        pass
            
            success = result.returncode == 0 and failed == 0
            
            return TestResult(
                name=step,
                passed=success,
                duration_ms=duration,
                output=output[-500:] if output else "",
                error=result.stderr[-500:] if result.stderr and not success else ""
            )
            
        except subprocess.TimeoutExpired:
            return TestResult(
                name=step,
                passed=False,
                duration_ms=timeout * 1000,
                error=f"Timeout după {timeout} secunde"
            )
        except FileNotFoundError:
            return TestResult(
                name=step,
                passed=False,
                duration_ms=0,
                error="Zig nu e în PATH"
            )
    
    def run_file_tests(self, filepath: Path, timeout: int = 60) -> TestResult:
        """Rulează testele pentru un singur fișier."""
        start = time.time()
        
        if not filepath.exists():
            return TestResult(
                name=f"test-{filepath.name}",
                passed=False,
                duration_ms=0,
                error=f"Fișierul {filepath} nu există"
            )
        
        cmd = ['zig', 'test', str(filepath), '-Doqs=false']
        
        try:
            result = subprocess.run(
                cmd,
                cwd=self.project_root,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            
            duration = (time.time() - start) * 1000
            
            return TestResult(
                name=f"test-{filepath.name}",
                passed=result.returncode == 0,
                duration_ms=duration,
                output=result.stdout[-300:] if result.stdout else "",
                error=result.stderr[-300:] if result.stderr else ""
            )
            
        except subprocess.TimeoutExpired:
            return TestResult(
                name=f"test-{filepath.name}",
                passed=False,
                duration_ms=timeout * 1000,
                error=f"Timeout după {timeout} secunde"
            )
    
    def run_group(self, group_name: str) -> TestResult:
        """Rulează un grup de teste."""
        if group_name not in self.TEST_GROUPS:
            return TestResult(
                name=group_name,
                passed=False,
                duration_ms=0,
                error=f"Grup necunoscut: {group_name}. Disponibili: {', '.join(self.TEST_GROUPS.keys())}"
            )
        
        group = self.TEST_GROUPS[group_name]
        result = self.run_build_step(group.build_step)
        result.name = f"{group.name}: {group.description}"
        return result
    
    def run_all(self) -> List[TestResult]:
        """Rulează toate grupurile de teste."""
        print("  [INFO] Rulează toate testele... (poate dura câteva minute)\n")
        
        for group_name in self.TEST_GROUPS:
            result = self.run_group(group_name)
            self.results.append(result)
        
        return self.results


def print_results(results: List[TestResult], verbose: bool = False):
    """Afișează rezultatele testelor."""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    RESET = '\033[0m'
    BOLD = '\033[1m'
    
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{BOLD}║              OmniBus Blockchain - Test Results               ║{RESET}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════════╝{RESET}\n")
    
    total_time = 0
    passed_count = 0
    
    for result in results:
        status = f"{GREEN}✓ PASS{RESET}" if result.passed else f"{RED}✗ FAIL{RESET}"
        print(f"  [{status}] {result.name[:50]:50} {result.duration_ms/1000:5.1f}s")
        
        if result.passed:
            passed_count += 1
        
        if verbose and result.error:
            print(f"       {RED}{result.error[:100]}{RESET}")
        
        total_time += result.duration_ms
    
    print(f"\n  {'─' * 60}")
    print(f"  Total: {len(results)} grupuri, {passed_count} trecute, {len(results) - passed_count} picate")
    print(f"  Timp total: {total_time/1000:.1f}s")
    print(f"  {'─' * 60}\n")
    
    if passed_count == len(results):
        print(f"  {GREEN}{BOLD}✓ TOATE TESTELE AU TRECUT{RESET}\n")
    else:
        print(f"  {RED}{BOLD}✗ {len(results) - passed_count} GRUPURI AU PICAT{RESET}\n")


def watch_mode(runner: TestRunner, group_name: Optional[str] = None):
    """Watch mode pentru TDD."""
    import time
    
    print("\n  [WATCH MODE] Aștept modificări... (Ctrl+C pentru oprire)\n")
    
    last_mtime = 0
    
    try:
        while True:
            # Verifică dacă s-a modificat vreun fișier .zig
            max_mtime = 0
            for zig_file in runner.project_root.rglob('*.zig'):
                if any(part.startswith('.') for part in zig_file.parts):
                    continue
                mtime = zig_file.stat().st_mtime
                if mtime > max_mtime:
                    max_mtime = mtime
            
            if max_mtime > last_mtime:
                last_mtime = max_mtime
                print(f"\n  [CHANGE] Modificare detectată, rulez testele...\n")
                
                if group_name:
                    result = runner.run_group(group_name)
                    print_results([result])
                else:
                    results = runner.run_all()
                    print_results(results)
                
                print("  [WATCH] Aștept următoarea modificare...\n")
            
            time.sleep(1)
            
    except KeyboardInterrupt:
        print("\n  [WATCH] Oprit de utilizator.\n")


def main():
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Rulează teste selective pentru OmniBus',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Grupe disponibile:
  crypto   - Teste criptografie
  chain    - Teste blockchain
  net      - Teste rețea
  shard    - Teste sharding
  storage  - Teste storage
  light    - Teste light client
  wallet   - Teste wallet (necesită liboqs)

Exemple:
  python test_runner.py                    # Toate testele
  python test_runner.py --group crypto     # Doar crypto
  python test_runner.py --file core/p2p.zig  # Teste fișier
  python test_runner.py --watch            # Watch mode
  python test_runner.py --group chain --watch  # Watch doar chain
        """
    )
    parser.add_argument('--group', '-g', choices=list(TestRunner.TEST_GROUPS.keys()),
                        help='Rulează doar un grup specific')
    parser.add_argument('--file', '-f', type=str,
                        help='Rulează teste pentru un fișier specific')
    parser.add_argument('--watch', '-w', action='store_true',
                        help='Watch mode - rulează testele când se modifică fișiere')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Output verbose')
    parser.add_argument('--json', action='store_true',
                        help='Output JSON')
    
    args = parser.parse_args()
    
    # Find project root
    script_dir = Path(__file__).parent
    project_root = script_dir.parent.parent
    
    runner = TestRunner(project_root)
    
    # Watch mode
    if args.watch:
        watch_mode(runner, args.group)
        return
    
    # Run tests
    if args.group:
        result = runner.run_group(args.group)
        results = [result]
    elif args.file:
        filepath = Path(args.file)
        if not filepath.is_absolute():
            filepath = project_root / filepath
        result = runner.run_file_tests(filepath)
        results = [result]
    else:
        results = runner.run_all()
    
    # Output
    if args.json:
        print(json.dumps([asdict(r) for r in results], indent=2))
    else:
        print_results(results, args.verbose)
    
    # Exit code
    all_passed = all(r.passed for r in results)
    sys.exit(0 if all_passed else 1)


if __name__ == '__main__':
    main()
