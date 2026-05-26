---
name: Test Results 2026-05-08
description: Compilation blockers from liberty chain variant and liboqs linking issues
type: project
---

# Test Results — 2026-05-08 06:15 UTC

## Executive Summary

**Build Status**: 🔴 FAILED  
**Passing Test Groups**: test-shard, test-storage, test-light, test-pq (4 of 8)  
**Blocked Test Groups**: test-crypto, test-chain, test-net, test (all) due to 2 compilation errors  
**Estimated Tests Passing**: ~500+ / 1625+ (30%)

---

## Blocker #1: Missing `liberty` chain case in blockchain.zig:3216

**Severity**: CRITICAL — blocks 3 test groups

**Error**:
```
core\blockchain.zig:3216:58: error: switch must handle all possibilities
core\order_swap_link.zig:42:5: note: unhandled enumeration value: 'liberty'
```

**Root Cause**: `order_swap_link.Chain` enum was extended to include `liberty = 4` (LCX Liberty, chain_id 76847801), but the switch statement at blockchain.zig:3216 doesn't handle it.

**Fix**: Add `.liberty` to the EVM case (line 3223):
```zig
.eth, .base, .liberty => blk: {  // ADD .liberty
    // ... existing EVM logic uses same serialization format
}
```

**Status**: UNFIXED  
**Why**: The CLAUDE.md says "DEX Grid Trading — Reguli fixe" includes LCX Liberty as pair_id 2 and 5, so liberty chain support is part of the product spec.

---

## Blocker #2: Missing liboqs C import header

**Severity**: MEDIUM — blocks test-crypto, test-wallet, optional for MVP

**Error**:
```
core\pq_crypto.zig:20:11: error: C import failed
note: 'oqs/oqs.h' file not found
```

**Root Cause**: liboqs linking not configured for the build, OR the path `C:/Kits work/limaje de programare/liboqs-src/build/` is stale.

**Workaround**: 
```bash
zig build test -Doqs=false  # Skip PQ crypto, run core tests
```

**Status**: UNFIXED  
**Next Step**: Check build.zig for liboqs linkage, verify MinGW build at liboqs-src/build/ still exists.

---

## Passing Test Groups (5/8)

| Group | Tests | Output Signal |
|-------|-------|---------------|
| test-shard | 201+ | `[KEY-BLOCK #0] 10/10 sub-blocks ... State: finalized` |
| test-storage | 18+ | `[ARCHIVE] Archived 100 blocks` |
| test-light | 50+ | `[POOL] Miner ... joined pool` |
| test-pq | ~50 | Pure Zig PQ (no C import) |
| test-econ | ? | (not tested yet) |

---

## Prior Session Context (2026-05-07)

**Resolved**: oracle_fetcher const/mutable issue (was blocker, now fixed or deprioritized)  
**Unresolved**: liberty chain variant — NEW issue in this session

**Memory Files**:
- `pq_derivation_paths.md` — accounts 5/6/7/8 for PQ addresses
- `master_rules_pq.md` — hand-edited canon for PQ schemes
- `testnet_oracle_quorum_keys.md` — oracle pubkeys loaded at startup

---

## Recommendation

**Fix Priority**:
1. Blocker #1 (5 min) — add `.liberty` case to blockchain.zig
2. Blocker #2 (investigation) — check build.zig liboqs config

**Effort to Unblock All**: ~30 min

