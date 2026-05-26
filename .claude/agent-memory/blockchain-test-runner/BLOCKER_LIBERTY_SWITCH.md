---
name: Blocker — .liberty missing in blockchain.zig switch
description: Switch statement in blockchain.zig:3223 must handle all Chain enum variants including .liberty
type: feedback
---

## Rule
**Exhaustive switch statements in Zig must handle ALL enum variants.** When `order_swap_link.Chain` enum changes (esp. adding `.liberty`), ALL switch statements that pattern-match on `Chain` must be updated immediately, or the build fails.

## Why
Zig enforces exhaustive pattern matching at compile time — this is a feature, not a bug. If you add a new enum variant but miss a switch case, the compiler catches it before tests run. This prevents runtime bugs in DEX HTLC logic (wrong chain type → wrong preimage encoding → failed swaps).

## How to apply
1. When adding a new `Chain` enum variant to `core/order_swap_link.zig`, grep for all switch statements on `Chain`:
   ```bash
   grep -n "switch.*taker_chain\|switch.*maker_chain\|switch.*self.*chain" core/*.zig
   ```
2. For each match, check if the switch handles the new variant:
   - **EVM-compatible chains** (eth, base, liberty) → group them in the same case and use the EVM HtlcRef encoding
   - **Non-EVM chains** (btc, omnibus) → separate cases
3. Update `blockchain.zig:3223` specifically: `.eth, .base => ` becomes `.eth, .base, .liberty => `
4. Re-run `zig build test` to verify exhaustiveness.

## Context
- File: `core/blockchain.zig` line 3216–3236 (HTLC roundtrip logic in applyBlock)
- Enum: `order_swap_link.Chain` (currently: omnibus=0, btc=1, eth=2, base=3, liberty=4)
- Affected tests: blockchain.zig tests + transitive (e2e_mining, node_launcher, sync, p2p, genesis)
