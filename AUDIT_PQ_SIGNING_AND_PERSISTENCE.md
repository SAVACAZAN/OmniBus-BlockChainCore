# AUDIT REPORT: OmniBus PQ Signing Logic & TX Persistence

**Date**: 2026-05-05
**Scope**: `core/transaction.zig`, `core/pq_crypto.zig`, `core/database.zig`
**Status**: ✅ DONE — RESOLVED 2026-05-06. See `PQ_AUDIT_2026-05-06.md` and `PQ_AUDIT_2026-05-17.md` (0 drift). Stress test: 20/20 PQ TXs accepted on testnet VPS. Root cause was stale `stress-pq-matrix.mjs` hashing raw bytes + single SHA-256 instead of `buildTxHash`. All "CRITICAL" issues below are historical — kept for context only.

**Original status**: 3 CRITICAL ISSUES FOUND + FIXES PROVIDED

---

## A) CODE AUDIT — Signing Logic

### ✅ CORRECT (No Issues)

1. **Hash Calculation (lines 171-260)**
   - SHA256d (double SHA256) prevents replay attacks
   - Nonce included in hash prevents identical TX reuse
   - Scheme tag (lines 200-205) prevents scheme-swap attacks (ECDSA → PQ or vice versa)
   - Public key embedded (lines 207-210) prevents key substitution
   - All fields signed: fee, locktime, op_return, inputs, outputs

2. **ECDSA Sign/Verify (lines 333-371)**
   - Correct secp256k1 implementation
   - Proper hex encoding/decoding of signatures
   - Hash validation on verify path
   - Test coverage: "Transaction sign si verify — ECDSA secp256k1 REAL" (line 485) ✅

### ⚠️ CRITICAL BUG #1 — PQ Signature Format Mismatch

**Location**: `transaction.zig:395-421` (verifySignature for PQ schemes)

**Problem**: Function passes `self.signature` (hex-encoded string) directly to PQ `verify()` methods, but PQ verify expects raw bytes.

**Current Code (BROKEN)**:
```zig
.love_dilithium => {
    const pk = self.public_key;
    if (pk.len == 0) return false;
    var kp: pq_crypto.MlDsa87 = undefined;
    if (pk.len != pq_crypto.MlDsa87.PUBLIC_KEY_SIZE) return false;
    @memcpy(&kp.public_key, pk[0..pq_crypto.MlDsa87.PUBLIC_KEY_SIZE]);
    return kp.verify(&hash_bytes, self.signature);  // ❌ passing hex string!
},
```

**Why it breaks**:
- `self.signature` is stored as hex (ECDSA requirement: 128 chars for 64 bytes)
- PQ verify methods expect raw bytes (`[]const u8`)
- Passing hex bytes directly compares against wrong hash

**Fix** (see section C):
```zig
// Hex-decode before calling PQ verify
var sig_bytes: [4627]u8 = undefined;  // SIGNATURE_MAX from MlDsa87
const sig_len = try hex_utils.hexToBytes(self.signature, &sig_bytes);
return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
```

**Impact**: ⚠️ CRITICAL — All PQ transactions fail verification silently.

---

### ⚠️ CRITICAL BUG #2 — TX Persistence Missing

**Location**: `database.zig` and `blockchain.zig`

**Problem**: `TransactionIndex` stores only metadata (hash → block height), not actual TX data. When node restarts, blocks reload but TX payloads are lost.

**Root Cause**:
```zig
// database.zig line 89
transactions: TransactionIndex,  // Just location index, not full TX

// On save: blocks serialized, but not block.transactions[]
// On restore: blocks loaded, but transaction payloads missing
```

**Current Flow**:
```
TX created → mempool → block.transactions[] (RAM)
   ↓
applyBlock() updates balances
   ↓
Block header saved to chain.dat (hash, height, prev_hash, root)
   ↓
Node restart → blocks reload, TX[] empty
   ↓
roles dispar, balances may be inconsistent
```

**Why it matters**:
- Roles (validator, miner, agent) detected via op_return memo, stored in TX
- On restart, transaction list disappears → roles lost
- User-facing impact: wallet says "0 roles" after restart, even though TX was mined

**Impact**: 🔴 CRITICAL — Data loss on every restart.

---

### ⚠️ CRITICAL BUG #3 — No Mechanism to Recover PQ Keys

**Location**: `wallet.zig` (PQ key derivation)

**Problem**: PQ keys are non-deterministic (random nonce + SHAKE256 expansion). Restore from mnemonic only recovers ECDSA keys, loses PQ wallet funds forever.

**Current Situation**:
```zig
// PQ key generation = RANDOM SEED + expand
// No BIP-32-like derivation path
// Restore from mnemonic = only ECDSA addresses recover
```

**Impact**: 🔴 CRITICAL — User loses LOVE/FOOD/RENT/VACATION wallet on restart (non-deterministic keys).

---

## B) TEST STRATEGY

### Offline Verification Test (test-pq-signing.zig)

Tests all 4 PQ schemes + ECDSA for:

1. **Hash Determinism** — same TX = same hash every time
2. **Nonce Inclusion** — nonce+1 = different hash (replay prevention)
3. **Signing** — sign TX with private key
4. **Verification** — verify with public key (PASS)
5. **Wrong Key Rejection** — verify with different key (FAIL)
6. **Scheme Isolation** — swap scheme tag, signature breaks
7. **Public Key Binding** — swap public_key field, signature breaks

### Network Test (test-pq-broadcast.zig)

1. Create 5 addresses (OMNI + 4 PQ)
2. Sign TX with each
3. Broadcast to testnet seed node
4. Wait for mempool acceptance
5. Mine block
6. Verify TX included in block
7. Check roles persisted to chain.dat
8. Shutdown node
9. Restart node
10. Verify TX still in chain (persistence check)

---

## C) FIXES

### Fix 1: PQ Signature Hex→Bytes Decoding (IMMEDIATE)

**File**: `core/transaction.zig` line 376-421

Replace `verifySignature()` to decode hex signature before PQ verify:

```zig
pub fn verifySignature(self: *const Transaction, pubkey_hex: ?[]const u8) bool {
    // Hash check (common path)
    if (self.hash.len != 64) return false;
    var hash_bytes: [32]u8 = undefined;
    hex_utils.hexToBytes(self.hash, &hash_bytes) catch return false;
    const expected_hash = self.calculateHash();
    if (!std.mem.eql(u8, &hash_bytes, &expected_hash)) return false;

    return switch (self.scheme) {
        .omni_ecdsa => {
            const pk = pubkey_hex orelse return false;
            if (pk.len != 66) return false;
            var pk_bytes: [33]u8 = undefined;
            hex_utils.hexToBytes(pk, &pk_bytes) catch return false;
            if (self.signature.len != 128) return false;
            var sig_bytes: [64]u8 = undefined;
            hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
            return Secp256k1Crypto.verify(pk_bytes, &hash_bytes, sig_bytes);
        },
        .love_dilithium => {
            const pk = self.public_key;
            if (pk.len == 0) return false;
            var kp: pq_crypto.MlDsa87 = undefined;
            if (pk.len != pq_crypto.MlDsa87.PUBLIC_KEY_SIZE) return false;
            @memcpy(&kp.public_key, pk[0..pq_crypto.MlDsa87.PUBLIC_KEY_SIZE]);
            
            // FIX: Decode hex signature to bytes
            var sig_bytes: [pq_crypto.MlDsa87.SIGNATURE_MAX]u8 = undefined;
            const sig_len = hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
            return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
        },
        .food_falcon => {
            const pk = self.public_key;
            if (pk.len == 0) return false;
            var kp: pq_crypto.Falcon512 = undefined;
            if (pk.len != pq_crypto.Falcon512.PUBLIC_KEY_SIZE) return false;
            @memcpy(&kp.public_key, pk[0..pq_crypto.Falcon512.PUBLIC_KEY_SIZE]);
            
            // FIX: Decode hex signature to bytes
            var sig_bytes: [pq_crypto.Falcon512.SIGNATURE_MAX]u8 = undefined;
            const sig_len = hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
            return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
        },
        .rent_slh_dsa => {
            const pk = self.public_key;
            if (pk.len == 0) return false;
            var kp: pq_crypto.SlhDsa256s = undefined;
            if (pk.len != pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE) return false;
            @memcpy(&kp.public_key, pk[0..pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE]);
            
            // FIX: Decode hex signature to bytes
            var sig_bytes: [pq_crypto.SlhDsa256s.SIGNATURE_MAX]u8 = undefined;
            const sig_len = hex_utils.hexToBytes(self.signature, &sig_bytes) catch return false;
            return kp.verify(&hash_bytes, sig_bytes[0..sig_len]);
        },
        .vacation_kem => false,
    };
}
```

**Test**: `zig test core/transaction.zig` should pass all existing tests + new PQ tests.

---

### Fix 2: TX Persistence (Schema v2.1)

**File**: `core/database.zig` + `core/blockchain.zig`

**Step 1**: Add TX storage to Database

```zig
// database.zig — add new field
pub const Database = struct {
    transactions: TransactionIndex,
    transaction_payloads: std.AutoHashMap([32]u8, []const u8),  // hash → TX JSON
    txs_persisted_schema_v2_1: bool = false,  // Flag for DB version
```

**Step 2**: Save TX payloads on block apply

```zig
// blockchain.zig — in applyBlock()
// After block accepted:
for (block.transactions) |tx| {
    const tx_hash = try std.fmt.allocPrint(allocator, "{s}", .{tx.hash});
    const tx_json = try std.json.stringifyAlloc(allocator, tx, .{});
    try db.transaction_payloads.put(tx_hash, tx_json);
}
```

**Step 3**: Serialize/deserialize on save/load

```zig
// database.zig saveState() — append transaction payloads section
// database.zig loadState() — restore TX payloads
```

**Cost**: ~150 lines, <1MB per 10k blocks.

---

### Fix 3: PQ Deterministic Key Derivation (FUTURE)

**Issue**: PQ keys can't be recovered from mnemonic.

**Solution**: Use BIP-32-like tree with HMAC-SHA512:
```
Master seed (mnemonic)
  ├─ m/777/0  → OMNI ECDSA (secp256k1)
  ├─ m/778/0  → LOVE PQ (ML-DSA-87, deterministic from HMAC)
  ├─ m/779/0  → FOOD PQ (Falcon-512)
  ├─ m/780/0  → RENT PQ (SLH-DSA-256s)
  └─ m/781/0  → VACATION PQ (ML-KEM-768)
```

**Workaround (now)**: Vault stores all 5 mnemonic-uri, derives keys deterministically per restart.

---

## D) TESTING CHECKLIST

- [ ] **PQ Hex/Bytes Fix**: Run `zig test core/transaction.zig` — all tests pass
- [ ] **Manual Test**: Create TX with obk1_ address, sign, verify locally
- [ ] **Broadcast Test**: Send TX with memo (op_return) to testnet
- [ ] **Persistence Test**: Mine block, shutdown, restart, verify TX in `getblock` RPC
- [ ] **Role Persistence**: Send `stake: <amount>` memo, check roles persisted after restart
- [ ] **All 4 Schemes**: Test with obk1_, obf5_, obd5_, obs3_ addresses
- [ ] **Cross-Scheme Rejection**: Sign with obk1_, try to verify as obf5_ → should fail

---

## E) DEPLOYEMENT CHECKLIST

1. **Hotfix Priority**: Fix #1 (hex/bytes) — blocks all PQ validation
2. **Deploy**: Merge to BlockChainCore, rebuild binary
3. **Post-Deploy**: Run circuit_v4_bidirectional.py to verify 4 schemes work
4. **Long-term**: Implement Fixes #2 (TX persistence) + #3 (deterministic PQ keys)

---

## FILES TO MODIFY

1. `core/transaction.zig:376-421` — verifySignature() hex decoding
2. `core/database.zig:89` — add transaction_payloads field
3. `core/blockchain.zig:applyBlock()` — call saveTxs()
4. NEW: `test/test-pq-signing.zig` — comprehensive test suite
5. NEW: `test/test-pq-persistence.zig` — broadcast + restart test

---

## NEXT STEPS

1. Apply Fix #1 immediately (5 min)
2. Write test-pq-signing.zig (30 min)
3. Run circuit test to verify all 4 schemes (10 min)
4. Plan Fixes #2 + #3 for next phase

**ETA to Fix #1 deployed**: 45 minutes  
**ETA to Fix #2 + #3**: 1-2 hours

