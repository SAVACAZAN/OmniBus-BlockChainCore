# Security Audit Report - 2026-05-22

**Auditor**: blockchain-security-auditor (13th pass)
**Scope**: OmniBus-BlockChainCore core/*.zig | **Status**: Read-only

## Fix Verification

| SEV | Description | Verdict |
|-----|-------------|----------|
| SEV-42 | PQ-OMNI verifySignature=>true (transaction.zig:642) | STILL OPEN |
| SEV-50 | State trie non-deterministic root | STILL OPEN |
| SEV-41 | removeGuardian no auth | STILL OPEN |
| SEV-43 | fills_root missing from block hash | STILL OPEN |
| SEV-01 | Bearer token timing (rpc_server.zig:7819) | STILL OPEN |
| SEV-04 | verifyPassword stub (key_encryption.zig:165) | STILL OPEN |
| SEV-P2P-4GB | P2P 4GB OOM | FIXED: 1MB cap at p2p.zig:585 |
| SEV-23 | grid_cancel no-auth | CONFIRMED FIXED |

## New Findings

### SEV-66 (HIGH): grid_create Owner Not Authenticated
- File: core/rpc_server.zig:14590, core/grid_engine.zig:116
- handleGridCreate reads owner from JSON-RPC with no sig verify. Any peer impersonates any address.
- Exploit: 256 grid_create calls with owner=victim exhaust MAX_GRIDS and inject 51200 ghost orders.
- Fix: Require signature+publicKey. Verify secp256k1.verify. Mirror rpc_server.zig:5082-5086.

### SEV-67 (MEDIUM): Grid price*amount u64 Overflow
- File: core/grid_engine.zig:406,430,446,470
- amount_quote = sell_p * amount_base / 1_000_000. Both u64. Product can hit 10^25, overflows silently.
- Exploit: Extreme price_high grid fills at high price; amount_quote wraps near-zero; attacker gets OMNI for free.
- Fix: const amount_quote: u64 = @intCast(@as(u128, sell_p) * @as(u128, amount_base) / 1_000_000);

### SEV-68 (MEDIUM): Varint decodeU64 Shift Wraps
- File: core/binary_codec.zig:32,36,40
- shift: u6 wraps mod 64 after 10 continuation bytes. Corrupted decode instead of error.
- Exploit: Crafted varint with 15 continuation bytes causes misaligned P2P compact block parsing.
- Fix: if (bytes_read >= 10) return error.VarintTooLong; declare shift: u7; check shift >= 64.

### SEV-69 (MEDIUM): Self-Trade Saturates Oracle Price Feed
- File: core/matching_engine.zig:6,402-407,456-460
- Self-trade allowed. No per-address fill rate limit. One address saturates MAX_FILLS=1000 with fake trades.
- Exploit: Alice self-trades 999x/block, controls prices_root oracle median.
- Fix: Max 100 fills/address/block. Oracle requires 3+ distinct counterparty addresses.

### SEV-70 (HIGH): Governance vote() Caller-Supplied Power + Overflow
- File: core/governance.zig:201-219
- vote() accepts voting_power: u64 with no staked balance check. maxInt(u64) overflows votes_yes.
- Exploit: votes_yes wraps to 0, quorum_needed = 0, any proposal force-approved.
- Fix: Look up staked balance. Use try std.math.add(u64, proposal.votes_yes, voting_power).

### SEV-71 (HIGH): verifyPassword Stub
- File: core/key_encryption.zig:165-168
- Code: return password.len >= 8 and password.len <= 128; (ignores password_hash entirely)
- Exploit: Any 8-char password re-encrypts private key under attacker choice.
- Fix: Store salt. test_hash = sha256(password || stored_salt). return constantTimeEql.

### SEV-72 (HIGH): constantTimeEql Not Wired Into isAuthorized
- File: core/rpc_server.zig:7819
- constantTimeEql at :7790 (comment: Kimi BUG_14). isAuthorized still uses std.mem.eql.
- Exploit: Timing oracle recovers bearer token byte-by-byte in O(256*len) requests.
- Fix: return std.mem.eql(u8, got, token); => return constantTimeEql(got, token);

### SEV-73 (MEDIUM): grid tick() No Per-Block Rate Limit
- File: core/grid_engine.zig:383-480
- No last_tick_block guard. 10 sub-blocks = 10 fills/block per grid. 256 grids = 2560 HTLC bindings.
- Exploit: Exhausts MAX_SWAPS in ~0.4 blocks.
- Fix: Add last_tick_block: u64 = 0 to GridConfig. Skip if already ticked this block.

### SEV-74 (MEDIUM): lockTaker No Maker-Locked Guard
- File: core/order_swap_link.zig:278-283
- lockTaker transitions to .both_locked without verifying maker_locked flag. settle() then succeeds.
- Exploit: Attacker (taker) skips lockMaker, calls lockTaker+settle, claims HTLC with zero maker funding.
- Fix: maker_locked: bool = false in SwapBinding. lockMaker sets it true. lockTaker checks it.

---

## Open Tracker (2026-05-22)

2 CRITICAL | 17 HIGH | 10 MEDIUM | 1 LOW = 30 total open

CRITICAL: SEV-42 (transaction.zig:642), SEV-50 (state_trie.zig:96)

HIGH: SEV-01/72, SEV-04/71, SEV-24, SEV-26, SEV-28, SEV-29, SEV-30/70, SEV-31, SEV-33, SEV-41, SEV-43, SEV-44, SEV-45, SEV-47/57, SEV-58, SEV-60, SEV-61, SEV-66 (NEW)

MEDIUM: SEV-09, SEV-14, SEV-48, SEV-55, SEV-62, SEV-63, SEV-64/68 (NEW), SEV-67 (NEW), SEV-69 (NEW), SEV-73 (NEW), SEV-74 (NEW)

LOW: SEV-65

FIXED this cycle: SEV-P2P-4GB
Previously fixed: SEV-02, SEV-03, SEV-20, SEV-23, SEV-52, SEV-CRIT-01, SEV-CRIT-02

---

## Priority Fix List

1. SEV-42: Remove catch-all true arm in transaction.zig:641-642. Implement ML-DSA-87/Falcon/SLH-DSA verify.
2. SEV-50: Sort state_trie accounts by address before hashing. Fixes non-deterministic root.
3. SEV-72: rpc_server.zig:7819 - one char change: mem.eql => constantTimeEql.
4. SEV-43: block.zig:~175 - add hasher.update(&self.fills_root); after prices_root.
5. SEV-66: grid_create requires signature+publicKey. Verify secp256k1. Mirror rpc_server.zig:5082-5086.
