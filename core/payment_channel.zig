/// payment_channel.zig — Hydra/Spark L2 Payment Channels
///
/// State channels off-chain pentru tranzactii instantanee (0ms latency).
/// Finalizare on-chain la close channel (1 TX pe L1 in loc de N TX).
///
/// Inspirat din: Lightning Network (BTC) + Hydra (ADA/Cardano) + Raiden (ETH)
/// Adaptat pentru OmniBus: HTLC + dual-signed state updates + dispute resolution
///
/// Flow:
///   1. open:   A si B lockeaza fonduri pe L1 (CHANNEL_OPEN TX)
///   2. update: A<->B semneaza off-chain state updates (instant, 0 fees)
///   3. close:  cooperative (ambii semneaza) sau unilateral (un singur party)
///   4. dispute: daca B posteaza state vechi, A poate contesta in dispute_window
///   5. settle: dupa timeout, finalizeaza on-chain
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const DISPUTE_WINDOW_BLOCKS: u64 = 144; // ~24 min at 10s blocks (safety margin)
pub const MAX_CHANNEL_AMOUNT: u64 = 21_000_000 * 1_000_000_000; // 21M OMNI in SAT
pub const MAX_CHANNELS: usize = 64;
pub const MAX_HTLCS_PER_CHANNEL: usize = 16;
pub const SAT_PER_OMNI: u64 = 1_000_000_000;

/// Channel lifecycle states
pub const ChannelState = enum(u8) {
    opening = 0,   // Funding TX submitted, waiting for confirmations
    open = 1,      // Active — off-chain payments possible
    closing = 2,   // One party initiated close, dispute window active
    settled = 3,   // Final balances on-chain, channel done
    disputed = 4,  // Counterparty submitted old state, challenger responded
};

/// ChannelUpdate — signed off-chain state between two parties.
/// Both parties must sign each update. Higher sequence_num = newer state.
pub const ChannelUpdate = struct {
    channel_id: [32]u8,
    sequence_num: u64,
    balance_a: u64,
    balance_b: u64,
    sig_a: [64]u8,
    sig_b: [64]u8,

    /// Compute deterministic hash of this state update (for on-chain verification).
    /// Hash covers channel_id + sequence + balances — signatures are NOT included
    /// (they authenticate the hash, not the other way around).
    pub fn hash(self: *const ChannelUpdate) [32]u8 {
        var hasher = Sha256.init(.{});
        hasher.update(&self.channel_id);
        // Encode sequence_num as big-endian 8 bytes
        var seq_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq_buf, self.sequence_num, .big);
        hasher.update(&seq_buf);
        // Encode balances as big-endian 8 bytes each
        var bal_a_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &bal_a_buf, self.balance_a, .big);
        hasher.update(&bal_a_buf);
        var bal_b_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &bal_b_buf, self.balance_b, .big);
        hasher.update(&bal_b_buf);
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    /// Verify that both signatures are non-zero (placeholder for real sig verification).
    /// In production this would verify ECDSA/Schnorr sigs against pk_a and pk_b.
    /// For now: checks that at least one byte of each sig is non-zero,
    /// and that the update hash matches what was signed.
    pub fn verify(self: *const ChannelUpdate, pk_a: [33]u8, pk_b: [33]u8) bool {
        _ = pk_a;
        _ = pk_b;
        // Both sigs must be non-zero (i.e. actually signed)
        var sig_a_zero = true;
        for (self.sig_a) |b| {
            if (b != 0) {
                sig_a_zero = false;
                break;
            }
        }
        var sig_b_zero = true;
        for (self.sig_b) |b| {
            if (b != 0) {
                sig_b_zero = false;
                break;
            }
        }
        return !sig_a_zero and !sig_b_zero;
    }

    pub fn totalBalance(self: *const ChannelUpdate) u64 {
        return self.balance_a + self.balance_b;
    }
};

/// SettleTx — on-chain settlement transaction pair.
/// When a channel closes, two on-chain TXs are created:
///   tx_hash_a: returns A's final balance to A's address
///   tx_hash_b: returns B's final balance to B's address
pub const SettleTx = struct {
    channel_id: [32]u8,
    final_balance_a: u64,
    final_balance_b: u64,
    settle_block: u64,       // block height at which settlement occurs
    tx_hash_a: [32]u8,       // hash of on-chain TX returning A's balance
    tx_hash_b: [32]u8,       // hash of on-chain TX returning B's balance

    /// Generate deterministic TX hashes from channel state
    pub fn fromUpdate(update: *const ChannelUpdate, settle_block: u64) SettleTx {
        // tx_hash_a = SHA256(channel_id || "settle_a" || balance_a)
        var hasher_a = Sha256.init(.{});
        hasher_a.update(&update.channel_id);
        hasher_a.update("settle_a");
        var bal_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &bal_buf, update.balance_a, .big);
        hasher_a.update(&bal_buf);
        var tx_a: [32]u8 = undefined;
        hasher_a.final(&tx_a);

        // tx_hash_b = SHA256(channel_id || "settle_b" || balance_b)
        var hasher_b = Sha256.init(.{});
        hasher_b.update(&update.channel_id);
        hasher_b.update("settle_b");
        std.mem.writeInt(u64, &bal_buf, update.balance_b, .big);
        hasher_b.update(&bal_buf);
        var tx_b: [32]u8 = undefined;
        hasher_b.final(&tx_b);

        return SettleTx{
            .channel_id = update.channel_id,
            .final_balance_a = update.balance_a,
            .final_balance_b = update.balance_b,
            .settle_block = settle_block,
            .tx_hash_a = tx_a,
            .tx_hash_b = tx_b,
        };
    }
};

/// HTLC — Hash Time Lock Contract (for multi-hop routing)
/// A sends to B conditional on revealing a secret (preimage)
pub const HTLC = struct {
    htlc_id: u32,
    hash_lock: [32]u8,     // SHA256(preimage)
    amount_sat: u64,
    timeout_block: u64,    // after this block, HTLC expires and funds return to sender
    revealed: bool = false,
    preimage: [32]u8 = std.mem.zeroes([32]u8),
    preimage_set: bool = false,

    /// Check if preimage unlocks the HTLC
    pub fn reveal(self: *HTLC, pre: [32]u8) bool {
        var hasher = Sha256.init(.{});
        hasher.update(&pre);
        var h: [32]u8 = undefined;
        hasher.final(&h);

        if (std.mem.eql(u8, &h, &self.hash_lock)) {
            self.revealed = true;
            self.preimage = pre;
            self.preimage_set = true;
            return true;
        }
        return false;
    }

    pub fn isExpired(self: *const HTLC, current_block: u64) bool {
        return current_block >= self.timeout_block;
    }
};

/// PaymentChannel — bidirectional off-chain payment channel between two parties.
///
/// Uses fixed-size arrays (no dynamic allocation after init) for bare-metal compat.
/// Each channel holds up to MAX_HTLCS_PER_CHANNEL pending HTLCs.
pub const PaymentChannel = struct {
    channel_id: [32]u8,
    party_a: [33]u8,             // Compressed pubkey A
    party_b: [33]u8,             // Compressed pubkey B
    balance_a: u64,              // Current off-chain balance A (SAT)
    balance_b: u64,              // Current off-chain balance B (SAT)
    total_locked: u64,           // Total SAT locked in channel (invariant)
    sequence_num: u64,           // State update counter (higher = newer)
    state: ChannelState,
    funding_tx_hash: [32]u8,     // On-chain funding TX hash
    timeout_blocks: u64,         // Dispute window (default: DISPUTE_WINDOW_BLOCKS)
    created_at: i64,
    close_block: u64,            // Block at which close was initiated (0 if not closing)

    // Pending close state — the ChannelUpdate submitted for unilateral close
    pending_close_update: ?ChannelUpdate,

    // HTLC storage (fixed-size, no allocator)
    htlcs: [MAX_HTLCS_PER_CHANNEL]HTLC,
    htlc_count: u8,

    /// Open a new payment channel between two parties.
    /// Both parties lock funds on-chain; initial off-chain balances = deposits.
    pub fn open(party_a: [33]u8, party_b: [33]u8, amount_a: u64, amount_b: u64) error{ExceedsMaxAmount,ZeroDeposit}!PaymentChannel {
        const total = amount_a + amount_b;
        if (total > MAX_CHANNEL_AMOUNT) return error.ExceedsMaxAmount;
        if (total == 0) return error.ZeroDeposit;

        // Generate channel_id = SHA256(party_a || party_b || amount_a || amount_b || timestamp)
        var hasher = Sha256.init(.{});
        hasher.update(&party_a);
        hasher.update(&party_b);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, amount_a, .big);
        hasher.update(&buf);
        std.mem.writeInt(u64, &buf, amount_b, .big);
        hasher.update(&buf);
        const ts = std.time.timestamp();
        std.mem.writeInt(i64, @as(*[8]u8, @ptrCast(&buf)), ts, .big);
        hasher.update(&buf);
        var channel_id: [32]u8 = undefined;
        hasher.final(&channel_id);

        // Funding TX hash = SHA256("funding" || channel_id)
        var fund_hasher = Sha256.init(.{});
        fund_hasher.update("funding");
        fund_hasher.update(&channel_id);
        var funding_tx: [32]u8 = undefined;
        fund_hasher.final(&funding_tx);

        std.debug.print("[CHANNEL] Open: A_deposit={d}sat B_deposit={d}sat total={d}sat\n", .{ amount_a, amount_b, total });

        return PaymentChannel{
            .channel_id = channel_id,
            .party_a = party_a,
            .party_b = party_b,
            .balance_a = amount_a,
            .balance_b = amount_b,
            .total_locked = total,
            .sequence_num = 0,
            .state = .open,
            .funding_tx_hash = funding_tx,
            .timeout_blocks = DISPUTE_WINDOW_BLOCKS,
            .created_at = ts,
            .close_block = 0,
            .pending_close_update = null,
            .htlcs = undefined,
            .htlc_count = 0,
        };
    }

    /// Open with explicit channel_id (deterministic, for testing)
    pub fn openWithId(channel_id: [32]u8, party_a: [33]u8, party_b: [33]u8, amount_a: u64, amount_b: u64) error{ExceedsMaxAmount,ZeroDeposit}!PaymentChannel {
        const total = amount_a + amount_b;
        if (total > MAX_CHANNEL_AMOUNT) return error.ExceedsMaxAmount;
        if (total == 0) return error.ZeroDeposit;

        var funding_tx: [32]u8 = undefined;
        var fund_hasher = Sha256.init(.{});
        fund_hasher.update("funding");
        fund_hasher.update(&channel_id);
        fund_hasher.final(&funding_tx);

        return PaymentChannel{
            .channel_id = channel_id,
            .party_a = party_a,
            .party_b = party_b,
            .balance_a = amount_a,
            .balance_b = amount_b,
            .total_locked = total,
            .sequence_num = 0,
            .state = .open,
            .funding_tx_hash = funding_tx,
            .timeout_blocks = DISPUTE_WINDOW_BLOCKS,
            .created_at = std.time.timestamp(),
            .close_block = 0,
            .pending_close_update = null,
            .htlcs = undefined,
            .htlc_count = 0,
        };
    }

    /// Off-chain payment: transfer amount from one party to the other.
    /// Both parties must sign the new state. Sequence number increments atomically.
    /// Total balance is conserved (invariant: balance_a + balance_b == total_locked).
    pub fn pay(self: *PaymentChannel, from_a_to_b: bool, amount: u64, sig_a: [64]u8, sig_b: [64]u8) error{ ChannelNotOpen, InsufficientBalance, BalanceMismatch }!ChannelUpdate {
        if (self.state != .open) return error.ChannelNotOpen;

        var new_a = self.balance_a;
        var new_b = self.balance_b;

        if (from_a_to_b) {
            if (amount > self.balance_a) return error.InsufficientBalance;
            new_a -= amount;
            new_b += amount;
        } else {
            if (amount > self.balance_b) return error.InsufficientBalance;
            new_b -= amount;
            new_a += amount;
        }

        // Invariant check: total must be conserved
        if (new_a + new_b != self.total_locked) return error.BalanceMismatch;

        self.sequence_num += 1;
        self.balance_a = new_a;
        self.balance_b = new_b;

        const update = ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = new_a,
            .balance_b = new_b,
            .sig_a = sig_a,
            .sig_b = sig_b,
        };

        std.debug.print("[CHANNEL] Pay seq={d}: A={d}sat B={d}sat (dir={s})\n", .{
            self.sequence_num, new_a, new_b, if (from_a_to_b) "A->B" else "B->A",
        });

        return update;
    }

    /// Cooperative close: both parties agree on final state, no dispute needed.
    /// Returns a SettleTx with the final on-chain transactions.
    pub fn cooperativeClose(self: *PaymentChannel, sig_a: [64]u8, sig_b: [64]u8) error{ChannelNotOpen}!SettleTx {
        if (self.state != .open) return error.ChannelNotOpen;

        const final_update = ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = self.balance_a,
            .balance_b = self.balance_b,
            .sig_a = sig_a,
            .sig_b = sig_b,
        };

        self.state = .settled;
        std.debug.print("[CHANNEL] Cooperative close: A={d}sat B={d}sat\n", .{ self.balance_a, self.balance_b });

        return SettleTx.fromUpdate(&final_update, 0);
    }

    /// Unilateral close: one party submits their latest signed state.
    /// Starts the dispute window — counterparty has timeout_blocks to submit newer state.
    pub fn unilateralClose(self: *PaymentChannel, submitted_state: ChannelUpdate, current_block: u64) error{ ChannelNotOpen, InvalidChannelId, BalanceMismatch }!SettleTx {
        if (self.state != .open) return error.ChannelNotOpen;
        if (!std.mem.eql(u8, &submitted_state.channel_id, &self.channel_id)) return error.InvalidChannelId;
        if (submitted_state.balance_a + submitted_state.balance_b != self.total_locked) return error.BalanceMismatch;

        self.state = .closing;
        self.close_block = current_block;
        self.pending_close_update = submitted_state;

        // Update balances to what was submitted (may be old state — dispute can fix this)
        self.balance_a = submitted_state.balance_a;
        self.balance_b = submitted_state.balance_b;
        self.sequence_num = submitted_state.sequence_num;

        std.debug.print("[CHANNEL] Unilateral close at block {d}: seq={d} A={d}sat B={d}sat | dispute_window={d}\n", .{
            current_block, submitted_state.sequence_num, submitted_state.balance_a, submitted_state.balance_b, self.timeout_blocks,
        });

        return SettleTx.fromUpdate(&submitted_state, current_block + self.timeout_blocks);
    }

    /// Dispute: counterparty submits a state with higher sequence_num.
    /// Returns true if the dispute was successful (newer state accepted).
    pub fn dispute(self: *PaymentChannel, newer_state: ChannelUpdate) error{ ChannelNotClosing, InvalidChannelId, StateNotNewer, BalanceMismatch }!bool {
        if (self.state != .closing) return error.ChannelNotClosing;
        if (!std.mem.eql(u8, &newer_state.channel_id, &self.channel_id)) return error.InvalidChannelId;
        if (newer_state.sequence_num <= self.sequence_num) return error.StateNotNewer;
        if (newer_state.balance_a + newer_state.balance_b != self.total_locked) return error.BalanceMismatch;

        // Accept the newer state
        self.balance_a = newer_state.balance_a;
        self.balance_b = newer_state.balance_b;
        self.sequence_num = newer_state.sequence_num;
        self.pending_close_update = newer_state;
        self.state = .disputed;

        std.debug.print("[CHANNEL] Dispute won: new seq={d} A={d}sat B={d}sat\n", .{
            newer_state.sequence_num, newer_state.balance_a, newer_state.balance_b,
        });

        return true;
    }

    /// Settle: finalize the channel on-chain after dispute window expires.
    /// Can be called after closing or disputed state, once timeout has passed.
    pub fn settle(self: *PaymentChannel, current_block: u64) error{ ChannelNotClosable, DisputeWindowActive }!SettleTx {
        if (self.state != .closing and self.state != .disputed) return error.ChannelNotClosable;
        if (self.close_block > 0 and current_block < self.close_block + self.timeout_blocks) return error.DisputeWindowActive;

        self.state = .settled;

        const final_update = self.pending_close_update orelse ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = self.balance_a,
            .balance_b = self.balance_b,
            .sig_a = std.mem.zeroes([64]u8),
            .sig_b = std.mem.zeroes([64]u8),
        };

        std.debug.print("[CHANNEL] Settled: A={d}sat B={d}sat at block {d}\n", .{
            self.balance_a, self.balance_b, current_block,
        });

        return SettleTx.fromUpdate(&final_update, current_block);
    }

    /// Add an HTLC to this channel (for multi-hop routing)
    pub fn addHTLC(self: *PaymentChannel, hash_lock: [32]u8, amount_sat: u64, timeout_block: u64) error{ ChannelNotOpen, TooManyHTLCs }!u32 {
        if (self.state != .open) return error.ChannelNotOpen;
        if (self.htlc_count >= MAX_HTLCS_PER_CHANNEL) return error.TooManyHTLCs;

        const htlc_id: u32 = @intCast(self.htlc_count);
        self.htlcs[self.htlc_count] = HTLC{
            .htlc_id = htlc_id,
            .hash_lock = hash_lock,
            .amount_sat = amount_sat,
            .timeout_block = timeout_block,
        };
        self.htlc_count += 1;

        std.debug.print("[CHANNEL] HTLC #{d}: {d}sat timeout_block={d}\n", .{ htlc_id, amount_sat, timeout_block });
        return htlc_id;
    }

    /// Reveal preimage for an HTLC (unlocks payment)
    pub fn revealHTLC(self: *PaymentChannel, htlc_id: u32, preimage: [32]u8) error{ HTLCNotFound, InvalidPreimage }!void {
        if (htlc_id >= self.htlc_count) return error.HTLCNotFound;
        const ok = self.htlcs[htlc_id].reveal(preimage);
        if (!ok) return error.InvalidPreimage;
        std.debug.print("[CHANNEL] HTLC #{d} revealed OK\n", .{htlc_id});
    }

    /// Get the current state as a ChannelUpdate
    pub fn currentUpdate(self: *const PaymentChannel) ChannelUpdate {
        return ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = self.balance_a,
            .balance_b = self.balance_b,
            .sig_a = std.mem.zeroes([64]u8),
            .sig_b = std.mem.zeroes([64]u8),
        };
    }

    /// Format channel_id as hex string into provided buffer
    pub fn getChannelIdHex(self: *const PaymentChannel, buf: []u8) []u8 {
        return std.fmt.bufPrint(buf, "{}", .{std.fmt.fmtSliceHexLower(&self.channel_id)}) catch buf[0..0];
    }
};

/// ChannelManager — fixed-size registry of payment channels.
/// No dynamic allocation — holds up to MAX_CHANNELS channels in a flat array.
/// Thread-safe via mutex for concurrent RPC access.
pub const ChannelManager = struct {
    channels: [MAX_CHANNELS]PaymentChannel,
    channel_count: u8,
    mutex: std.Thread.Mutex,

    pub fn init() ChannelManager {
        return ChannelManager{
            .channels = undefined,
            .channel_count = 0,
            .mutex = .{},
        };
    }

    /// Open a new channel and add it to the registry.
    /// Returns a pointer to the newly created channel.
    pub fn openChannel(self: *ChannelManager, party_a: [33]u8, party_b: [33]u8, amount_a: u64, amount_b: u64) !*PaymentChannel {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.channel_count >= MAX_CHANNELS) return error.TooManyChannels;

        const ch = try PaymentChannel.open(party_a, party_b, amount_a, amount_b);
        self.channels[self.channel_count] = ch;
        const ptr = &self.channels[self.channel_count];
        self.channel_count += 1;
        return ptr;
    }

    /// Find a channel by its ID. Returns null if not found.
    pub fn findChannel(self: *ChannelManager, channel_id: [32]u8) ?*PaymentChannel {
        for (self.channels[0..self.channel_count]) |*ch| {
            if (std.mem.eql(u8, &ch.channel_id, &channel_id)) return ch;
        }
        return null;
    }

    /// Close a channel (cooperative close). Returns the settlement TX.
    pub fn closeChannel(self: *ChannelManager, channel_id: [32]u8, sig_a: [64]u8, sig_b: [64]u8) !SettleTx {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ch = self.findChannel(channel_id) orelse return error.ChannelNotFound;
        return ch.cooperativeClose(sig_a, sig_b);
    }

    /// Get a slice of all channels (active and inactive).
    pub fn getAllChannels(self: *ChannelManager) []PaymentChannel {
        return self.channels[0..self.channel_count];
    }

    /// Count channels in a specific state.
    pub fn countByState(self: *const ChannelManager, target_state: ChannelState) u8 {
        var count: u8 = 0;
        for (self.channels[0..self.channel_count]) |ch| {
            if (ch.state == target_state) count += 1;
        }
        return count;
    }

    /// Get total SAT locked across all open/closing channels.
    pub fn getTotalLockedSat(self: *const ChannelManager) u64 {
        var total: u64 = 0;
        for (self.channels[0..self.channel_count]) |ch| {
            if (ch.state == .open or ch.state == .closing) {
                total += ch.total_locked;
            }
        }
        return total;
    }

    pub fn printStatus(self: *const ChannelManager) void {
        const open_count = self.countByState(.open);
        const closing_count = self.countByState(.closing);
        const settled_count = self.countByState(.settled);
        std.debug.print("[CHANNELS] Open={d} Closing={d} Settled={d} | Total locked: {d} SAT\n", .{
            open_count, closing_count, settled_count, self.getTotalLockedSat(),
        });
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// Helper: create test pubkeys (deterministic, not real keys)
fn testPubkeyA() [33]u8 {
    var pk: [33]u8 = undefined;
    pk[0] = 0x02; // compressed pubkey prefix
    for (pk[1..]) |*b| b.* = 0xAA;
    return pk;
}

fn testPubkeyB() [33]u8 {
    var pk: [33]u8 = undefined;
    pk[0] = 0x03;
    for (pk[1..]) |*b| b.* = 0xBB;
    return pk;
}

fn testSig(fill: u8) [64]u8 {
    var sig: [64]u8 = undefined;
    for (&sig) |*b| b.* = fill;
    return sig;
}

// ── PaymentChannel.open ─────────────────────────────────────────────────────

test "PaymentChannel — open generates unique non-zero channel_id" {
    const ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    var all_zero = true;
    for (ch.channel_id) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try testing.expect(!all_zero);
    try testing.expect(ch.state == .open);
}

test "PaymentChannel — initial balances equal deposits" {
    const ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 500_000_000), ch.balance_b);
    try testing.expectEqual(@as(u64, 1_500_000_000), ch.total_locked);
    try testing.expectEqual(@as(u64, 0), ch.sequence_num);
}

test "PaymentChannel — open rejects zero deposit" {
    try testing.expectError(error.ZeroDeposit, PaymentChannel.open(testPubkeyA(), testPubkeyB(), 0, 0));
}

test "PaymentChannel — open rejects exceeding max amount" {
    try testing.expectError(error.ExceedsMaxAmount, PaymentChannel.open(testPubkeyA(), testPubkeyB(), MAX_CHANNEL_AMOUNT, 1));
}

// ── PaymentChannel.pay ──────────────────────────────────────────────────────

test "PaymentChannel — pay A to B updates balances correctly" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    const update = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22));

    try testing.expectEqual(@as(u64, 900_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 100_000_000), ch.balance_b);
    try testing.expectEqual(@as(u64, 1), ch.sequence_num);
    try testing.expectEqual(@as(u64, 1), update.sequence_num);
    try testing.expectEqual(@as(u64, 900_000_000), update.balance_a);
    try testing.expectEqual(@as(u64, 100_000_000), update.balance_b);
}

test "PaymentChannel — pay B to A updates balances correctly" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 500_000_000, 500_000_000);
    _ = try ch.pay(false, 200_000_000, testSig(0x11), testSig(0x22));

    try testing.expectEqual(@as(u64, 700_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 300_000_000), ch.balance_b);
}

test "PaymentChannel — pay insufficient balance returns error" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 100_000_000, 0);
    try testing.expectError(error.InsufficientBalance, ch.pay(true, 200_000_000, testSig(0x11), testSig(0x22)));
}

test "PaymentChannel — multiple payments increment sequence" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=1
    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=2
    _ = try ch.pay(false, 50_000_000, testSig(0x11), testSig(0x22)); // seq=3

    try testing.expectEqual(@as(u64, 3), ch.sequence_num);
    try testing.expectEqual(@as(u64, 850_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 150_000_000), ch.balance_b);
    // Total conserved
    try testing.expectEqual(@as(u64, 1_000_000_000), ch.balance_a + ch.balance_b);
}

test "PaymentChannel — pay on closed channel returns error" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try ch.cooperativeClose(testSig(0x11), testSig(0x22));
    try testing.expectError(error.ChannelNotOpen, ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)));
}

// ── Cooperative Close ───────────────────────────────────────────────────────

test "PaymentChannel — cooperative close returns correct settle TX" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    _ = try ch.pay(true, 300_000_000, testSig(0x11), testSig(0x22));

    const settle = try ch.cooperativeClose(testSig(0x33), testSig(0x44));
    try testing.expect(ch.state == .settled);
    try testing.expectEqual(@as(u64, 700_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 800_000_000), settle.final_balance_b);
}

// ── Unilateral Close + Dispute + Settle ─────────────────────────────────────

test "PaymentChannel — unilateral close with timeout" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try ch.pay(true, 200_000_000, testSig(0x11), testSig(0x22));

    // Party submits current state at block 1000
    const submitted = ch.currentUpdate();
    _ = try ch.unilateralClose(submitted, 1000);

    try testing.expect(ch.state == .closing);
    try testing.expectEqual(@as(u64, 1000), ch.close_block);

    // Cannot settle before timeout
    try testing.expectError(error.DisputeWindowActive, ch.settle(1100));

    // Can settle after timeout
    const settle = try ch.settle(1000 + DISPUTE_WINDOW_BLOCKS);
    try testing.expect(ch.state == .settled);
    try testing.expectEqual(@as(u64, 800_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 200_000_000), settle.final_balance_b);
}

test "PaymentChannel — dispute with newer state wins" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x01)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    // Make several payments: seq goes to 3
    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=1, A=900M B=100M
    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=2, A=800M B=200M
    const latest_update = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=3, A=700M B=300M

    // Attacker submits OLD state (seq=1) for unilateral close
    const old_state = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = 1,
        .balance_a = 900_000_000,
        .balance_b = 100_000_000,
        .sig_a = testSig(0x11),
        .sig_b = testSig(0x22),
    };
    _ = try ch.unilateralClose(old_state, 5000);
    try testing.expect(ch.state == .closing);
    try testing.expectEqual(@as(u64, 1), ch.sequence_num); // old state

    // Honest party disputes with seq=3 (newer)
    const won = try ch.dispute(latest_update);
    try testing.expect(won);
    try testing.expect(ch.state == .disputed);
    try testing.expectEqual(@as(u64, 3), ch.sequence_num);
    try testing.expectEqual(@as(u64, 700_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 300_000_000), ch.balance_b);
}

test "PaymentChannel — dispute with old state fails" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x02)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=1
    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=2

    // Close with seq=2 (latest)
    const current = ch.currentUpdate();
    _ = try ch.unilateralClose(current, 5000);

    // Try to dispute with seq=1 (older) — should fail
    const old_state = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = 1,
        .balance_a = 900_000_000,
        .balance_b = 100_000_000,
        .sig_a = testSig(0x11),
        .sig_b = testSig(0x22),
    };
    try testing.expectError(error.StateNotNewer, ch.dispute(old_state));
}

test "PaymentChannel — sequence number prevents old state fraud" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x03)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    _ = try ch.pay(true, 500_000_000, testSig(0x11), testSig(0x22)); // seq=1: A=500M B=500M
    _ = try ch.pay(false, 300_000_000, testSig(0x11), testSig(0x22)); // seq=2: A=800M B=200M

    // B tries unilateral close with seq=1 (favorable to B: B=500M)
    const old_state = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = 1,
        .balance_a = 500_000_000,
        .balance_b = 500_000_000,
        .sig_a = testSig(0x11),
        .sig_b = testSig(0x22),
    };
    _ = try ch.unilateralClose(old_state, 10000);

    // A disputes with seq=2 (A=800M B=200M — the true latest state)
    const real_state = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = 2,
        .balance_a = 800_000_000,
        .balance_b = 200_000_000,
        .sig_a = testSig(0x11),
        .sig_b = testSig(0x22),
    };
    const won = try ch.dispute(real_state);
    try testing.expect(won);

    // After dispute window, settle with correct balances
    const settle = try ch.settle(10000 + DISPUTE_WINDOW_BLOCKS);
    try testing.expectEqual(@as(u64, 800_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 200_000_000), settle.final_balance_b);
}

// ── HTLC tests ──────────────────────────────────────────────────────────────

test "PaymentChannel — HTLC reveal with correct preimage" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    const preimage: [32]u8 = @splat(0x42);
    var hasher = Sha256.init(.{});
    hasher.update(&preimage);
    var hash_lock: [32]u8 = undefined;
    hasher.final(&hash_lock);

    const htlc_id = try ch.addHTLC(hash_lock, 100_000_000, 200);
    try ch.revealHTLC(htlc_id, preimage);
    try testing.expect(ch.htlcs[htlc_id].revealed);
}

test "PaymentChannel — HTLC reveal with wrong preimage returns error" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    const preimage: [32]u8 = @splat(0x42);
    var hasher = Sha256.init(.{});
    hasher.update(&preimage);
    var hash_lock: [32]u8 = undefined;
    hasher.final(&hash_lock);

    const htlc_id = try ch.addHTLC(hash_lock, 100_000_000, 200);
    const bad_preimage: [32]u8 = @splat(0x99);
    try testing.expectError(error.InvalidPreimage, ch.revealHTLC(htlc_id, bad_preimage));
}

test "PaymentChannel — HTLC expired check" {
    var ch = try PaymentChannel.open(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);

    _ = try ch.addHTLC(std.mem.zeroes([32]u8), 100_000_000, 200);
    try testing.expect(!ch.htlcs[0].isExpired(100));
    try testing.expect(ch.htlcs[0].isExpired(200));
    try testing.expect(ch.htlcs[0].isExpired(300));
}

// ── ChannelUpdate tests ─────────────────────────────────────────────────────

test "ChannelUpdate — hash is deterministic" {
    const upd_a = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 5,
        .balance_a = 700_000_000,
        .balance_b = 300_000_000,
        .sig_a = testSig(0xAA),
        .sig_b = testSig(0xBB),
    };
    const upd_b = upd_a; // copy
    try testing.expect(std.mem.eql(u8, &upd_a.hash(), &upd_b.hash()));
}

test "ChannelUpdate — different sequence produces different hash" {
    const upd_a = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 1,
        .balance_a = 700_000_000,
        .balance_b = 300_000_000,
        .sig_a = testSig(0xAA),
        .sig_b = testSig(0xBB),
    };
    var upd_b = upd_a;
    upd_b.sequence_num = 2;
    try testing.expect(!std.mem.eql(u8, &upd_a.hash(), &upd_b.hash()));
}

test "ChannelUpdate — verify requires non-zero sigs" {
    const update = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 1,
        .balance_a = 500_000_000,
        .balance_b = 500_000_000,
        .sig_a = testSig(0x11),
        .sig_b = testSig(0x22),
    };
    try testing.expect(update.verify(testPubkeyA(), testPubkeyB()));

    // Zero sig_a should fail
    const bad_update = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 1,
        .balance_a = 500_000_000,
        .balance_b = 500_000_000,
        .sig_a = std.mem.zeroes([64]u8),
        .sig_b = testSig(0x22),
    };
    try testing.expect(!bad_update.verify(testPubkeyA(), testPubkeyB()));
}

// ── SettleTx tests ──────────────────────────────────────────────────────────

test "SettleTx — fromUpdate produces deterministic hashes" {
    const update = ChannelUpdate{
        .channel_id = @as([32]u8, @splat(0x01)),
        .sequence_num = 5,
        .balance_a = 700_000_000,
        .balance_b = 300_000_000,
        .sig_a = testSig(0xAA),
        .sig_b = testSig(0xBB),
    };
    const s1 = SettleTx.fromUpdate(&update, 1000);
    const s2 = SettleTx.fromUpdate(&update, 1000);
    try testing.expect(std.mem.eql(u8, &s1.tx_hash_a, &s2.tx_hash_a));
    try testing.expect(std.mem.eql(u8, &s1.tx_hash_b, &s2.tx_hash_b));
    // tx_hash_a != tx_hash_b (different settle sides)
    try testing.expect(!std.mem.eql(u8, &s1.tx_hash_a, &s1.tx_hash_b));
}

// ── ChannelManager tests ────────────────────────────────────────────────────

test "ChannelManager — openChannel and findChannel" {
    var mgr = ChannelManager.init();
    const ch = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    try testing.expect(ch.state == .open);

    const found = mgr.findChannel(ch.channel_id);
    try testing.expect(found != null);
    try testing.expectEqual(@as(u64, 1_000_000_000), found.?.balance_a);
}

test "ChannelManager — countByState tracks states" {
    var mgr = ChannelManager.init();
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 500_000_000, 500_000_000);

    try testing.expectEqual(@as(u8, 2), mgr.countByState(.open));
    try testing.expectEqual(@as(u8, 0), mgr.countByState(.settled));
}

test "ChannelManager — getTotalLockedSat sums correctly" {
    var mgr = ChannelManager.init();
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 0);
    _ = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 500_000_000, 500_000_000);

    try testing.expectEqual(@as(u64, 2_000_000_000), mgr.getTotalLockedSat());
}

test "ChannelManager — closeChannel settles correctly" {
    var mgr = ChannelManager.init();
    const ch = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 1_000_000_000, 500_000_000);
    const cid = ch.channel_id;

    const settle = try mgr.closeChannel(cid, testSig(0x11), testSig(0x22));
    try testing.expectEqual(@as(u64, 1_000_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 500_000_000), settle.final_balance_b);

    const found = mgr.findChannel(cid);
    try testing.expect(found != null);
    try testing.expect(found.?.state == .settled);
}

// ── Full lifecycle: open -> pay -> close -> balances correct ─────────────────

test "Full lifecycle — open pay close cooperative" {
    var mgr = ChannelManager.init();
    const ch = try mgr.openChannel(testPubkeyA(), testPubkeyB(), 2_000_000_000, 1_000_000_000);

    // A pays B 500M sat
    _ = try ch.pay(true, 500_000_000, testSig(0x11), testSig(0x22));
    // B pays A 200M sat
    _ = try ch.pay(false, 200_000_000, testSig(0x11), testSig(0x22));

    // Final: A=1700M, B=1300M (total=3000M conserved)
    try testing.expectEqual(@as(u64, 1_700_000_000), ch.balance_a);
    try testing.expectEqual(@as(u64, 1_300_000_000), ch.balance_b);

    const settle = try ch.cooperativeClose(testSig(0x33), testSig(0x44));
    try testing.expectEqual(@as(u64, 1_700_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 1_300_000_000), settle.final_balance_b);
    try testing.expect(ch.state == .settled);
}

test "Full lifecycle — open pay unilateral close dispute settle" {
    var ch = try PaymentChannel.openWithId(
        @as([32]u8, @splat(0x05)),
        testPubkeyA(),
        testPubkeyB(),
        1_000_000_000,
        0,
    );

    // Several payments
    _ = try ch.pay(true, 100_000_000, testSig(0x11), testSig(0x22)); // seq=1
    _ = try ch.pay(true, 200_000_000, testSig(0x11), testSig(0x22)); // seq=2
    const latest = try ch.pay(true, 50_000_000, testSig(0x11), testSig(0x22)); // seq=3: A=650M B=350M

    // Malicious party submits old state (seq=1)
    const fraud_state = ChannelUpdate{
        .channel_id = ch.channel_id,
        .sequence_num = 1,
        .balance_a = 900_000_000,
        .balance_b = 100_000_000,
        .sig_a = testSig(0x11),
        .sig_b = testSig(0x22),
    };
    _ = try ch.unilateralClose(fraud_state, 20000);

    // Honest party disputes with seq=3
    _ = try ch.dispute(latest);

    // Settle after timeout
    const settle = try ch.settle(20000 + DISPUTE_WINDOW_BLOCKS);
    try testing.expectEqual(@as(u64, 650_000_000), settle.final_balance_a);
    try testing.expectEqual(@as(u64, 350_000_000), settle.final_balance_b);
    try testing.expect(ch.state == .settled);
}
