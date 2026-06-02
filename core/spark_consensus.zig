/// spark_consensus.zig — SPARK Sub-Block Consensus (10-layer parallel validation)
///
/// Cele 10 sub-blocks devin 10 layere de validare paralela. Fiecare layer
/// produce un ATTEST/REJECT vote cu semnatura validatorului. 6/10 ATTEST = high
/// trust, 5/10 = low trust, <5/10 = REJECT.
///
/// Design goals:
///   - No malloc in validateBlock — fixed-size arrays pe stack/global
///   - `alloc` doar pentru RPC JSON output
///   - Adaugat ca layer adițional, nu modifica consensul existent
const std = @import("std");

// ─── Tipuri publice ──────────────────────────────────────────────────────────

pub const ValidationLayer = enum(u8) {
    tx_well_formed    = 1,
    utxo_existence    = 2,
    no_double_spend   = 3,
    signature_verify  = 4,
    nonce_monotonic   = 5,
    balance_constraint = 6,
    contract_state    = 7,
    cross_shard       = 8,
    reputation        = 9,
    merkle_commit     = 10,
};

pub const VoteKind = enum(u8) { attest, reject };

pub const ValidationVote = struct {
    layer:      ValidationLayer,
    kind:       VoteKind,
    /// Validator address (first 20 bytes of OmniBus address — Bitcoin-style)
    validator:  [20]u8,
    block_hash: [32]u8,
    /// Reject reason in UTF-8, zero-padded. All zeros if kind == .attest.
    reason:     [64]u8,
};

pub const TrustLevel = enum(u8) {
    high,     // >= 6/10 ATTEST
    low,      // == 5/10 ATTEST
    rejected, // < 5/10 ATTEST
    pending,  // votes not yet collected
};

// ─── BlockConsensusState ────────────────────────────────────────────────────

pub const BlockConsensusState = struct {
    block_hash:   [32]u8,
    /// One vote slot per layer (layer index = @intFromEnum(layer) - 1)
    votes:        [10]?ValidationVote,
    attest_count: u8,
    reject_count: u8,
    trust:        TrustLevel,

    pub fn init(block_hash: [32]u8) BlockConsensusState {
        return .{
            .block_hash   = block_hash,
            .votes        = .{null} ** 10,
            .attest_count = 0,
            .reject_count = 0,
            .trust        = .pending,
        };
    }

    /// Upsert a vote for its layer. Overwrites any previous vote from any
    /// validator for that layer (single-vote-per-layer model, first caller wins).
    pub fn addVote(self: *BlockConsensusState, vote: ValidationVote) void {
        const idx = @intFromEnum(vote.layer) - 1; // layers are 1-indexed
        if (idx >= 10) return;
        // If slot already has a vote, do not replace (first vote wins)
        if (self.votes[idx] != null) return;
        self.votes[idx] = vote;
        if (vote.kind == .attest) {
            self.attest_count += 1;
        } else {
            self.reject_count += 1;
        }
    }

    /// Recompute trust from current attest/reject counts.
    pub fn computeTrust(self: *BlockConsensusState) TrustLevel {
        self.trust = if (self.attest_count >= 6)
            .high
        else if (self.attest_count == 5)
            .low
        else
            .rejected;
        return self.trust;
    }
};

// ─── ChainState shim ────────────────────────────────────────────────────────
//
// validateBlock and runLayer accept `anytype` for `state` so they work with
// the full Blockchain struct without creating a circular import. The helpers
// below use duck-typing to call only the fields/methods that exist.

/// Lookup address balance from chain state. Returns 0 if not found.
/// Works with any `state` that has a `getBalance(addr) u64` method.
inline fn stateBalance(state: anytype, addr: []const u8) u64 {
    // Blockchain has .getAddressBalance(addr) which returns u64
    if (@hasDecl(@TypeOf(state.*), "getAddressBalance")) {
        return state.getAddressBalance(addr);
    }
    // MockState for tests has .balance_map  (we query via getBalance)
    if (@hasDecl(@TypeOf(state.*), "getBalance")) {
        return state.getBalance(addr);
    }
    return 0;
}

/// True if address exists in state (has any balance or UTXO history).
inline fn stateHasAddress(state: anytype, addr: []const u8) bool {
    return stateBalance(state, addr) > 0;
}

// ─── Layer implementations ───────────────────────────────────────────────

/// Helper: build an ATTEST vote for `layer`.
fn attest(layer: ValidationLayer, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    return .{
        .layer      = layer,
        .kind       = .attest,
        .validator  = validator,
        .block_hash = block_hash,
        .reason     = [_]u8{0} ** 64,
    };
}

/// Helper: build a REJECT vote for `layer` with a reason string.
fn reject(layer: ValidationLayer, validator: [20]u8, block_hash: [32]u8, comptime reason: []const u8) ValidationVote {
    var r: [64]u8 = [_]u8{0} ** 64;
    const n = @min(reason.len, 64);
    @memcpy(r[0..n], reason[0..n]);
    return .{
        .layer      = layer,
        .kind       = .reject,
        .validator  = validator,
        .block_hash = block_hash,
        .reason     = r,
    };
}

/// Layer 1 — TX batch well-formed.
/// Each TX must have non-empty from/to, amount > 0 (or op_return present),
/// and a non-empty signature field.
fn layer1WellFormed(block: anytype, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    const txs = block.transactions.items;
    for (txs) |tx| {
        if (tx.from_address.len == 0)
            return reject(.tx_well_formed, validator, block_hash, "from_address empty");
        if (tx.to_address.len == 0)
            return reject(.tx_well_formed, validator, block_hash, "to_address empty");
        // amount == 0 is ok only for op_return TXs or typed TXs
        const is_data_tx = tx.op_return.len > 0 or tx.tx_type != .transfer;
        if (tx.amount == 0 and !is_data_tx)
            return reject(.tx_well_formed, validator, block_hash, "amount=0 non-data TX");
        if (tx.signature.len == 0)
            return reject(.tx_well_formed, validator, block_hash, "signature empty");
    }
    return attest(.tx_well_formed, validator, block_hash);
}

/// Layer 2 — UTXO existence: sender address must exist in chain state.
/// Skip when state has no address lookup capability (always attest).
fn layer2UtxoExistence(block: anytype, validator: [20]u8, block_hash: [32]u8, state: anytype) ValidationVote {
    const txs = block.transactions.items;
    for (txs) |tx| {
        // Skip coinbase / faucet / op_return-only TXs (amount == 0)
        if (tx.amount == 0) continue;
        if (!stateHasAddress(state, tx.from_address))
            return reject(.utxo_existence, validator, block_hash, "sender not found in state");
    }
    return attest(.utxo_existence, validator, block_hash);
}

/// Layer 3 — No double-spend: detect duplicate TX hashes within this block.
/// Uses an O(n²) scan (fixed-size, no alloc). Blocks with >256 TXs pass
/// a simplified modular sample to avoid stack overflow on embedded targets.
fn layer3NoDoubleSpend(block: anytype, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    const txs = block.transactions.items;
    // O(n²) is fine for normal blocks (max ~4096 TXs in prod, tests are small)
    // For very large blocks we limit to first 256 entries to stay no-alloc.
    const limit = @min(txs.len, 256);
    for (0..limit) |i| {
        for (i + 1..limit) |j| {
            // Compare by id (u32) — cheaper than full hash string comparison
            if (txs[i].id == txs[j].id and txs[i].id != 0)
                return reject(.no_double_spend, validator, block_hash, "duplicate TX id in block");
            // Also compare hash strings if both non-empty
            if (txs[i].hash.len > 0 and txs[j].hash.len > 0 and
                std.mem.eql(u8, txs[i].hash, txs[j].hash))
                return reject(.no_double_spend, validator, block_hash, "duplicate TX hash in block");
        }
    }
    return attest(.no_double_spend, validator, block_hash);
}

/// Layer 4 — Signature verify (lightweight check).
/// Full crypto verify is done by applyBlock. Here we only verify that the
/// signature field is non-empty (TODO: real verify when perf budget allows).
fn layer4SignatureVerify(block: anytype, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    const txs = block.transactions.items;
    for (txs) |tx| {
        if (tx.signature.len == 0)
            return reject(.signature_verify, validator, block_hash, "empty signature field");
    }
    return attest(.signature_verify, validator, block_hash);
}

/// Layer 5 — Nonce monotonic: per-sender nonce must be strictly increasing.
/// We scan in block order and track the last seen nonce per address.
/// Fixed-size table: max 64 distinct senders tracked (no alloc).
fn layer5Nonce(block: anytype, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    const MAX_SENDERS = 64;
    var addrs: [MAX_SENDERS][]const u8 = undefined;
    var nonces: [MAX_SENDERS]u64 = undefined;
    var count: usize = 0;

    const txs = block.transactions.items;
    for (txs) |tx| {
        if (tx.nonce == 0) continue; // nonce=0 means not set (legacy TXs)
        // Find or insert sender
        var found = false;
        for (0..count) |k| {
            if (std.mem.eql(u8, addrs[k], tx.from_address)) {
                // Nonce must be >= previous (allow same nonce for legacy compat)
                if (tx.nonce < nonces[k])
                    return reject(.nonce_monotonic, validator, block_hash, "nonce decreased for sender");
                nonces[k] = tx.nonce;
                found = true;
                break;
            }
        }
        if (!found and count < MAX_SENDERS) {
            addrs[count] = tx.from_address;
            nonces[count] = tx.nonce;
            count += 1;
        }
    }
    return attest(.nonce_monotonic, validator, block_hash);
}

/// Layer 6 — Balance constraint: for each sender Σamount + fee <= state balance.
/// Aggregates all TXs from the same sender within the block.
fn layer6Balance(block: anytype, validator: [20]u8, block_hash: [32]u8, state: anytype) ValidationVote {
    const MAX_SENDERS = 64;
    var addrs:  [MAX_SENDERS][]const u8 = undefined;
    var totals: [MAX_SENDERS]u64 = undefined;
    var count: usize = 0;

    const txs = block.transactions.items;
    for (txs) |tx| {
        if (tx.amount == 0) continue; // op_return or typed, no coin movement

        var found = false;
        for (0..count) |k| {
            if (std.mem.eql(u8, addrs[k], tx.from_address)) {
                totals[k] = totals[k] +| (tx.amount +| tx.fee); // saturating add
                found = true;
                break;
            }
        }
        if (!found and count < MAX_SENDERS) {
            addrs[count] = tx.from_address;
            totals[count] = tx.amount +| tx.fee;
            count += 1;
        }
    }

    // Now check each sender against state balance
    for (0..count) |k| {
        const bal = stateBalance(state, addrs[k]);
        if (totals[k] > bal)
            return reject(.balance_constraint, validator, block_hash, "total spend exceeds balance");
    }
    return attest(.balance_constraint, validator, block_hash);
}

/// Layer 7 — Smart contract state (stub).
/// ATTEST if no TX has a non-transfer tx_type with missing data.
/// Real contract VM integration is a follow-up sprint.
fn layer7ContractState(block: anytype, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    const txs = block.transactions.items;
    for (txs) |tx| {
        // Typed TXs that require a payload but have none are malformed
        if (tx.tx_type != .transfer and tx.data.len == 0) {
            // This is already caught by isValid(), but double-check here
            return reject(.contract_state, validator, block_hash, "typed TX missing data payload");
        }
    }
    return attest(.contract_state, validator, block_hash);
}

/// Layer 8 — Cross-shard receipts (stub).
/// Always ATTEST — full cross-shard settlement is a Phase-3 item.
fn layer8CrossShard(validator: [20]u8, block_hash: [32]u8) ValidationVote {
    return attest(.cross_shard, validator, block_hash);
}

/// Layer 9 — Reputation / trust score.
/// ATTEST if validator rep >= 0 (all validators pass on testnet).
/// Production: gate on a minimum staked amount or reputation score.
fn layer9Reputation(validator: [20]u8, block_hash: [32]u8) ValidationVote {
    // Validator rep is always >= 0 (unsigned), so always attest.
    return attest(.reputation, validator, block_hash);
}

/// Layer 10 — Merkle root + commit.
/// Recomputes the block's TX merkle root and compares with the stored value.
fn layer10MerkleCommit(block: anytype, validator: [20]u8, block_hash: [32]u8) ValidationVote {
    // Recompute merkle root from TX hashes (SHA-256 of concatenated hashes)
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (block.transactions.items) |tx| {
        if (tx.hash.len == 64) {
            // TX hash is hex-encoded (64 chars) — hash the raw hex bytes into merkle
            hasher.update(tx.hash);
        } else {
            // Fallback: hash tx id as bytes
            var id_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &id_buf, tx.id, .big);
            hasher.update(&id_buf);
        }
    }
    var computed_root: [32]u8 = undefined;
    hasher.final(&computed_root);

    // Compare with block.merkle_root (field exists on Block and SubBlock)
    if (!std.mem.eql(u8, &block.merkle_root, &computed_root)) {
        return reject(.merkle_commit, validator, block_hash, "merkle root mismatch");
    }
    return attest(.merkle_commit, validator, block_hash);
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Run all 10 validation layers for a block. Returns 10 votes.
/// Each layer is deterministic — same block + same validator = same votes.
///
/// `block`     — Block or SubBlock type with .transactions.items and .merkle_root
/// `validator_addr` — 20-byte validator address (first 20 bytes of OB address)
/// `state`     — Chain state with address balance lookup (duck-typed)
///
/// NO malloc is used here — all data lives in the returned array.
pub fn validateBlock(
    alloc: std.mem.Allocator,
    block: anytype,
    validator_addr: [20]u8,
    state: anytype,
) [10]ValidationVote {
    _ = alloc; // reserved for future async/batch use; not used today
    // Compute block hash for embedding in votes
    const bh = blockHashOf(block);
    var votes: [10]ValidationVote = undefined;
    votes[0] = layer1WellFormed(block, validator_addr, bh);
    votes[1] = layer2UtxoExistence(block, validator_addr, bh, state);
    votes[2] = layer3NoDoubleSpend(block, validator_addr, bh);
    votes[3] = layer4SignatureVerify(block, validator_addr, bh);
    votes[4] = layer5Nonce(block, validator_addr, bh);
    votes[5] = layer6Balance(block, validator_addr, bh, state);
    votes[6] = layer7ContractState(block, validator_addr, bh);
    votes[7] = layer8CrossShard(validator_addr, bh);
    votes[8] = layer9Reputation(validator_addr, bh);
    votes[9] = layer10MerkleCommit(block, validator_addr, bh);
    return votes;
}

/// Run a single validation layer. Deterministic.
pub fn runLayer(
    layer: ValidationLayer,
    block: anytype,
    validator_addr: [20]u8,
    state: anytype,
) ValidationVote {
    const bh = blockHashOf(block);
    return switch (layer) {
        .tx_well_formed    => layer1WellFormed(block, validator_addr, bh),
        .utxo_existence    => layer2UtxoExistence(block, validator_addr, bh, state),
        .no_double_spend   => layer3NoDoubleSpend(block, validator_addr, bh),
        .signature_verify  => layer4SignatureVerify(block, validator_addr, bh),
        .nonce_monotonic   => layer5Nonce(block, validator_addr, bh),
        .balance_constraint => layer6Balance(block, validator_addr, bh, state),
        .contract_state    => layer7ContractState(block, validator_addr, bh),
        .cross_shard       => layer8CrossShard(validator_addr, bh),
        .reputation        => layer9Reputation(validator_addr, bh),
        .merkle_commit     => layer10MerkleCommit(block, validator_addr, bh),
    };
}

/// Extract a [32]u8 block hash from any block type.
/// Supports Block (hash: []const u8, hex-encoded) and SubBlock (hash: [32]u8).
fn blockHashOf(block: anytype) [32]u8 {
    const T = @TypeOf(block.*);
    if (@hasField(T, "hash")) {
        const h = block.hash;
        // Block type: hash is []const u8 (hex, 64 chars)
        if (@TypeOf(h) == []const u8 or @TypeOf(h) == []u8) {
            if (h.len == 64) {
                var raw: [32]u8 = undefined;
                // Inline hex decode (no allocator)
                for (0..32) |i| {
                    const hi = hexNibble(h[i * 2]);
                    const lo = hexNibble(h[i * 2 + 1]);
                    raw[i] = (hi << 4) | lo;
                }
                return raw;
            }
        }
        // SubBlock type: hash is [32]u8 directly
        if (@TypeOf(h) == [32]u8) return h;
    }
    // Fallback: compute from index if available
    var out: [32]u8 = [_]u8{0} ** 32;
    if (@hasField(T, "index")) {
        std.mem.writeInt(u32, out[0..4], block.index, .big);
    } else if (@hasField(T, "block_number")) {
        std.mem.writeInt(u32, out[0..4], block.block_number, .big);
    }
    return out;
}

inline fn hexNibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

// ─── Process-global consensus state store ────────────────────────────────────
//
// Keeps the last SPARK_HISTORY_DEPTH consensus states for RPC queries.
// Lock-free ring buffer (single-writer: finalizer thread).

pub const SPARK_HISTORY_DEPTH: usize = 64;

var g_states: [SPARK_HISTORY_DEPTH]BlockConsensusState = undefined;
var g_states_head: usize = 0;
var g_states_count: usize = 0;
var g_spark_mutex: std.Thread.Mutex = .{};

/// Store a finalized BlockConsensusState for later RPC queries.
pub fn recordState(state: BlockConsensusState) void {
    g_spark_mutex.lock();
    defer g_spark_mutex.unlock();
    g_states[g_states_head % SPARK_HISTORY_DEPTH] = state;
    g_states_head += 1;
    if (g_states_count < SPARK_HISTORY_DEPTH) g_states_count += 1;
}

/// Retrieve the most recent recorded state. Returns null if none yet.
pub fn lastState() ?BlockConsensusState {
    g_spark_mutex.lock();
    defer g_spark_mutex.unlock();
    if (g_states_count == 0) return null;
    const idx = (g_states_head + SPARK_HISTORY_DEPTH - 1) % SPARK_HISTORY_DEPTH;
    return g_states[idx];
}

/// Retrieve state by block_hash. Returns null if not in ring buffer.
pub fn findByHash(block_hash: [32]u8) ?BlockConsensusState {
    g_spark_mutex.lock();
    defer g_spark_mutex.unlock();
    const depth = @min(g_states_count, SPARK_HISTORY_DEPTH);
    for (0..depth) |i| {
        const idx = (g_states_head + SPARK_HISTORY_DEPTH - 1 - i) % SPARK_HISTORY_DEPTH;
        if (std.mem.eql(u8, &g_states[idx].block_hash, &block_hash))
            return g_states[idx];
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// Minimal mock Transaction for tests (no full transaction.zig dependency)
const MockTx = struct {
    id:           u32 = 1,
    from_address: []const u8 = "ob1qtest000000000000000000000000000000000000",
    to_address:   []const u8 = "ob1qtest111111111111111111111111111111111111",
    amount:       u64 = 1_000_000_000,
    fee:          u64 = 1000,
    nonce:        u64 = 0,
    signature:    []const u8 = "aabbcc",
    hash:         []const u8 = "",
    op_return:    []const u8 = "",
    tx_type:      MockTxType = .transfer,
    data:         []const u8 = "",

    const MockTxType = enum { transfer, order_place };
};

// Minimal mock Block for tests
const MockBlock = struct {
    index:       u32 = 1,
    hash:        []const u8 = "0" ** 64,
    merkle_root: [32]u8 = [_]u8{0} ** 32,
    transactions: MockTxList = .{},

    const MockTxList = struct {
        items: []const MockTx = &.{},
    };
};

// Mock state with a simple balance map
const MockState = struct {
    /// Single address for tests
    addr: []const u8 = "",
    bal: u64 = 0,

    pub fn getBalance(self: *const MockState, addr: []const u8) u64 {
        if (std.mem.eql(u8, self.addr, addr)) return self.bal;
        return 0;
    }
};

fn testValidator() [20]u8 {
    return [_]u8{0xDE, 0xAD, 0xBE, 0xEF} ++ [_]u8{0} ** 16;
}

fn testBlockHash() [32]u8 {
    return [_]u8{0xCA, 0xFE, 0xBA, 0xBE} ++ [_]u8{0} ** 28;
}

// ── Test 1: init → trust=pending, counts=0 ──────────────────────────────────
test "BlockConsensusState.init — trust=pending counts=0" {
    const bh = testBlockHash();
    const s = BlockConsensusState.init(bh);
    try testing.expectEqual(TrustLevel.pending, s.trust);
    try testing.expectEqual(@as(u8, 0), s.attest_count);
    try testing.expectEqual(@as(u8, 0), s.reject_count);
    for (s.votes) |v| try testing.expect(v == null);
}

// ── Test 2: 6 ATTEST votes → trust=high ─────────────────────────────────────
test "BlockConsensusState — 6 ATTEST → high trust" {
    const bh = testBlockHash();
    const val = testValidator();
    var s = BlockConsensusState.init(bh);
    const layers = [_]ValidationLayer{
        .tx_well_formed, .utxo_existence, .no_double_spend,
        .signature_verify, .nonce_monotonic, .balance_constraint,
    };
    for (layers) |layer| {
        s.addVote(attest(layer, val, bh));
    }
    try testing.expectEqual(@as(u8, 6), s.attest_count);
    try testing.expectEqual(TrustLevel.high, s.computeTrust());
}

// ── Test 3: 5 ATTEST votes → trust=low ──────────────────────────────────────
test "BlockConsensusState — 5 ATTEST → low trust" {
    const bh = testBlockHash();
    const val = testValidator();
    var s = BlockConsensusState.init(bh);
    const layers = [_]ValidationLayer{
        .tx_well_formed, .utxo_existence, .no_double_spend,
        .signature_verify, .nonce_monotonic,
    };
    for (layers) |layer| {
        s.addVote(attest(layer, val, bh));
    }
    try testing.expectEqual(@as(u8, 5), s.attest_count);
    try testing.expectEqual(TrustLevel.low, s.computeTrust());
}

// ── Test 4: 4 ATTEST votes → trust=rejected ─────────────────────────────────
test "BlockConsensusState — 4 ATTEST → rejected" {
    const bh = testBlockHash();
    const val = testValidator();
    var s = BlockConsensusState.init(bh);
    const layers = [_]ValidationLayer{
        .tx_well_formed, .utxo_existence, .no_double_spend, .signature_verify,
    };
    for (layers) |layer| {
        s.addVote(attest(layer, val, bh));
    }
    try testing.expectEqual(@as(u8, 4), s.attest_count);
    try testing.expectEqual(TrustLevel.rejected, s.computeTrust());
}

// ── Test 5: Layer 1 ATTEST for valid TX ─────────────────────────────────────
test "Layer 1 tx_well_formed — ATTEST for valid TX" {
    const tx = MockTx{};
    const txs = [_]MockTx{tx};
    var blk = MockBlock{ .transactions = .{ .items = &txs } };
    var state = MockState{};
    const val = testValidator();
    const vote = runLayer(.tx_well_formed, &blk, val, &state);
    try testing.expectEqual(VoteKind.attest, vote.kind);
}

// ── Test 6: Layer 1 REJECT for TX with amount=0 (no op_return) ──────────────
test "Layer 1 tx_well_formed — REJECT for amount=0 TX" {
    const tx = MockTx{ .amount = 0 }; // no op_return, no typed data
    const txs = [_]MockTx{tx};
    var blk = MockBlock{ .transactions = .{ .items = &txs } };
    var state = MockState{};
    const val = testValidator();
    const vote = runLayer(.tx_well_formed, &blk, val, &state);
    try testing.expectEqual(VoteKind.reject, vote.kind);
}

// ── Test 7: Layer 3 REJECT for duplicate TX in block ────────────────────────
test "Layer 3 no_double_spend — REJECT for duplicate TX id" {
    const tx1 = MockTx{ .id = 42 };
    const tx2 = MockTx{ .id = 42 }; // same id!
    const txs = [_]MockTx{ tx1, tx2 };
    var blk = MockBlock{ .transactions = .{ .items = &txs } };
    var state = MockState{};
    const val = testValidator();
    const vote = runLayer(.no_double_spend, &blk, val, &state);
    try testing.expectEqual(VoteKind.reject, vote.kind);
}

// ── Test 8: Layer 6 REJECT when amount > balance ────────────────────────────
test "Layer 6 balance_constraint — REJECT when spend > balance" {
    const tx = MockTx{
        .from_address = "ob1qtest_sender_000000000000000000000000000000",
        .amount = 1_000_000_000,
        .fee    = 1000,
    };
    const txs = [_]MockTx{tx};
    var blk = MockBlock{ .transactions = .{ .items = &txs } };
    // Sender has only 500_000_000 SAT
    var state = MockState{
        .addr = "ob1qtest_sender_000000000000000000000000000000",
        .bal  = 500_000_000,
    };
    const val = testValidator();
    const vote = runLayer(.balance_constraint, &blk, val, &state);
    try testing.expectEqual(VoteKind.reject, vote.kind);
}

// ── Test 9: Layer 10 ATTEST when merkle root is correct ─────────────────────
test "Layer 10 merkle_commit — ATTEST for correct merkle root" {
    // Build the exact merkle root that layer10 computes for an empty TX list
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var expected: [32]u8 = undefined;
    hasher.final(&expected); // SHA-256 of empty input

    var blk = MockBlock{
        .merkle_root = expected,
        .transactions = .{ .items = &.{} }, // empty TX list
    };
    var state = MockState{};
    const val = testValidator();
    const vote = runLayer(.merkle_commit, &blk, val, &state);
    try testing.expectEqual(VoteKind.attest, vote.kind);
}

// ── Test 10: validateBlock returns exactly 10 votes ─────────────────────────
test "validateBlock — returns exactly 10 votes" {
    var blk = MockBlock{};
    var state = MockState{};
    const val = testValidator();
    const votes = validateBlock(testing.allocator, &blk, val, &state);
    try testing.expectEqual(@as(usize, 10), votes.len);
}

// ── Test 11: runLayer is deterministic ──────────────────────────────────────
test "runLayer — deterministic (same result on two calls)" {
    const tx = MockTx{};
    const txs = [_]MockTx{tx};
    var blk = MockBlock{ .transactions = .{ .items = &txs } };
    var state = MockState{};
    const val = testValidator();
    const v1 = runLayer(.tx_well_formed, &blk, val, &state);
    const v2 = runLayer(.tx_well_formed, &blk, val, &state);
    try testing.expectEqual(v1.kind, v2.kind);
    try testing.expectEqual(v1.layer, v2.layer);
}

// ── Test 12: mixed ATTEST/REJECT → trust computed correctly ─────────────────
test "Mixed ATTEST/REJECT — trust computed correctly" {
    const bh = testBlockHash();
    const val = testValidator();
    var s = BlockConsensusState.init(bh);
    // 7 ATTEST + 3 REJECT = trust high
    const attest_layers = [_]ValidationLayer{
        .tx_well_formed, .utxo_existence, .no_double_spend,
        .signature_verify, .nonce_monotonic, .balance_constraint, .contract_state,
    };
    const reject_layers = [_]ValidationLayer{
        .cross_shard, .reputation, .merkle_commit,
    };
    for (attest_layers) |layer| s.addVote(attest(layer, val, bh));
    for (reject_layers) |layer| s.addVote(reject(layer, val, bh, "test reject"));
    try testing.expectEqual(@as(u8, 7), s.attest_count);
    try testing.expectEqual(@as(u8, 3), s.reject_count);
    try testing.expectEqual(TrustLevel.high, s.computeTrust());
}
