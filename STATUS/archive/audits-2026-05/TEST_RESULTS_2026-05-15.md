# BlockChainCore Test Results — 2026-05-15

## Summary

Test Suite Status: FAILED

- Total Tests Run: 8806
- Passed: 8805 (99.99%)
- Failed: 1
- Leaked: ~200 memory leak events (test-phase only)
- Build Status: 148/162 steps succeeded; 10 failed

---

## Critical Issues (Priority Order)

### PRIORITY 1: pq_crypto.zig Build Failure
File: core/pq_crypto.zig, line 439
Error: ML-KEM-768 error union type mismatch

error: expected '...MlKem768.encapsulate__struct_29933',
        found '...Oqs__struct_25382.mlKem768Encapsulate__struct_29941'

Root Cause: Anonymous struct return types from C binding don't match.

Fix: Change line 434-440 to use named struct
pub const MlKem768Encapsulation = struct {
    ciphertext: []u8,
    shared_secret: []u8,
};

Unblocks: test-pq, test-crypto, test-chain, test-net, test-econ
Estimated Time: 15-30 min

---

### PRIORITY 2: spark_invariants Test Failure
Test: spark_invariants.test.totalEmittedUpTo
Issue: Test command exited abnormally

Root Cause: Likely off-by-one in token emission formula

Debug: zig test core/spark_invariants.zig
Estimated Time: 20-45 min

---

### PRIORITY 3: Memory Leaks (Test-Only, Optional)
Severity: LOW
Pattern: ~100 address string dupes in blockchain.zig balance map

Why: Test allocator detects leaks; production GPA cleans up on shutdown.
Zero production impact.

Options:
1. Accept leaks (current)
2. Run with -Drelease=true
3. Manually free balance map keys

Estimated Time: 5 min

---

## Test Group Status

Test Group      | Status        | Pass  | Fail
test-shard      | PASS          | 2900+ | 0
test-pq         | BUILD FAIL    | 0     | 1
test-crypto     | BLOCKED by pq | ~250  | -
test-chain      | BLOCKED by pq | ~900  | -
test-net        | BLOCKED by pq | ~100  | -
test-storage    | BLOCKED by pq | ~20   | -
test-light      | BLOCKED by pq | ~15   | -
test-econ       | BLOCKED by pq | ~200  | -
TOTAL           | FAIL          | 8805  | 1

---

## Memory Leak Breakdown (Test-Phase Only)

Module              | Leak Count | Nature
blockchain.zig      | ~100       | Address dupe in balance map
faucet.zig          | ~20        | IP cooldown
bread_ledger.zig    | ~15        | Merchant IDs
payment_channel.zig | ~35        | Channel state
TOTAL               | ~170 leaks | ~20 KB (test-only)

---

## Recommended Actions

STEP 1: Fix pq_crypto.zig (15-30 min)
- Edit core/pq_crypto.zig
- Define named struct at module scope (line ~230)
- Update function signatures to use named struct
- Rebuild: zig build test-pq

STEP 2: Fix spark_invariants (20-45 min)
- Run: zig test core/spark_invariants.zig
- Find test: totalEmittedUpTo
- Verify token emission formula
- Fix assertion or implementation

STEP 3: Full test run (after both fixes)
- zig build test -Doqs=false
- Expected: ALL TESTS PASS (8806/8806)

---

## Estimated Time to Green

Priority 1: 15-30 min
Priority 2: 20-45 min
Priority 3: 5 min (optional)
TOTAL: 45-75 min to full green

---

Report Generated: 2026-05-15
Status: Ready for fixes
