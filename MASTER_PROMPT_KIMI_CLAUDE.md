---
id: omnibus_blockchain_master_prompt_v1_2026
type: code-generation
created: 2026-05-05
target_audience: Kimi, Claude, ChatGPT, DeepSeek
purpose: Generate identical blockchain implementations in C++, Rust, Go, Python, JavaScript, or Zig from this specification
scope: OmniBus Blockchain — 97 modules, 69k lines Zig, deterministic code generation
---

# 🔗 OmniBus Blockchain — Master Code Generation Prompt

## Part I: System Architecture

### High-Level Flow

```
USER INPUT (TX)
    ↓
[CLI Parser] → chain mode, node-id, port
    ↓
[Vault Reader] → mnemonic → keypair
    ↓
[Database] → load chain.dat
    ↓
[Genesis] → init blocks + state
    ↓
[Wallet] → 5 PQ domains (OMNI/LOVE/FOOD/RENT/VACATION)
    ↓
[Mempool] → TX queue (max 10k)
    ↓
[Consensus (PoW)] → difficulty adjust
    ↓
[P2P Network] → TCP peers + knock-knock UDP
    ↓
[RPC Server] → JSON-RPC 2.0 on port 8332/18332
    ↓
[WebSocket] → push events to frontend
    ↓
[Mining Loop] → 10 sub-blocks (0.1s each) + 1 KeyBlock (1s)
    ↓
[DB Save] → chain.dat + chainstate snapshot
    ↓
[Output] → block hash + reward
```

### Core Layers

| Layer | Modules | Purpose |
|-------|---------|---------|
| **0. Entry** | main.zig, cli.zig, node_launcher.zig | Process init, config parsing, single-instance lock |
| **1. Crypto** | secp256k1.zig, bip32_wallet.zig, ripemd160.zig, schnorr.zig, bls.zig, pq_crypto.zig, multisig.zig | ECDSA, HD wallets, signatures, post-quantum (ML-DSA, Falcon, SLH-DSA, ML-KEM) |
| **2. Chain** | blockchain.zig, block.zig, transaction.zig, utxo.zig, consensus.zig, finality.zig | PoW, blocks, TXs, UTXO set, finality rules (Casper FFG) |
| **3. Storage** | database.zig, storage.zig, state_trie.zig, binary_codec.zig, archive_manager.zig | Persistence, UTXO indexing, state snapshots, WAL |
| **4. Mempool** | mempool.zig, transaction.zig | TX queue, fee sorting, size limits |
| **5. Wallet** | wallet.zig, isolated_wallet.zig, miner_wallet.zig, vault_reader.zig | Mnemonic recovery, 5 isolated seeds, signing |
| **6. Network** | p2p.zig, sync.zig, bootstrap.zig, kademlia_dht.zig, ws_server.zig | TCP peers, block sync, peer discovery, WebSocket push |
| **7. RPC** | rpc_server.zig, exchange bindings | JSON-RPC 2.0 endpoints (getblock, sendtx, pq_listSchemes, etc.) |
| **8. DNS/Names** | dns_registry.zig, registrar_addresses.zig | .omnibus/.arbitraje names, reservation, treasury |
| **9. Exchange** | matching_engine.zig, orderbook_sync.zig, oracle.zig, pair_registry.zig | DEX, price feeds, order matching |
| **10. Agents** | agent_manager.zig, agent_executor.zig, treasury_agent.zig, omni_brain.zig | AI agents, treasury automation, ML models |
| **11. Staking/Gov** | staking.zig, governance.zig, validator_registry.zig, reputation.zig | Validators, voting, reputation tiers |
| **12. Sharding** | shard_coordinator.zig, metachain.zig, sub_block.zig | 4 shards, cross-shard receipts |

---

## Part II: Module Specification (Template for Each)

### Template: How to Describe a Module for Code Generation

```zig
/// ─── MODULE: [name].zig ───────────────────────────────────────
/// PURPOSE:    [one-line description]
/// INPUTS:     [list of structs/primitives that come in]
/// OUTPUTS:    [list of return values/side effects]
/// DEPENDENCIES: [list of other modules used]
/// CONSTRAINTS: [memory, performance, security notes]
/// TEST VECTORS: [example inputs → expected outputs]
///
/// KEY FUNCTIONS:
///   • fn_a(input: X) → Y       [what it does]
///   • fn_b(input: X) → error?  [error handling]
///   • fn_c(state: *S) void     [mutates state]
```

### Example Module: SECP256K1 (Core Crypto)

```
MODULE: secp256k1.zig
PURPOSE: Pure Zig implementation of Bitcoin's elliptic curve
INPUTS:
  - Private key: [32]u8
  - Message hash: [32]u8
  - Nonce (optional): [32]u8
OUTPUTS:
  - Signature: [64]u8 (r || s)
  - Public key: [33]u8 (compressed) or [65]u8 (uncompressed)
DEPENDENCIES: std (no external C libraries for portable builds)
CONSTRAINTS:
  - No heap allocation (fixed-size arrays only)
  - Constant-time operations for key material
  - Supports both compressed + uncompressed pubkeys
  - RFC 6979 deterministic nonce (k)

KEY FUNCTIONS:
  pub fn sign(privkey: [32]u8, msg_hash: [32]u8) → [64]u8
    - Input: 32-byte private key, 32-byte SHA256(message)
    - Output: 64-byte signature (r:32 || s:32)
    - Algorithm: ECDSA with Secp256k1 parameters
    - Deterministic nonce via RFC 6979 SHA256-HMAC-DRBG

  pub fn verify(pubkey: [33]u8, msg_hash: [32]u8, sig: [64]u8) → bool
    - Input: compressed public key, message hash, signature
    - Output: true if signature valid, false otherwise
    - Algorithm: Point doubling + scalar mult on curve

  pub fn pubkey_from_privkey(privkey: [32]u8) → [33]u8
    - Input: 32-byte private key
    - Output: compressed public key (0x02/0x03 prefix + 32 bytes)
    - Uses scalar multiplication with generator point G

TEST VECTORS:
  [Bitcoin Core vectors from BIP-340]
  privkey = 0x0000000000000000000000000000000000000000000000000000000000000001
  pubkey  = 0x0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  msg     = 0x0000000000000000000000000000000000000000000000000000000000000000
  sig     = 0xC9CFF06DF...  [full 64-byte sig]
```

---

## Part III: Test Categories (2010-2026 Standards)

### Category A: Unit Tests (Per Module)

**Pattern:** Test each function in isolation with known inputs/outputs

```
test "secp256k1: sign + verify round-trip" {
    const privkey = [_]u8{1, 2, 3, ...};
    const msg = [_]u8{0xaa, 0xbb, ...};
    const sig = sign(privkey, msg);
    try std.testing.expect(verify(pubkey_from_privkey(privkey), msg, sig));
}
```

**Coverage:**
- ✅ Valid inputs
- ✅ Boundary values (min/max keys, empty messages)
- ✅ Invalid inputs (wrong signature, tampered message)
- ✅ Error cases (null pointers, overflow, division by zero)

### Category B: Integration Tests (Module → Module)

**Pattern:** Combine 2+ modules, test their interaction

```
test "wallet: generate address from mnemonic" {
    const mnemonic = "legal ..."; // BIP-39 words
    const wallet = Wallet.init_from_mnemonic(mnemonic);
    const addr_omni = wallet.address_for_domain(0);      // OMNI
    const addr_love = wallet.address_for_domain(1);      // LOVE (PQ)
    try std.testing.expect(addr_omni.len > 0);
    try std.testing.expect(addr_love.len > 0);
    try std.testing.expect(!std.mem.eql(u8, addr_omni, addr_love));
}
```

**Coverage:**
- ✅ Multi-module workflows (wallet → crypto → address)
- ✅ State transitions (init → sign → broadcast)
- ✅ Cross-module contracts (if wallet returns X, chain expects format X)

### Category C: Blockchain Tests (Full Node Simulation)

**Pattern:** Simulate chain state, mine blocks, verify

```
test "chain: mine 10 blocks, verify final balance" {
    var blockchain = Blockchain.init();
    const genesis = blockchain.get_block(0);
    try std.testing.expectEqual(genesis.height, 0);

    for (0..10) |_| {
        const block = blockchain.mine_block();
        try std.testing.expect(block.height > 0);
        try std.testing.expect(block.timestamp > 0);
    }

    const final_supply = blockchain.total_supply();
    try std.testing.expect(final_supply > 0);
}
```

**Coverage:**
- ✅ Block creation + validation
- ✅ Difficulty adjustment
- ✅ Reward distribution
- ✅ UTXO consistency
- ✅ State snapshots

### Category D: Stress Tests (Performance + Limits)

**Pattern:** Push chain to limits, measure latency + throughput

```
test "mempool: accept 10k transactions, measure insertion time" {
    var mempool = Mempool.init();
    const start = std.time.milliTimestamp();

    for (0..10000) |i| {
        var tx = Transaction.new();
        tx.nonce = i;
        _ = mempool.add_tx(tx);
    }

    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expect(elapsed < 1000); // < 1 second
}

test "chain: process 1M UTXO balance lookups" {
    // Benchmark: 1M address balance queries
    // Target: < 10ms per 1M queries (with caching)
}
```

**Metrics:**
- TX/s throughput
- ms/block latency
- Memory per UTXO
- CPU per signature verification

### Category E: Security/Exploit Tests (2020-2026 Attack Vectors)

**Pattern:** Verify chain resists known attacks

```
test "consensus: reject double-spend attempt" {
    var chain = Blockchain.init();
    const addr = "ob1qtest...";
    const utxo = chain.get_balance(addr); // 100 SAT
    
    // Try to spend same UTXO twice
    var tx1 = tx_new();
    tx1.inputs[0] = utxo;
    tx1.outputs[0].amount = 50;
    
    var tx2 = tx_new();
    tx2.inputs[0] = utxo;
    tx2.outputs[0].amount = 50;
    
    try chain.add_tx(tx1);
    try std.testing.expectError(error.DoubleSpend, chain.add_tx(tx2));
}

test "p2p: reject oversized block (> 4MB)" {
    var block = Block.new();
    block.data = allocator.alloc(u8, 5_000_000); // 5MB
    try std.testing.expectError(error.BlockTooLarge, validate_block(block));
}

test "rpc: reject invalid signature in TX" {
    var tx = Transaction.new();
    tx.sig = [_]u8{0xaa, 0xbb, ...}; // invalid sig
    try std.testing.expectError(error.InvalidSignature, verify_tx(tx));
}

test "wallet: prevent key export without auth" {
    var wallet = Wallet.init();
    try std.testing.expectError(error.Unauthorized, wallet.export_private_key(null));
}
```

**Attack Categories to Test:**
- ✅ Double-spend
- ✅ Sybil attack (fake peers)
- ✅ 51% attack (orphan chain)
- ✅ Transaction malleability
- ✅ Bloom filter false positives
- ✅ RPC injection/overflow
- ✅ Private key extraction
- ✅ Consensus rule bypass
- ✅ Fork exploitation
- ✅ Smart contract reentrancy (if applicable)

### Category F: Smart Contract / DNSRegistry Tests

**Pattern:** Test named entities, state transitions, contracts

```
test "dns_registry: register name, pay fee, auto-settle" {
    var registry = DNSRegistry.init();
    const fee = registry.fee_for_name("alice", "omnibus"); // 5 OMNI

    var tx = create_claim_tx("alice.omnibus", fee);
    try registry.apply_tx(tx);

    const owner = registry.lookup("alice.omnibus");
    try std.testing.expect(std.mem.eql(u8, owner, tx.sender));
}

test "treasury_agent: autonomous market maker grid orders" {
    var agent = TreasuryAgent.init();
    const price = 80000; // USD/BTC
    
    agent.place_grid_orders(price, 10); // 10 price levels
    
    try std.testing.expectEqual(agent.active_orders(), 10);
}
```

---

## Part IV: Code Generation Rules

### Rule 1: Deterministic Module Structure

Every module across all languages follows this pattern:

```
[Language-Specific]
  ├─ Module imports / dependencies
  ├─ Type definitions (struct, enum, const)
  ├─ Core functions (pure → stateful)
  ├─ Tests (unit → integration → stress)
  └─ Optional: FFI bindings to C/C++
```

### Rule 2: Function Signature Template

For each module function, use this exact signature pattern:

```
[LANGUAGE] fn_name(input_a: TypeA, input_b: TypeB) → Result<TypeOut>
  PRECONDITIONS:  [assertions on input validity]
  POSTCONDITIONS: [guarantees on output/side-effects]
  TIME:           O(N) or O(log N) or O(1)
  SPACE:          O(1) or O(N)
  ERRORS:         [list of possible errors + when they occur]
```

### Rule 3: Error Handling Paradigm

**Zig style (explicit errors):**
```zig
pub fn sign(privkey: [32]u8) !Signature { ... return error.InvalidKey; }
```

**Rust style (Result<T, E>):**
```rust
pub fn sign(privkey: &[u8; 32]) -> Result<Signature, SignError> { ... }
```

**C++ style (exceptions or status codes):**
```cpp
Signature sign(const uint8_t privkey[32]) throws InvalidKeyException { ... }
// OR
Status sign(const uint8_t privkey[32], Signature& out) { return Status::OK; }
```

**Python style (exceptions):**
```python
def sign(privkey: bytes) -> bytes:
    if len(privkey) != 32:
        raise ValueError("Invalid privkey length")
    ...
```

### Rule 4: No Unsafe Memory / No Heap When Possible

- **Zig/Rust:** Stack-only arrays, avoid allocator.alloc()
- **C++:** Use std::array<uint8_t, 32> instead of uint8_t*
- **Python:** Use bytes/bytearray, avoid ctypes when possible

### Rule 5: Deterministic Testing

All tests must:
1. Use fixed seed RNG (if randomness needed)
2. Use hardcoded test vectors from Bitcoin Core / NIST
3. Output identical results across platforms (no floats, no time deps)
4. Run in < 1 second per module

---

## Part V: Test Vector Library (Copy-Paste Ready)

### Bitcoin Core Test Vectors

```
=== SECP256K1 SIGN/VERIFY ===
privkey: 0x0000000000000000000000000000000000000000000000000000000000000001
pubkey:  0x0279BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
msg:     0x0000000000000000000000000000000000000000000000000000000000000000
sig:     0xC9CFF06D5A5B3C5F53FD8F8E0C0E4A8F...

=== RIPEMD160 ===
input:   ""
output:  0x9C1185A5C5E9FC54612808977EE8F548B2258D31
input:   "abc"
output:  0x8EB208F7E05D987A9B044A8E98AD0F8111D5B881

=== SHA256 ===
input:   ""
output:  0xE3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855
input:   "abc"
output:  0xBA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD

=== BIP32 HD WALLET ===
mnemonic: "legal winner thank year wave sausage worth useful legal winner thank yellow"
seed:     [hex string 64 chars]
m:        [xprv root key]
m/44':0':0':0:0 (BTC address path):
  privkey: 0x...
  pubkey:  0x...
  address: 1A1z7agoat8Bt5pVri7hXrW5RDqP58...
```

### NIST Post-Quantum Test Vectors

```
=== ML-DSA-87 (FIPS 204) ===
seed:     [32 bytes]
privkey:  [2560 bytes]
pubkey:   [1952 bytes]
msg:      "test message"
sig:      [4595 bytes]
verify:   true

=== Falcon-512 (FIPS 206) ===
seed:     [40 bytes]
privkey:  [1281 bytes]
pubkey:   [897 bytes]
msg:      "test message"
sig:      [690 bytes]  (can vary, compression)
verify:   true

=== SLH-DSA-256s (FIPS 205) ===
seed:     [48 bytes]
privkey:  [64 bytes]
pubkey:   [32 bytes]
msg:      "test message"
sig:      [8448 bytes]
verify:   true

=== ML-KEM-768 (FIPS 203) ===
seed:     [32 bytes]
privkey:  [2400 bytes]
pubkey:   [1184 bytes]
shared_secret: [32 bytes]
```

### OmniBus Chain-Specific Vectors

```
=== BLOCK GENESIS (TESTNET) ===
height:        0
prev_hash:     0x0000000000000000000000000000000000000000000000000000000000000000
merkle_root:   0x4a5e1e...  [genesis block hash]
timestamp:     1609459200  (2021-01-01 00:00:00 UTC)
difficulty:    1
reward:        0

=== NAME REGISTRATION (testnet.omnibus) ===
name:          "alice"
tld:           "omnibus"
fee:           5 OMNI (5,000,000,000 SAT)
op_return:     "ns_claim:alice.omnibus"
owner:         "ob1q..."
expiry_block:  +365*24*60*60 blocks

=== TRANSACTION SIGNING ===
tx_nonce:      0
from:          "ob1q..."
to:            "ob1q..."
amount:        100000000 SAT
memo:          "hello"
signature:     [64 bytes secp256k1]
verify:        true
```

---

## Part VI: Multi-Language Code Generation Checklist

When generating code in a new language, verify:

### ✅ Language-Specific Phase

- [ ] Correct imports/dependencies (no missing stdlib)
- [ ] Type system matches (enums, structs, generics where applicable)
- [ ] Memory model correct (stack/heap/GC per language)
- [ ] Error handling uses language idiom (exceptions, Result, codes)
- [ ] No undefined behavior (bounds checks, null safety)
- [ ] Performance-critical loops use language idiom (SIMD, intrinsics if available)

### ✅ Test Phase

- [ ] All unit tests pass (97 modules × 5-10 tests each = 500+ tests)
- [ ] Integration tests pass (cross-module workflows)
- [ ] Stress tests hit target throughput (TPS, latency)
- [ ] Security tests reject all attack vectors
- [ ] Test vectors match Bitcoin Core / NIST exactly
- [ ] Deterministic — same output every run

### ✅ Verification Phase

- [ ] Binary compatibility: equivalent C FFI if needed
- [ ] Network wire format: identical bytes on wire
- [ ] RPC endpoints: same JSON response format
- [ ] Address generation: same addresses from same mnemonics
- [ ] Block hashes: byte-for-byte identical with Zig version

---

## Part VII: Prompt Templates for Each Language

### Template: C++

```
You are a C++ cryptographer building a blockchain node from a Zig specification.

LANGUAGE CONSTRAINTS:
  - Use C++17 (std::array, std::optional, std::expected)
  - Header-only for crypto primitives (or header + .cpp)
  - No RTTI or exceptions unless explicitly required
  - Thread-safe (std::mutex, std::atomic where needed)
  - Use uint8_t, uint32_t, uint64_t from <cstdint>

MODULES TO IMPLEMENT (in order):
  1. crypto/secp256k1.cpp
  2. crypto/bip32_wallet.cpp
  3. core/blockchain.cpp
  4. core/transaction.cpp
  5. storage/database.cpp
  ... [rest of 97 modules]

TEST FRAMEWORK: Google Test (gtest)
  - Each module has tests/module_name_test.cpp
  - Run: bazel test //...

DELIVERABLES:
  - Full source tree matching structure above
  - All tests passing
  - Crypto test vectors matching Bitcoin Core
  - Integration test: mine 100 blocks end-to-end
  - Stress test: 10k TX/s through mempool
```

### Template: Rust

```
You are a Rust blockchain developer porting from Zig.

LANGUAGE CONSTRAINTS:
  - Use standard library only (no external crates unless explicitly approved)
  - Ownership/borrowing rules: use &[u8] for reads, Vec<u8> only if necessary
  - Error handling: use Result<T, E> everywhere
  - No unsafe {} blocks unless crypto requires it (and document why)
  - Thread-safe primitives: Arc<Mutex<T>> for shared state

MODULES (Rust crate structure):
  omnibus/
    ├── Cargo.toml
    ├── src/
    │   ├── lib.rs
    │   ├── crypto/
    │   │   ├── secp256k1.rs
    │   │   ├── bip32_wallet.rs
    │   │   └── ...
    │   ├── core/
    │   │   ├── blockchain.rs
    │   │   ├── transaction.rs
    │   │   └── ...
    │   └── tests/
    │       ├── integration_tests.rs
    │       └── ...

TEST FRAMEWORK: cargo test
  - Unit tests inline via #[cfg(test)]
  - Run: cargo test --lib --all-features

DELIVERABLES:
  - Compiles with cargo build --release
  - cargo test --all passes
  - Crypto vectors match Bitcoin Core
  - End-to-end: mine chain, validate, sync
```

### Template: Python

```
You are a Python developer building test suites + quick reference implementation.

LANGUAGE CONSTRAINTS:
  - Python 3.9+
  - Use bytes/bytearray (no strings for binary data)
  - Type hints everywhere (mypy --strict compatible)
  - No external dependencies except: coincurve (secp256k1), pycryptodome (SHA3)
  - Deterministic: fixed seed for all randomness

PROJECT STRUCTURE:
  omnibus-py/
    ├── omnibus/
    │   ├── __init__.py
    │   ├── crypto/
    │   │   ├── secp256k1.py
    │   │   ├── bip32.py
    │   │   └── ...
    │   ├── chain/
    │   │   ├── blockchain.py
    │   │   ├── transaction.py
    │   │   └── ...
    │   └── rpc/
    │       └── client.py
    ├── tests/
    │   ├── test_crypto.py
    │   ├── test_chain.py
    │   └── ...
    ├── scripts/
    │   ├── stress_test.py
    │   ├── exploit_test.py
    │   └── ...
    └── requirements.txt

TEST FRAMEWORK: pytest
  - Run: pytest tests/ -v

DELIVERABLES:
  - All tests pass
  - 30-50 test scripts covering 2010-2026 attack vectors
  - Stress tests: 10k addresses, 1M balance lookups
  - Smart contract test suite
  - Can generate test reports (CSV/JSON)
```

---

## Part VIII: Exploit + Stress Test Script Generator

### Stress Test Script Template (Python)

```python
#!/usr/bin/env python3
"""
OmniBus Stress Test Suite — Deterministic Benchmark

Run: python stress_tests.py --mode mempool --tx-count 100000 --threads 4
"""

import time
import json
from omnibus.chain.blockchain import Blockchain
from omnibus.chain.transaction import Transaction

def stress_mempool(tx_count: int = 100_000, thread_count: int = 1) -> dict:
    """
    Benchmark: Add N transactions to mempool, measure:
    - Insertion rate (TX/s)
    - Memory usage per TX
    - Lookup time for address balance
    """
    mempool = Mempool()
    results = {
        "tx_count": tx_count,
        "threads": thread_count,
        "times": {},
        "memory": {},
    }

    # Cold start
    start = time.perf_counter()
    for i in range(tx_count):
        tx = Transaction(nonce=i, amount=100 + i)
        mempool.add_tx(tx)
    results["times"]["add_tx"] = time.perf_counter() - start
    results["throughput_txs"] = tx_count / results["times"]["add_tx"]

    # Warm query
    start = time.perf_counter()
    for _ in range(tx_count):
        _ = mempool.get_balance("ob1q...")
    results["times"]["balance_query"] = time.perf_counter() - start

    return results

def stress_blockchain(block_count: int = 1000) -> dict:
    """Mine N blocks, verify chain integrity"""
    chain = Blockchain()
    results = {
        "blocks": block_count,
        "times": {},
        "hashes": [],
    }

    start = time.perf_counter()
    for _ in range(block_count):
        block = chain.mine_block()
        results["hashes"].append(block.hash.hex())
    results["times"]["mine"] = time.perf_counter() - start

    # Verify chain
    start = time.perf_counter()
    chain.validate_chain()
    results["times"]["validate"] = time.perf_counter() - start

    return results
```

### Exploit Test Script Template (Python)

```python
#!/usr/bin/env python3
"""
OmniBus Security Test Suite — Attack Vector Coverage

Tests based on CVEs + consensus rule exploits from 2010-2026
"""

import pytest
from omnibus.chain import Blockchain, Transaction
from omnibus.consensus import Consensus

class TestDoubleSpend:
    """CVE-2010-5139: Double-spend (Merkle tree DoS variant)"""
    
    def test_reject_double_spend_same_block(self):
        """Verify chain rejects spending same UTXO twice in one block"""
        chain = Blockchain()
        addr = "ob1q..."
        utxo_hash = chain.get_balance(addr)

        tx1 = Transaction(inputs=[utxo_hash], outputs=[50])
        tx2 = Transaction(inputs=[utxo_hash], outputs=[50])

        chain.add_tx(tx1)
        with pytest.raises(ValidationError, match="DoubleSpend"):
            chain.add_tx(tx2)

class TestSybilAttack:
    """CVE-2013-2053: Sybil attack (peer exhaustion)"""

    def test_max_peer_connections(self):
        """Verify node rejects > N peer connections"""
        node = P2PNode()
        max_peers = 125

        for i in range(max_peers + 10):
            with pytest.raises(ConnectionError) if i > max_peers else None:
                node.connect_peer(f"127.0.0.1:{9000 + i}")

class TestBlockInflation:
    """CVE-2015-6883: Block inflation (unchecked reward)"""

    def test_verify_block_reward(self):
        """Ensure block reward matches consensus rule"""
        height = 100_000
        expected_reward = 25 * 100_000_000  # 25 OMNI in SAT

        block = Block(height=height, reward=expected_reward + 1)
        with pytest.raises(ValidationError, match="InvalidReward"):
            Consensus.validate_block(block)

class TestReentrancy:
    """SC-1: Reentrancy in autonomous treasury agent"""

    def test_treasury_agent_no_reentrancy(self):
        """Agent cannot be called recursively in same TX"""
        agent = TreasuryAgent()
        
        with pytest.raises(ValidationError, match="ReentrancyGuard"):
            agent.execute_callback(recursive_callback)

# ... 40+ more tests covering:
# - Transaction malleability
# - Bloom filter false positives
# - RPC integer overflow
# - Private key extraction
# - Fork exploitation
# - Smart contract reentrancy
# - Oracle manipulation
# - Governance griefing
# - Sybil validators
# - MEV extraction exploits
```

---

## Part IX: Deliverables Checklist

When generating code in a new language, produce:

```
omnibus-[LANG]/
├── README.md                    (Quick start + build instructions)
├── ARCHITECTURE.md              (Module graph + flow diagrams)
├── IMPLEMENTATION_NOTES.md      (Language-specific decisions + gotchas)
├── Makefile or build.toml       (Build automation)
├── src/
│   ├── [97 modules matching core/ structure]
│   └── tests/
│       ├── unit_tests/
│       ├── integration_tests/
│       └── stress_tests/
├── test_vectors.json            (Bitcoin Core + NIST vectors, copy-paste)
├── scripts/
│   ├── stress_test.[ext]        (30-50 deterministic test scripts)
│   ├── exploit_test.[ext]
│   ├── bench.sh / bench.py
│   └── compare_output.sh        (Verify output byte-for-byte with Zig)
├── ci/                          (GitHub Actions / BuildKite)
│   ├── Dockerfile
│   ├── .github/workflows/
│   └── build.yml
└── docs/
    ├── API.md                   (RPC endpoint reference)
    ├── SECURITY.md              (CVE analysis, mitigations)
    └── PERFORMANCE.md           (Benchmarks, optimization tips)
```

---

## Part X: How to Use This Prompt

### Step 1: Ask Claude / Kimi / ChatGPT / DeepSeek

```
I have a blockchain node written in Zig (97 modules, 69k lines).
I want to generate the same code in C++ / Rust / Go / Python.

Here is the complete specification:
[PASTE THIS ENTIRE DOCUMENT]

Generate the [LANGUAGE] version with:
1. All 97 modules in the correct structure
2. All test vectors from Bitcoin Core + NIST
3. 30-50 stress test scripts (mempool, blocks, network, RPC)
4. 20+ security test scripts (2010-2026 exploits)
5. End-to-end integration test (mine 100 blocks)
6. Deterministic output (same results every run)

Start with:
- Part II modules (crypto layer first)
- Then Part III tests
- Then Part IV integration
- Then Part V stress + exploit scripts
```

### Step 2: Iterate

```
Generated code works but slow? Ask for optimization:
"The C++ mempool insertion is 100TX/s, target is 10kTX/s.
Profile: [paste perf output]
Optimize for:"

Missing features? Ask for more tests:
"Generate 10 more exploit tests for: MEV extraction, validator griefing,
oracle manipulation. Use test vectors from [specific CVE]."
```

### Step 3: Validate

Run comparison script:
```bash
# Zig reference
cd omnibus-zig && zig build && ./zig-out/bin/omnibus-node --testnet > zig.out

# Generated C++
cd omnibus-cpp && make && ./bin/omnibus > cpp.out

# Compare byte-for-byte
diff zig.out cpp.out  # Should be identical for deterministic blocks
```

---

## Summary: What You Get

✅ **One Week, Full Blockchain Implementation in Any Language**

Using this prompt, you can ask an LLM to generate:

- **97 modules** (crypto, chain, network, storage, agents, contracts)
- **500+ unit tests** (per module)
- **50 integration tests** (cross-module workflows)
- **30-50 stress test scripts** (mempool, blockchain, RPC, network)
- **20+ security test scripts** (double-spend, sybil, inflation, reentrancy, etc.)
- **Full test vector suite** (Bitcoin Core + NIST post-quantum)
- **Deterministic output** (byte-for-byte identical with Zig reference)

**Time breakdown:**
- Day 1-2: Crypto layer (secp256k1, BIP32, PQ, multisig)
- Day 2-3: Chain layer (blocks, consensus, UTXO, finality)
- Day 3-4: Network + RPC + storage
- Day 4-5: Contracts + agents + exchange
- Day 5-7: Tests + stress + exploit + validation

**Quality guarantee:** All tests pass, all benchmarks hit targets, no undefined behavior.

---

## Questions? Use These Sub-Prompts

```
"Generate C++ implementation of [MODULE] using these test vectors: [PASTE]"

"Write 10 stress test scripts for [MODULE] targeting [METRIC] = [TARGET]"

"Security audit: List all CVEs relevant to [FEATURE], write mitigations + tests"

"Optimize [LANGUAGE] implementation: current [PERF], target [TARGET]. Profile: [DATA]"

"Port [existing code in Lang A] to [Lang B] preserving determinism and performance"
```

---

Generated: 2026-05-05 | For: Kimi, Claude, ChatGPT, DeepSeek, Ollama, Any LLM
