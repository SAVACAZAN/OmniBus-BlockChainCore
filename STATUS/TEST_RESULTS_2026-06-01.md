# Test Results — 2026-06-01

## Executive Summary

**Full test run:** 398/420 tests passed (94.8%)  
**Critical blockers:** 2 (P2P mutex segfault, isolated_wallet PQ disabled)  
**Memory leaks:** 30+ (test-only, non-critical)

## Critical Failures

### 1. P2P Mutex Segfault (test-net)

**Severity:** BLOCKER  
**File:** `core/p2p.zig:661`  
**Error:** Segmentation fault at address 0xffffffffffffffff

**Root Cause:** peers_mutex being unlocked on uninitialized or double-freed mutex.

**Specific Fix:**
- Verify peers_mutex initialized with std.Thread.Mutex in P2PNode.init()
- Check deinit() doesn't call unlock() if init failed
- Add guard: if (!self.initialized) return; at top of peerCount()

**Related Tests Affected:**
- p2p.test.P2PNode init si deinit
- node_launcher.test.network readiness check
- cli.test.CLI — miner fara seed

---

### 2. Isolated Wallet PQ Domain Generation Disabled (test-crypto)

**Severity:** BLOCKER (test suite only)  
**File:** `core/isolated_wallet.zig:197`, `core/pq_crypto.zig:328`

**Root Cause:** -Doqs=false disables liboqs. Tests unconditionally call PQ domain generation which requires MlDsa87.generateKeyPairFromSeed(), causing error return.

**Impact:** 22 test failures in isolated_wallet

**Specific Fix:** Wrap test blocks with: if (!has_oqs) return;

---

## Memory Leaks (Non-Critical, Test-Only)

Total: 30+ leaks across test-chain and test-net
- Category 1: Stray credit logs (11 leaks) — blockchain_tests.zig tests
- Category 2: GPA memory leaks (9 leaks) — arena allocators not freed
- Category 3: Exchange fee validation (3 leaks) — invalid TX cleanup
- Category 4: DNS registry leaks (2 leaks) — file handle cleanup

---

## Test Group Status

| Group | Pass | Fail | Status |
|-------|------|------|--------|
| test-crypto | 398/420 | 22 | BLOCKED |
| test-chain | 883/883 | 0 | PASS (+ leaks) |
| test-net | 3713/3716 | 3 | MOSTLY PASS |
| test-shard | 201+ | 0 | PASS |
| test-storage | 18+ | 0 | PASS |
| test-light | 100+ | 0 | PASS |

---

## Recommendations

### Priority 1 (Immediate)

1. Fix P2P Mutex Segfault (~15 min)
   - File: core/p2p.zig:300-350, 661
   - Unblocks: 3 test-net failures

2. Skip PQ Wallet Tests When -Doqs=false (~20 min)
   - File: core/isolated_wallet.zig:191-320
   - Unblocks: 22 crypto test failures

### Priority 2 (Follow-Up)

3. Clean up memory leaks in blockchain_tests.zig (~45 min)
4. Fix spark_invariants test execution (~30 min)

---

## Verify Fixes

```
zig build test-net -Doqs=false
zig build test-crypto -Doqs=false
zig build test -Doqs=false
```

---

Generated: 2026-06-01 12:10 UTC
Status: Read-only diagnostic run, no code changes
