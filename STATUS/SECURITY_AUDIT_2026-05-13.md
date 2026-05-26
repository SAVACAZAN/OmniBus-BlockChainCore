# Security Audit #8 — OmniBus-BlockChainCore
**Date:** 2026-05-13 | **Pass:** #8

## Summary Table — All Open Findings

| ID | Sev | File | Category | Status |
|----|-----|------|----------|--------|
| SEV-33 | HIGH* | transaction.zig:633 | Auth | NEW — PQ wallet drain |
| SEV-41 | HIGH | guardian.zig:100 | Auth | STILL-OPEN |
| SEV-01/32 | HIGH | rpc_server.zig:7688 | Timing | STILL-OPEN |
| SEV-03 | HIGH | mempool.zig | Auth | STILL-OPEN |
| SEV-04 | HIGH | rpc_server.zig | Auth | STILL-OPEN |
| SEV-19/26 | HIGH | price_oracle.zig:221 | Auth | STILL-OPEN |
| SEV-28 | HIGH | bls_signatures.zig | Crypto | STILL-OPEN |
| SEV-29 | HIGH | rpc_server.zig | Auth | STILL-OPEN |
| SEV-30 | HIGH | governance.zig | Logic | STILL-OPEN |
| SEV-31 | HIGH | finality.zig | Logic | STILL-OPEN |
| SEV-34 | MEDIUM | staking.zig:477 | Logic | NEW |
| SEV-35 | MEDIUM | encrypted_p2p.zig:68 | Crypto | STILL-OPEN |
| SEV-36 | MEDIUM | encrypted_p2p.zig:93 | Crypto | NEW |
| SEV-37 | MEDIUM | price_oracle.zig:288 | Logic | NEW |
| SEV-38 | MEDIUM | ws_server.zig:128 | DoS | NEW |
| SEV-39 | LOW | kademlia_dht.zig:193 | Logic | NEW |
| SEV-40 | LOW | htlc.zig:272 | Logic | NEW |

*SEV-33 effectively CRITICAL (fund theft, no key needed)

Open HIGH: 10 | Open MEDIUM: 5 | Open LOW: 2 | FIXED this pass: 1

---

## FIXED This Pass

**SEV-23 grid_cancel auth — CONFIRMED FIXED**
`core/grid_engine.zig:172` now checks `if (!std.mem.eql(u8, g.owner[0..g.owner_len], owner)) return GridError.NotOwner;`

---

## New Findings

### SEV-33: PQ/Hybrid TX verifySignature Returns true Unconditionally
- **Severity**: HIGH (fund theft, effectively CRITICAL)
- **File:Line**: `core/transaction.zig:633-635`
- **Category**: Auth
- **Description**: All 8 PQ/Hybrid scheme tags in `verifySignature` switch return `true` unconditionally. Any TX from a PQ-scheme address (`obk1_`, `obf5_`, `obs3_`, `obd5_`) passes with a garbage signature.
- **Exploit**: `TX { from = victim_pq_address, scheme = .pq_omni_ml_dsa, signature = [0]*128 }` — accepted by mempool, mined, funds transferred. No key required.
- **Fix**: Change branch to `return false` until pq_crypto.zig verify is wired in per scheme.

### SEV-34: Slash Evidence Not Cryptographically Verified
- **Severity**: MEDIUM
- **File:Line**: `core/staking.zig:477-523`
- **Category**: Logic
- **Description**: `submitSlashEvidence` for `double_sign` checks only that sig bytes are non-zero, not that they are valid ECDSA. For `invalid_block` and `downtime`, zero crypto verification.
- **Exploit**: Fake `SlashEvidence { reason = .invalid_block, validator = victim, sig1 = [0x01]*64 }` -> victim slashed 10%, attacker earns 1% reporter reward.
- **Fix**: `Secp256k1Crypto.verify(validator_pubkey_from_registry, block_hash, sig)` before slashing. Pubkey from on-chain registry, not evidence struct.

### SEV-36: AES-GCM Nonce Has 4 Static Zero Bytes
- **Severity**: MEDIUM
- **File:Line**: `core/encrypted_p2p.zig:93-94`
- **Category**: Crypto
- **Description**: Nonce = `[0,0,0,0] ++ u64_counter`. All sessions share nonce prefix. Combined with SEV-35's broken shared key, identical nonces enable keystream XOR recovery.
- **Fix**: Random 4-byte session salt at handshake for nonce[0..4].

### SEV-37: Oracle Median Biased for Even Submission Count
- **Severity**: MEDIUM
- **File:Line**: `core/price_oracle.zig:288`
- **Category**: Logic
- **Description**: `prices[valid_count/2]` takes upper value for even counts. For 4 submissions `[100,100,105,105]` picks index 2 = 105. Outlier check: 100 deviates 4.76% from 105, passes 5% threshold. Two-of-four colluding miners bias price +5%.
- **Fix**: `(@as(u128, prices[n/2-1]) + prices[n/2]) / 2` for even counts to use true median.

### SEV-38: WebSocket acceptLoop Has No Connection Limit
- **Severity**: MEDIUM
- **File:Line**: `core/ws_server.zig:128-176`
- **Category**: DoS
- **Description**: No upper bound on concurrent WS clients. Unlimited `allocator.create(WsClient)` + `Thread.spawn` per connection.
- **Exploit**: Open thousands of connections to ws://127.0.0.1:8334 -> OOM, thread exhaustion, socket exhaustion. Node stops serving RPC and mining pool.
- **Fix**: `const MAX_WS_CLIENTS = 64;` — reject above limit with immediate close.

### SEV-39: Kademlia findClosest Searches Only One Bucket
- **Severity**: LOW
- **File:Line**: `core/kademlia_dht.zig:193-213`
- **Category**: Protocol
- **Description**: Only XOR-distance bucket searched. Per Kademlia spec, adjacent buckets must expand until K results gathered. Creates routing holes, cheapens eclipse attacks.
- **Fix**: Iterate adjacent buckets ±1, ±2, ... until K peers collected.

### SEV-40: computeHtlcId Hashes Hex String Not Raw Bytes
- **Severity**: LOW
- **File:Line**: `core/htlc.zig:272-275`
- **Category**: Logic
- **Description**: `SHA256.hash(init_tx_hash_hex)` receives 64-char ASCII hex, not 32 raw bytes. Internally consistent but breaks external interoperability.
- **Fix**: Decode hex to raw bytes before hashing, or document this as canonical.

---

## Still Open (Carry-Forward)

| ID | Description | Effort |
|----|-------------|--------|
| SEV-01 | Bearer token: std.mem.eql -> constantTimeEql at rpc_server.zig:7688 | 1 line |
| SEV-03 | mempool replaceByNonce accepts unsigned replacement TX | 15 lines |
| SEV-04 | verifyPassword stub — any password accepted | 30 lines |
| SEV-19/26 | oracle submissions without miner signature verification | 20 lines |
| SEV-28 | BLS: any non-zero pubkey passes verifyAggregate | 10 lines |
| SEV-29 | REST/HMAC bypass via JSON-RPC routing | 20 lines |
| SEV-30 | governance voting power unbounded | 10 lines |
| SEV-31 | finality caller-supplied stake not verified on-chain | 10 lines |
| SEV-35 | encrypted_p2p: HMAC(privkey,pubkey) != ECDH, sessions broken in prod | 30 lines |
| SEV-41 | guardian.removeGuardian: no signature, anyone strips 2FA | 10 lines |

---

## Clean Modules This Pass

- **transaction.zig ECDSA path**: hash recomputed before verify, no substitution attack
- **staking.zig**: zero-stake guard and unbonding period both correct
- **htlc.zig**: preimage verify, timelock, double-claim all correct
- **matching_engine.zig**: zero-price/quantity rejected, pair_id bounded, no u64 overflow in fill path
- **price_oracle.zig**: per-miner-per-round duplicate detection working
- **ws_server.zig frame parsing**: extended-length frames correct, masked payload capped
- **kademlia_dht.zig**: LRU eviction correct, no bucket OOB
- **guardian.zig**: 20,000-block activation delay enforced

---

## Priority Fix Order

| # | ID | Location | Effort | Impact |
|---|----|----------|--------|--------|
| 1 | SEV-33 | transaction.zig:633 | 1 line | PQ wallet drain — any PQ address drainable |
| 2 | SEV-41 | guardian.zig:100 | 10 lines | 2FA stripped from any account |
| 3 | SEV-01 | rpc_server.zig:7688 | 1 line | Bearer token timing attack |
| 4 | SEV-34 | staking.zig:477 | 20 lines | Stake theft via fake slash evidence |
| 5 | SEV-38 | ws_server.zig:128 | 5 lines | Node DoS via WS flood |
| 6 | SEV-04 | rpc_server.zig | 30 lines | Password auth bypass |
| 7 | SEV-03 | mempool.zig | 15 lines | Unsigned TX replacement |
| 8 | SEV-35 | encrypted_p2p.zig:68 | 30 lines | Encrypted P2P non-functional |
| 9 | SEV-37 | price_oracle.zig:288 | 5 lines | Oracle median manipulation |
| 10 | SEV-28/29/30/31 | multiple | varies | Consensus/governance integrity |
