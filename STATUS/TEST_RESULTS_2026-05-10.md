# Test Results — 2026-05-10

## Summary

| Test Group | Status | Blockers | Root Cause |
|-----------|--------|----------|-----------|
| zig build test (all) | FAIL | 2 critical | Switch exhaustiveness + liboqs |
| test-crypto | FAIL | 1 critical | liboqs C import missing |
| test-chain | FAIL | 1 critical | Switch in blockchain.zig |
| test-net | FAIL | 1 critical | Cascaded by blockchain.zig |
| test-shard | FAIL | 1 critical | Blocked by blockchain.zig |

---

## CRITICAL: blockchain.zig Line 3225 - Missing liberty chain case

**File:** core/blockchain.zig:3225  
**Related:** core/order_swap_link.zig:37-42

### Problem

The switch statement on taker_chain only handles .btc, .eth, .base, and .omnibus.
But order_swap_link.Chain enum has a new value: .liberty = 4

Error output:
```
error: switch must handle all possibilities
const taker_ref: swap_link_mod.HtlcRef = switch (taker_chain) {
note: unhandled enumeration value: 'liberty'
```

### Root Cause

order_swap_link.Chain enum was extended with Liberty chain (chain_id 76847801), 
but blockchain.zig switch at line 3225 does not handle it. Zig requires all enum 
values to be handled in exhaustive switches.

### Fix

Change blockchain.zig line 3232:
```
OLD: .eth, .base => blk: {
NEW: .eth, .base, .liberty => blk: {
```

This is correct because liberty is EVM-compatible (like eth and base), using:
- chain_id (u64)
- contract address (20 bytes)  
- HTLC id hash (32 bytes)

### Impact

- Blocks ALL test groups (blockchain.zig is a transitive dependency)
- Once fixed: expect 2000+ tests to pass
- Will reveal cascading failures (liboqs C import, ASN.1 cache issues)

---

## SECONDARY: pq_crypto.zig - liboqs C import fails

**Severity:** Blocker for test-crypto
**File:** core/pq_crypto.zig:20

Error: 'oqs/oqs.h' file not found during C import

Expected behavior: test suite runs with -Doqs=false by default to skip PQ features.
Should resolve once blockchain.zig is fixed.

---

## TERTIARY: Zig compiler "Unexpected" errors

Multiple modules fail with generic "Unexpected" errors. Typical causes:
- Zig cache corruption (.zig-cache/)
- Windows file locking issues
- Cascading failures due to blockchain.zig blocking the entire import chain

Fix after blockchain.zig:
```
rm -r .zig-cache
zig build clean
zig build test
```

---

## Immediate Action Required

1. Fix blockchain.zig:3232 (add .liberty to switch)
   Estimated time: 1 minute

2. Run: zig build test
   Should show 2000+ passing tests

3. Address any remaining failures

---

## Last Known Good State

- Date: 2026-05-07 03:01 UTC
- Status: 283/283 tests passed
- Change since: liberty chain added to order_swap_link.Chain enum
