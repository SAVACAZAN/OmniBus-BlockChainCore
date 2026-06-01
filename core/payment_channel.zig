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
const secp256k1 = @import("secp256k1.zig");

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

    /// Verify both party signatures over the canonical update hash using
    /// secp256k1 ECDSA. Both sigs must:
    ///   - be canonical (low-S, non-zero R/S — enforced by secp256k1.verify)
    ///   - validate against the corresponding compressed pubkey
    ///   - cover the same message: hash() of this update
    /// Either failure → false (caller treats the update as forged/stale).
    pub fn verify(self: *const ChannelUpdate, pk_a: [33]u8, pk_b: [33]u8) bool {
        const msg = self.hash();
        if (!secp256k1.Secp256k1Crypto.verify(pk_a, &msg, self.sig_a)) return false;
        if (!secp256k1.Secp256k1Crypto.verify(pk_b, &msg, self.sig_b)) return false;
        return true;
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
    pub fn pay(self: *PaymentChannel, from_a_to_b: bool, amount: u64, sig_a: [64]u8, sig_b: [64]u8) error{ ChannelNotOpen, InsufficientBalance, BalanceMismatch, InvalidSignature }!ChannelUpdate {
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

        // Build the candidate update with PROPOSED sequence/balances and the
        // two signatures supplied by the caller, then verify both before
        // mutating channel state. This blocks the "anyone can advance the
        // channel without signing" attack the placeholder code path used to
        // permit.
        const candidate = ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num + 1,
            .balance_a = new_a,
            .balance_b = new_b,
            .sig_a = sig_a,
            .sig_b = sig_b,
        };
        if (!candidate.verify(self.party_a, self.party_b)) return error.InvalidSignature;

        self.sequence_num += 1;
        self.balance_a = new_a;
        self.balance_b = new_b;

        std.debug.print("[CHANNEL] Pay seq={d}: A={d}sat B={d}sat (dir={s})\n", .{
            self.sequence_num, new_a, new_b, if (from_a_to_b) "A->B" else "B->A",
        });

        return candidate;
    }

    /// Cooperative close: both parties agree on final state, no dispute needed.
    /// Returns a SettleTx with the final on-chain transactions.
    pub fn cooperativeClose(self: *PaymentChannel, sig_a: [64]u8, sig_b: [64]u8) error{ChannelNotOpen, InvalidSignature}!SettleTx {
        if (self.state != .open) return error.ChannelNotOpen;

        const final_update = ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = self.balance_a,
            .balance_b = self.balance_b,
            .sig_a = sig_a,
            .sig_b = sig_b,
        };
        // Both parties must sign the final state. Without this check, anyone
        // who knows the channel_id could close the channel unilaterally with
        // bogus signatures and lock the counterparty out of dispute window.
        if (!final_update.verify(self.party_a, self.party_b)) return error.InvalidSignature;

        self.state = .settled;
        std.debug.print("[CHANNEL] Cooperative close: A={d}sat B={d}sat\n", .{ self.balance_a, self.balance_b });

        return SettleTx.fromUpdate(&final_update, 0);
    }

    /// Unilateral close: one party submits their latest signed state.
    /// Starts the dispute window — counterparty has timeout_blocks to submit newer state.
    pub fn unilateralClose(self: *PaymentChannel, submitted_state: ChannelUpdate, current_block: u64) error{ ChannelNotOpen, InvalidChannelId, BalanceMismatch, InvalidSignature }!SettleTx {
        if (self.state != .open) return error.ChannelNotOpen;
        if (!std.mem.eql(u8, &submitted_state.channel_id, &self.channel_id)) return error.InvalidChannelId;
        if (submitted_state.balance_a + submitted_state.balance_b != self.total_locked) return error.BalanceMismatch;
        // The submitted state MUST carry valid sigs from both parties —
        // without this, a malicious peer could submit an arbitrary balance
        // distribution and force the channel into dispute.
        if (!submitted_state.verify(self.party_a, self.party_b)) return error.InvalidSignature;

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
    pub fn dispute(self: *PaymentChannel, newer_state: ChannelUpdate) error{ ChannelNotClosing, InvalidChannelId, StateNotNewer, BalanceMismatch, InvalidSignature }!bool {
        if (self.state != .closing) return error.ChannelNotClosing;
        if (!std.mem.eql(u8, &newer_state.channel_id, &self.channel_id)) return error.InvalidChannelId;
        if (newer_state.sequence_num <= self.sequence_num) return error.StateNotNewer;
        if (newer_state.balance_a + newer_state.balance_b != self.total_locked) return error.BalanceMismatch;
        // Dispute is a security-critical path — a forged "newer" state with
        // no real sigs would let an attacker rewrite the closing balances.
        if (!newer_state.verify(self.party_a, self.party_b)) return error.InvalidSignature;

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

        // If a pending_close_update is set (from unilateralClose), use it — it
        // already carries verified sigs. Otherwise we're settling from
        // .closing without any submitted state which shouldn't happen, but
        // emit zero-sig fallback so callers can still observe the final
        // balances; downstream verify() will (correctly) reject it.
        const final_update = self.pending_close_update orelse ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = self.balance_a,
            .balance_b = self.balance_b,
            .sig_a = @splat(0),
            .sig_b = @splat(0),
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

    /// Get the current state as a ChannelUpdate (sigs left empty —
    /// caller must populate them by signing the hash() before submitting
    /// to verify()).
    pub fn currentUpdate(self: *const PaymentChannel) ChannelUpdate {
        return ChannelUpdate{
            .channel_id = self.channel_id,
            .sequence_num = self.sequence_num,
            .balance_a = self.balance_a,
            .balance_b = self.balance_b,
            .sig_a = @splat(0),
            .sig_b = @splat(0),
        };
    }

    /// Format channel_id as hex string into provided buffer (must be >=64 bytes).
    /// Returns slice of buf containing the hex string.
    pub fn getChannelIdHex(self: *const PaymentChannel, buf: []u8) []u8 {
        const hex = std.fmt.bytesToHex(self.channel_id, .lower);
        if (buf.len < hex.len) return buf[0..0];
        @memcpy(buf[0..hex.len], &hex);
        return buf[0..hex.len];
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
    /// Errors:
    ///   - ChannelNotFound — no channel with this id
    ///   - ChannelNotOpen  — channel is not in `.open` state
    ///   - InvalidSignature — sig_a or sig_b did not verify against party pubkeys
    pub fn closeChannel(self: *ChannelManager, channel_id: [32]u8, sig_a: [64]u8, sig_b: [64]u8) error{ChannelNotFound, ChannelNotOpen, InvalidSignature}!SettleTx {
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
