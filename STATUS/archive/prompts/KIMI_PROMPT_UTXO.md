# Prompt for Kimi — Switch OmniBus L1 from RAM-cached balances to UTXO source-of-truth

Copy everything below the `---` line into Kimi (or any external LLM)
verbatim. Paste back the resulting Zig diff here for review.

---

## ROLE

You are a senior Zig systems engineer reviewing and patching an L1
blockchain codebase written in Zig 0.15.2. The chain is called
**OmniBus**. Your task is to convert balance reads from a RAM cache
(`bc.balances`, a `StringHashMap`) to be sourced from the existing
on-chain UTXO set (`bc.utxo_set`), in two distinct phases.

You will produce two patch series:

  **Phase B (immediate, low-risk):** keep `bc.balances` as a hot cache
  but make every external balance read go through the UTXO set. RAM
  cache becomes a write-only mirror, never read by RPC / P2P / wallet
  code. Add an audit assertion that compares the two paths in debug
  builds and logs divergence in release builds.

  **Phase C (later, full Bitcoin model):** delete `bc.balances` entirely.
  All balance and nonce data lives in chainstate. Aligned with the
  Bitcoin-style storage refactor spec already in the repo at
  `ARCH_BITCOIN_STORAGE.md`.

This document covers Phase B + Phase C. Implement Phase B fully now;
Phase C as a design + migration strategy only.

## EXISTING CODE (relevant snippets)

### `core/blockchain.zig` (excerpts)

```zig
pub const Blockchain = struct {
    chain: array_list.Managed(Block),
    mempool: array_list.Managed(Transaction),
    difficulty: u32,
    cumulative_work: u128 = 0,
    validator_set: std.array_list.Managed(Validator),
    allocator: std.mem.Allocator,
    /// Balantele adreselor (in-memory, sincronizat cu database)
    balances: std.StringHashMap(u64),
    /// Nonce tracking per adresa
    nonces: std.StringHashMap(u64),
    /// Public key registry: address → compressed pubkey hex
    pubkey_registry: std.StringHashMap([]const u8),
    /// TX hash → block height
    tx_block_height: std.StringHashMap(u64),
    /// Address TX index for getaddresshistory
    address_tx_index: std.StringHashMap(std.ArrayList([]const u8)),
    /// UTXO set — tracks all unspent transaction outputs (Bitcoin-compatible)
    utxo_set: utxo_mod.UTXOSet,
    mutex: std.Thread.Mutex = .{},
    persistent_db: ?*@import("database.zig").PersistentBlockchain = null,
    db_path: []const u8 = "omnibus-chain.dat",
    // ... oracle prices, bridge state, etc. omitted

    pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
        return self.balances.get(address) orelse 0;          // ← RAM-only read
    }

    /// Apply a validated block to the chain.
    /// Caller must hold mutex.
    fn applyBlock(self: *Blockchain, block: Block) !void {
        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            self.debitBalanceLocked(tx.from_address, tx.amount + tx.fee) catch {};
            self.creditBalanceLocked(tx.to_address, tx.amount) catch {};
            total_fees += tx.fee;
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
            self.tx_block_height.put(tx.hash, @intCast(block.index)) catch {};
            self.indexAddressTx(tx.from_address, tx.hash);
            self.indexAddressTx(tx.to_address, tx.hash);
        }
        const fees_burned = total_fees * FEE_BURN_PCT / 100;
        const fees_to_miner = total_fees - fees_burned;
        if (block.miner_address.len > 0 and (block.reward_sat > 0 or fees_to_miner > 0)) {
            self.creditBalanceLocked(block.miner_address, block.reward_sat + fees_to_miner) catch {};
        }
        try self.chain.append(block);
        // ... cumulative_work, retarget, etc.
    }
};
```

### `core/utxo.zig` (excerpts — already implemented, currently
maintained but underused)

```zig
pub const UTXO = struct {
    tx_hash: []const u8,
    output_index: u32,
    address: []const u8,
    amount: u64,
    block_height: u64,
    script_pubkey: []const u8,
    is_coinbase: bool,

    pub fn isMature(self: *const UTXO, current_height: u64) bool {
        if (!self.is_coinbase) return true;
        return current_height >= self.block_height + 100;
    }
};

pub const UTXOSet = struct {
    utxos: std.StringHashMap(UTXO),                 // outpoint → UTXO
    address_index: std.StringHashMap(std.ArrayList([]const u8)),  // addr → outpoints
    allocator: std.mem.Allocator,
    count: u64,
    total_value: u64,

    pub fn addUTXO(self: *UTXOSet, tx_hash: []const u8, output_index: u32,
                   address: []const u8, amount: u64, block_height: u64,
                   script_pubkey: []const u8, is_coinbase: bool) !void { ... }

    pub fn spendUTXO(self: *UTXOSet, tx_hash: []const u8, output_index: u32) !UTXO { ... }

    pub fn getBalance(self: *const UTXOSet, address: []const u8) u64 {
        const outpoints = self.getUTXOsForAddress(address);
        var total: u64 = 0;
        for (outpoints) |outpoint| {
            if (self.utxos.get(outpoint)) |utxo| total += utxo.amount;
        }
        return total;
    }
    // selectUTXOs, hasUTXO, getUTXO etc. all present
};
```

### Where UTXO is currently populated (line numbers approximate)

```zig
// core/blockchain.zig, in applyBlock or a helper called by applyBlock:

// Regular TX outputs:
self.utxo_set.addUTXO(tx.hash, @intCast(tx_idx), tx.to_address,
                      tx.amount, @intCast(index), "", false);

// Coinbase / block reward (one virtual output per block):
self.utxo_set.addUTXO(block.hash, 0, miner_address,
                      reward + fees_to_miner, @intCast(index), "", true);
```

So the UTXO set already mirrors every confirmed credit. What's missing:

1. UTXOs from inputs are **not** spent — `spendUTXO` is implemented
   but never called from `applyBlock`. Instead `bc.balances` is
   debited directly. UTXOSet therefore only grows; balances drift
   from the UTXO sum after the first transfer.

2. `getAddressBalance` reads `bc.balances` rather than
   `utxo_set.getBalance`.

3. No audit / divergence detector exists.

## THE BUG WE'RE FIXING

`bc.balances` has no contract that ties it to chain state. Anything
that writes to it directly (without going through `applyBlock` →
proper TX handling) creates a phantom balance that vanishes on
the next replay-from-scratch.

We just lost 51 of 54 testnet faucet recipient balances at restart
because the faucet RPC writes `bc.balances` directly without emitting
a chain TX. Replay rebuilt only what was on chain → faucet grants
gone. (See `ARCH_BITCOIN_STORAGE.md` for the full incident write-up.)

The narrow fix in this prompt is **not** to make faucet emit TXs (that's
a separate RPC change). It's to make sure that when a phantom write
happens again, the rich list, RPC, and wallet UI **see only what's
actually on chain** — i.e. UTXO sums, not the divergent RAM cache.

## OMNIBUS-SPECIFIC CONSTRAINTS

1. **No external dependencies.** Everything stays pure Zig + std.
   `liboqs` is the only C dep already present (PQ crypto, irrelevant
   here). No LevelDB, no RocksDB, no JSON parser pulls.

2. **Account model on-chain wire format.** Block transactions today
   have one `from_address` → one `to_address` + amount + fee. They
   don't yet carry vin/vout vectors. Phase B keeps this; Phase C
   designs the migration.

3. **Mining loop holds `bc.mutex`** during `applyBlock`. UTXO writes
   inside `applyBlock` are already serialised by that mutex; reads
   from RPC handlers that take `bc.mutex` for snapshot are also safe.
   Don't introduce a second mutex in UTXOSet.

4. **Coinbase maturity = 100 blocks.** Mature-balance vs total-balance
   becomes a real distinction in Phase B. The existing
   `getAddressBalance` returns the total; the new path should return
   total too for compatibility, but expose a separate
   `getMatureBalance(addr, current_height)` for callers that care.

5. **Tests** live as `test "name" { ... }` blocks in each `core/*.zig`.
   `zig build test` and `zig build test-chain` are the relevant
   targets. Keep tests inline.

6. **Zig 0.15.2 specifics:** `std.array_list.Managed(T)` is the right
   list type in this codebase. `std.StringHashMap` is the right map.
   Use `.empty` for empty `ArrayList`, `init(allocator)` for HashMaps.

7. **Mutex semantics:** `bc.mutex.lock(); defer bc.mutex.unlock();`
   pattern. Public methods that need the lock take it; internal
   `*Locked` variants assume the caller holds it.

## PHASE B — DELIVERABLE

A single patch series with these changes:

### B.1 — Make `applyBlock` spend the inputs

In `applyBlock`, before crediting `tx.to_address`, locate the input
UTXOs for `tx.from_address` covering `tx.amount + tx.fee` and spend
them. Today balances are debited but UTXOs aren't.

The current TX wire format doesn't carry explicit vin pointers, so
use `selectUTXOs(from_address, total_needed, height, allocator)` to
pick the inputs greedily, then call `spendUTXO` on each picked
outpoint. If the total selected exceeds the spend, the coin-selection
implicit "change output" goes back to `from_address` — record it as
a synthetic UTXO with `tx_hash = tx.hash` and `output_index = 1`
(while the real `to_address` UTXO is at `output_index = 0`).

This keeps the on-chain semantics unchanged but makes the UTXO set
exactly track the truth. Coinbase is already correctly handled.

### B.2 — Switch `getAddressBalance` to UTXO source

```zig
pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
    return self.utxo_set.getBalance(address);
}
```

Add a sibling that exposes the mature-only view:

```zig
pub fn getMatureBalance(self: *const Blockchain, address: []const u8) u64 {
    const current_height = if (self.chain.items.len == 0) 0
                          else @as(u64, @intCast(self.chain.items.len - 1));
    const outpoints = self.utxo_set.getUTXOsForAddress(address);
    var total: u64 = 0;
    for (outpoints) |op| {
        if (self.utxo_set.utxos.get(op)) |utxo| {
            if (utxo.isMature(current_height)) total += utxo.amount;
        }
    }
    return total;
}
```

`bc.balances` stays in place as a hot cache, written by
`applyBlock` exactly as before, but **no caller reads it from outside
`applyBlock`**. Audit grep should turn up zero non-replay reads after
this patch.

### B.3 — Audit assertion

```zig
/// Walk every address in bc.balances and compare against utxo_set.getBalance.
/// Returns the number of addresses where the two paths disagree. In a
/// healthy chain this is always 0. Used by tests + an optional periodic
/// debug print from the mining loop.
pub fn auditBalanceConsistency(self: *const Blockchain) struct {
    addresses_checked: usize,
    divergences: usize,
} {
    var checked: usize = 0;
    var diverged: usize = 0;
    var it = self.balances.iterator();
    while (it.next()) |kv| {
        checked += 1;
        const ram = kv.value_ptr.*;
        const utxo = self.utxo_set.getBalance(kv.key_ptr.*);
        if (ram != utxo) {
            diverged += 1;
            std.debug.print(
                "[AUDIT-DIVERGE] addr={s} ram={d} utxo={d}\n",
                .{ kv.key_ptr.*, ram, utxo },
            );
        }
    }
    return .{ .addresses_checked = checked, .divergences = diverged };
}
```

Hook this into the existing stabilizer tick (in `main.zig`'s mining
loop) so it runs once per minute. If `divergences > 0`, emit a single
ALERT line.

### B.4 — Tests

Add to `core/blockchain.zig` (inline test blocks):

  - "applyBlock spends sender UTXOs and creates recipient UTXO":
    Build a chain with a coinbase to A, then a TX A→B for half;
    assert `utxo_set.count == 2` (B's output + A's change),
    `getAddressBalance(A)` == half via UTXO, `getAddressBalance(B)` ==
    half via UTXO.

  - "auditBalanceConsistency returns 0 divergences after normal
    applyBlock": same chain as above, assert `auditBalanceConsistency`
    finds zero divergences.

  - "auditBalanceConsistency catches phantom RAM credit":
    manually call `bc.balances.put(addr, 999)` outside applyBlock;
    assert audit returns `divergences == 1` and the printed line names
    that address.

  - "getMatureBalance excludes immature coinbase":
    coinbase to A at height 5; before height 105, mature balance of A
    is 0; at height ≥ 105, mature balance == coinbase reward.

### B.5 — RPC propagation

`getrichlist` and `getaddressbalance` should already work after B.2
(they call `bc.getAddressBalance`). Spot-check `core/rpc_server.zig`
for any direct read of `ctx.bc.balances` and replace with the helper.
If nothing reads it directly, leave the file alone.

## PHASE C — DESIGN ONLY

Specify (don't implement) the migration plan:

1. **Wire format change:** transactions gain explicit `inputs: []Outpoint`
   and `outputs: []TxOutput`. Sender's wallet picks UTXOs ahead of
   signing, includes them in the TX, signs the whole thing. The
   `from_address` field becomes derivable rather than carried separately
   (every input's address must agree, otherwise the TX is malformed).

2. **bc.balances removal:** every write callsite either
   (a) becomes a `applyBlock` path that goes through utxo_set, or
   (b) becomes an explicit "this is not consensus state" tag for any
   diagnostic counter we want to keep.

3. **Persistence:** chainstate KV (per `ARCH_BITCOIN_STORAGE.md`) holds
   the UTXO set on disk. Restart = open chainstate → instant balance
   for any address, no replay needed for balance queries. Replay still
   used for `-reindex` and integrity checks.

4. **Backwards compat:** old block format readable indefinitely;
   migration emits new-format equivalents on upgrade and stores both
   for one release cycle.

5. **Wallet impact:** Bitcoin-style coin selection becomes mandatory
   in the signing flow. Light clients and the franchise Python client
   need a UTXO query method (already have `getUTXOsForAddress` in
   utxo.zig — just expose via RPC).

Provide:

  - A list of every callsite in the current codebase that writes
    `bc.balances` directly (use grep on `balances.put`,
    `balances.getOrPut`, `creditBalanceLocked`, `debitBalanceLocked`).
    For each, classify: keep / move-to-applyBlock / delete.

  - A migration sequence with rollback notes for each step.

  - Estimated LoC + effort per phase.

## DELIVERABLES (what you give back)

For Phase B:

  - One `core/blockchain.zig` patch (use unified diff format).
  - One `core/rpc_server.zig` patch if any direct read of
    `ctx.bc.balances` exists; otherwise note "no change required".
  - One `core/main.zig` patch hooking `auditBalanceConsistency` into
    the stabilizer tick (every 60 s), single line ALERT on divergence.
  - All four inline tests added to `core/blockchain.zig`.
  - A short note (≤ 200 words) confirming you grepped for non-replay
    reads of `bc.balances` and either patched them or that none exist.

For Phase C:

  - The callsite classification table.
  - The migration sequence + rollback notes.
  - LoC + effort estimate.
  - **No code.** Design only.

## GROUND RULES

  - Don't refactor unrelated code. Keep the diff minimal.
  - Don't introduce new dependencies.
  - Don't change wire formats in Phase B.
  - Don't drop tests; expand them.
  - Don't paper over `divergences > 0` — surface it loudly.
  - Don't loosen the mutex; all UTXO mutation continues to require
    `bc.mutex` held.

If anything in this prompt is ambiguous, state your assumption inline
in the patch comments and move on. Don't ask clarifying questions
back; produce the diff.
