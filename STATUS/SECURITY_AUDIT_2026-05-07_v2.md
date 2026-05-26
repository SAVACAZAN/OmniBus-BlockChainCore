# Security Audit — OmniBus BlockChainCore
**Date**: 2026-05-07  **Pass**: v2 (delta from v1)  **Auditor**: blockchain-security-auditor
**Scope**: secp256k1 timing, P2P eclipse, mempool DoS, RPC injection, key encryption, DNS fees

---

## Fix Status: Prior CRITICALs from v1

### CRIT-01 (DNS nonce namespace isolation) — FIXED

Each operation now signs over a distinct canonical message prefix defined in `rpc_server.zig:9370-9431`.
Each operation enforces `nonce > entry.last_nonce`. Cross-operation replay is structurally blocked.
**Residual**: `registername` accepts `nonce = 0` silently (SEV-07, LOW).

### CRIT-02 (PQ zero-key fallback on OQS_SIG_new failure) — FIXED

All four `generateKeyPairFromSeed` variants at `pq_crypto.zig:119, 187, 264, 338` now return a
typed `OqsSigError.OqsSigInitFailed` instead of a zeroed struct.
**Residual**: Narrow init-order race documented in SEV-08 (LOW).

---

## New Findings

### [SEV-01] RPC Bearer Token Uses Non-Constant-Time std.mem.eql
- **Severity**: HIGH  **File:Line**: `core/rpc_server.zig:6239`  **Category**: Timing
- **Description**: `isAuthorized` uses `std.mem.eql(u8, got, token)` which short-circuits on first
  mismatch, leaking matching prefix length via response latency. `constantTimeEql` is defined at
  rpc_server.zig:6210 but not called here.
- **Exploit**: Attacker times RPC responses to recover auth token byte-by-byte.
- **Fix**: Replace line 6239: `return std.mem.eql(u8, got, token);` -> `return constantTimeEql(got, token);`

### [SEV-02] P2P Eclipse: MAX_INBOUND_PER_SUBNET (4) Contradicts MAX_PEERS_PER_SUBNET (2)
- **Severity**: HIGH  **File:Line**: `core/p2p.zig:135-141`  **Category**: Protocol
- **Description**: Stated total budget is 2 peers/subnet. Inbound limit is 4, double the total.
  Attacker fills 4 inbound slots from one /16 subnet, crowding out honest peers.
- **Fix**: Set `MAX_INBOUND_PER_SUBNET = 1`. Or enforce MAX_PEERS_PER_SUBNET as combined in+out limit.

### [SEV-03] Mempool.replaceByNonce Bypasses Signature Verification
- **Severity**: HIGH  **File:Line**: `core/mempool.zig:541-570`  **Category**: Logic
- **Description**: `replaceByNonce` swaps mempool entry in-place without consulting `self.verifier`.
  The verifier callback enforced in `add()` is skipped entirely.
- **Exploit**: Attacker knowing victim's (from_address, nonce) redirects funds without owning the address.
- **Fix**: Add at top of replaceByNonce: `if (self.verifier) |v| { if (!v(self.verifier_ctx, &tx)) return false; }`

### [SEV-04] KeyManager.verifyPassword Accepts Any 8-Character String
- **Severity**: HIGH  **File:Line**: `core/key_encryption.zig:165-169`  **Category**: Logic
- **Description**: `verifyPassword` checks only `password.len >= 8`. Ignores `self.password_hash`
  and `self.master_key`. Any 8+ char string passes -- function is a stub. Source comment acknowledges:
  "necesita stocarea salt-ului master separat."
- **Exploit**: Wallet unlock, key export bypassed with "aaaaaaaa".
- **Fix**: Re-derive PBKDF2(password, master_salt, KDF_ITERATIONS) and compare with timingSafeEql.

### [SEV-05] SeenHashes Truncates Hash to 64 Chars -- Gossip Suppression
- **Severity**: MEDIUM  **File:Line**: `core/p2p.zig:762-770`  **Category**: Protocol
- **Description**: `@min(hash.len, 64)` truncation means two distinct hashes sharing the first 64
  hex chars are treated as identical. Malicious peer can poison seen-set to suppress a block/TX.
- **Fix**: Store hashes as raw [32]u8 arrays. Unambiguous, uses half the memory.

### [SEV-06] PBKDF2 KDF Iteration Count Below OWASP 2023 Minimum
- **Severity**: MEDIUM  **File:Line**: `core/key_encryption.zig:17`  **Category**: Logic
- **Description**: `KDF_ITERATIONS = 100_000`. Source comment cites OWASP 2023 minimum as 210k.
  Exfiltrated key store cracked 2.1x faster than recommended.
- **Fix**: Raise to 210_000 minimum; recommended 600_000 for forward margin.

### [SEV-07] registername Accepts nonce = 0 (LOW)
- **Severity**: LOW  **File:Line**: `core/rpc_server.zig:3786`  **Category**: Logic
- **Description**: Missing nonce key returns 0. Registration succeeds with last_nonce = 0.
  Does not break replay protection (domain-separated) but breaks audit trail integrity.
- **Fix**: Require nonce >= 1 in handleRegisterName.

### [SEV-08] Narrow Init-Order Race in deterministicRng (LOW)
- **Severity**: LOW  **File:Line**: `core/pq_crypto.zig:56-63`  **Category**: Logic
- **Description**: Future liboqs version invoking custom RNG during OQS_SIG_new could find stream
  null and write zero bytes before the Zig assignment completes. Not triggerable in current liboqs.
- **Fix**: Document ordering constraint; consider @fence(.seq_cst) after stream assignment.

### [SEV-09] RPC Auth Header Partially Case-Sensitive -- Lockout Risk (LOW)
- **Severity**: LOW  **File:Line**: `core/rpc_server.zig:6229-6234`  **Category**: Protocol
- **Description**: Only "Authorization: Bearer " and "authorization: Bearer " are checked.
  "Authorization: bearer <token>" returns 401 with valid token. May lead operators to disable auth.
- **Fix**: Use existing extractHttpHeader (case-insensitive) then normalize scheme prefix.

### [SEV-10] DNS Fee Computation Integer Overflow -- Near-Free Premium Name Squatting
- **Severity**: MEDIUM  **File:Line**: `core/dns_registry.zig:107-143`  **Category**: Overflow
- **Description**: 1-char .arbitraje name, 100 years, 100 owner count: intermediate product
  110_000_000_000_000_000 * 21_000 = 2.31e21 overflows u64 (max ~1.8e19). Wraps to small number
  in ReleaseFast mode. Trivial payment accepted; name registered at near-zero cost.
- **Fix**: `const product = std.math.mul(u64, base, mul) catch return std.math.maxInt(u64);`

---

## Summary Table

| ID | Status | Severity | Category | File |
|----|--------|----------|----------|------|
| CRIT-01 (v1) | FIXED | CRITICAL | Protocol | dns_registry.zig |
| CRIT-02 (v1) | FIXED | CRITICAL | Logic | pq_crypto.zig |
| SEV-01 | OPEN | HIGH | Timing | rpc_server.zig:6239 |
| SEV-02 | OPEN | HIGH | Protocol | p2p.zig:135-141 |
| SEV-03 | OPEN | HIGH | Logic | mempool.zig:541-570 |
| SEV-04 | OPEN | HIGH | Logic | key_encryption.zig:165-169 |
| SEV-05 | OPEN | MEDIUM | Protocol | p2p.zig:762-770 |
| SEV-06 | OPEN | MEDIUM | Logic | key_encryption.zig:17 |
| SEV-07 | OPEN | LOW | Logic | rpc_server.zig:3786 |
| SEV-08 | OPEN | LOW | Logic | pq_crypto.zig:56-63 |
| SEV-09 | OPEN | LOW | Protocol | rpc_server.zig:6229 |
| SEV-10 | OPEN | MEDIUM | Overflow | dns_registry.zig:107-143 |

**v2 new findings**: HIGH: 4 | MEDIUM: 3 | LOW: 3 | Total: 10
**All-time open**: HIGH: 4 | MEDIUM: 3 | LOW: 3 (2 prior CRITs resolved)

---

## Top 3 Fixes Before Mainnet

1. **SEV-01 -- Timing attack on bearer token (HIGH, one-line fix)**
   `constantTimeEql` already exists at rpc_server.zig:6210. One-line swap at line 6239.

2. **SEV-04 -- verifyPassword is a stub (HIGH, security bypass)**
   Any wallet unlock bypassed with "aaaaaaaa". Implement PBKDF2 re-derivation vs stored master key.

3. **SEV-10 -- DNS fee overflow enables near-free premium name squatting (MEDIUM)**
   Switch to std.math.mul with overflow-to-maxInt in feeForRegistrationWithOwnerCount.

---

## Notes on Clean Areas

- **secp256k1.zig**: Clean. Constant-time borrow-based arithmetic with XOR-accumulator equality.
  Scalar multiplication delegates to std.crypto.sign.ecdsa stdlib. Prior HIGH-01 (v1) confirmed closed.
- **pq_crypto.zig**: CRIT-02 confirmed fixed. All generateKeyPairFromSeed variants propagate errors.
- **transaction.zig**: Chain-ID binding and nonce scheme appear sound.

*Generated by blockchain-security-auditor -- 2026-05-07 -- Read-only pass -- no source files modified*
