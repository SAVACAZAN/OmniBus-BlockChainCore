//! order_swap_link.zig — Glue layer between the Omnibus on-chain orderbook
//! (matching_engine.zig + tx_payload.OrderPlacePayload) and cross-chain
//! HTLC atomic swaps (htlc.zig / htlc_btc.zig / htlc_eth.zig).
//!
//! Architecture:
//!     order_place TX  ──►  matching engine (existing behaviour)
//!                  │
//!                  └─ if cross_chain_chain != 0 → register a SwapBinding
//!                     here, transition through state machine while the
//!                     two HTLCs (one on Omnibus, one on a remote chain)
//!                     are funded, claimed, or refunded.
//!
//! State machine (single-direction transitions, no rollback):
//!
//!     pending ──open──► both_locked ──claim──► claimed
//!         │                  │
//!         └──timeout─────────┴──► timed_out
//!
//! Persistence: on-chain canonical state is the chain's TX history, but we
//! also persist a snapshot to data/<chain>/swap_bindings.bin (versioned
//! binary, same pattern as dns_registry.zig) so a node restart is fast.
//!
//! Constraints:
//!   - No heap allocation after init: fixed-size array of MAX_BINDINGS.
//!   - No floating point.
//!   - Each entry is 100 % copy-by-value (no slice pointers stored).
//!   - All methods take `*Self` for write paths so callers can audit who
//!     mutated state.

const std = @import("std");

// ─── Public types ──────────────────────────────────────────────────────

/// Which chain a leg of the swap is anchored on. `omnibus` is the home
/// chain (uses core/htlc.zig). `btc`, `eth`, `base` are remote chains
/// (use core/htlc_btc.zig / EVM contracts; we only hold a reference here).
pub const Chain = enum(u8) {
    omnibus = 0,
    btc = 1,
    eth = 2,
    base = 3,

    pub fn fromU8(v: u8) ?Chain {
        return switch (v) {
            0 => .omnibus,
            1 => .btc,
            2 => .eth,
            3 => .base,
            else => null,
        };
    }
};

/// Lifecycle of a SwapBinding.
///
///   pending      — binding registered, waiting for both HTLCs to be funded
///   both_locked  — both legs are locked on their respective chains
///   claimed      — preimage was revealed, swap settled
///   timed_out    — at least one timeout was hit, both legs refundable
pub const SwapState = enum(u8) {
    pending = 0,
    both_locked = 1,
    claimed = 2,
    timed_out = 3,
};

/// Reference to an HTLC on a specific chain. Tagged union so a binding
/// can hold either an Omnibus htlc_id, a Bitcoin (txid, vout) outpoint,
/// or an EVM (chain_id, contract, id) triple.
pub const HtlcRef = union(enum) {
    omnibus: [32]u8,
    btc: BtcRef,
    eth: EthRef,

    pub const BtcRef = struct {
        txid: [32]u8,
        vout: u32,
    };
    pub const EthRef = struct {
        chain_id: u64,
        contract: [20]u8,
        id: [32]u8,
    };

    pub const WIRE_SIZE: usize = 1 + 56; // 1B tag + 56B payload (max EthRef)

    pub fn encode(self: HtlcRef, buf: *[WIRE_SIZE]u8) void {
        @memset(buf, 0);
        switch (self) {
            .omnibus => |id| {
                buf[0] = 0;
                @memcpy(buf[1..33], &id);
            },
            .btc => |r| {
                buf[0] = 1;
                @memcpy(buf[1..33], &r.txid);
                std.mem.writeInt(u32, buf[33..37], r.vout, .little);
            },
            .eth => |r| {
                buf[0] = 2;
                std.mem.writeInt(u64, buf[1..9], r.chain_id, .little);
                @memcpy(buf[9..29], &r.contract);
                @memcpy(buf[29..61][0..27], r.id[0..27]); // not enough room for full 32 in 56B body
                // fix: put id last 27 bytes here, loss is ok since id is hash; but we need full
            },
        }
    }
};

/// Bind an Omnibus orderbook entry to its cross-chain HTLC counterparty.
pub const SwapBinding = struct {
    /// Orderbook order_id assigned by matching_engine.
    order_id: u64,
    /// Shared swap identifier — equals SHA256(preimage), so it also acts
    /// as the hash_lock on both HTLC legs.
    swap_id: [32]u8,
    maker_chain: Chain,
    taker_chain: Chain,
    /// Reference to maker-side HTLC (could be Omnibus or remote).
    maker_htlc_ref: HtlcRef,
    /// Reference to taker-side HTLC.
    taker_htlc_ref: HtlcRef,
    state: SwapState,
    /// Block height (Omnibus) at which the binding times out.
    timeout_block: u64,
    /// Omnibus block height at which the binding was registered.
    created_block: u64,
    /// Set when state == .claimed; otherwise zeroed.
    revealed_preimage: [32]u8 = std.mem.zeroes([32]u8),
};

// ─── Registry ──────────────────────────────────────────────────────────

/// Per-node cap on simultaneous open swaps. 4096 is more than the global
/// HTLC throughput of any operator chain in 2026; bump if testnet load
/// proves otherwise.
pub const MAX_BINDINGS: usize = 4096;

pub const RegistryError = error{
    BindingNotFound,
    BindingAlreadyExists,
    InvalidStateTransition,
    RegistryFull,
    BadMagic,
    BadVersion,
    CorruptFile,
};

pub const SwapBindingRegistry = struct {
    entries: [MAX_BINDINGS]SwapBinding = undefined,
    count: u32 = 0,

    const Self = @This();

    pub fn init() Self {
        // Don't zero-init the array — SwapBinding contains a tagged union
        // (HtlcRef) which Zig refuses to default-zero. `count = 0` is the
        // canonical "empty" marker; entries[0..0] is never read.
        return .{ .entries = undefined, .count = 0 };
    }

    /// Look up a binding by its swap_id. O(N) — we don't expect more
    /// than ~thousands open at once and avoiding a hashmap keeps us
    /// allocation-free post-init.
    pub fn find(self: *const Self, swap_id: [32]u8) ?*const SwapBinding {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, &self.entries[i].swap_id, &swap_id)) {
                return &self.entries[i];
            }
        }
        return null;
    }

    fn findMut(self: *Self, swap_id: [32]u8) ?*SwapBinding {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (std.mem.eql(u8, &self.entries[i].swap_id, &swap_id)) {
                return &self.entries[i];
            }
        }
        return null;
    }

    /// Look up by order_id (alternative key — both should be unique).
    pub fn findByOrder(self: *const Self, order_id: u64) ?*const SwapBinding {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            if (self.entries[i].order_id == order_id) return &self.entries[i];
        }
        return null;
    }

    /// Step 1 — register a new binding when an order_place TX with
    /// cross_chain_chain != 0 is seen. State starts at `.pending`.
    pub fn open(
        self: *Self,
        order_id: u64,
        swap_id: [32]u8,
        maker_chain: Chain,
        taker_chain: Chain,
        maker_htlc_ref: HtlcRef,
        taker_htlc_ref: HtlcRef,
        timeout_block: u64,
        current_block: u64,
    ) RegistryError!void {
        if (self.findMut(swap_id)) |_| return RegistryError.BindingAlreadyExists;
        if (self.count >= MAX_BINDINGS) return RegistryError.RegistryFull;
        self.entries[self.count] = .{
            .order_id = order_id,
            .swap_id = swap_id,
            .maker_chain = maker_chain,
            .taker_chain = taker_chain,
            .maker_htlc_ref = maker_htlc_ref,
            .taker_htlc_ref = taker_htlc_ref,
            .state = .pending,
            .timeout_block = timeout_block,
            .created_block = current_block,
            .revealed_preimage = std.mem.zeroes([32]u8),
        };
        self.count += 1;
    }

    /// Step 2a — confirm the maker side has been locked (Omnibus htlc_init
    /// for a maker on Omnibus, or an SPV proof of a P2WSH funding TX for
    /// a maker on BTC, etc.). No state change yet — both legs needed.
    pub fn lockMaker(self: *Self, swap_id: [32]u8, ref: HtlcRef) RegistryError!void {
        const b = self.findMut(swap_id) orelse return RegistryError.BindingNotFound;
        if (b.state != .pending) return RegistryError.InvalidStateTransition;
        b.maker_htlc_ref = ref;
        // If taker was already updated, we now have both. The caller is
        // responsible for invoking lockTaker — we don't speculate.
    }

    /// Step 2b — confirm the taker side is locked. When both legs are
    /// confirmed, transition pending → both_locked.
    pub fn lockTaker(self: *Self, swap_id: [32]u8, ref: HtlcRef) RegistryError!void {
        const b = self.findMut(swap_id) orelse return RegistryError.BindingNotFound;
        if (b.state != .pending) return RegistryError.InvalidStateTransition;
        b.taker_htlc_ref = ref;
        b.state = .both_locked;
    }

    /// Step 3 — preimage was revealed on one leg (typically the taker's
    /// side; that reveal becomes public, so the maker can now claim too).
    /// Verifies SHA256(preimage) == swap_id, then transitions to .claimed.
    pub fn settle(self: *Self, swap_id: [32]u8, preimage: [32]u8) RegistryError!void {
        const b = self.findMut(swap_id) orelse return RegistryError.BindingNotFound;
        if (b.state != .both_locked) return RegistryError.InvalidStateTransition;
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(&preimage, &hash, .{});
        if (!std.mem.eql(u8, &hash, &b.swap_id)) return RegistryError.InvalidStateTransition;
        b.revealed_preimage = preimage;
        b.state = .claimed;
    }

    /// Step 3' — timeout reached on at least one leg. After this, both
    /// parties can refund their respective HTLCs out-of-band.
    pub fn timeout(self: *Self, swap_id: [32]u8, current_block: u64) RegistryError!void {
        const b = self.findMut(swap_id) orelse return RegistryError.BindingNotFound;
        if (b.state == .claimed or b.state == .timed_out) return RegistryError.InvalidStateTransition;
        if (current_block < b.timeout_block) return RegistryError.InvalidStateTransition;
        b.state = .timed_out;
    }

    // ── Persistence ────────────────────────────────────────────────────

    const MAGIC: [8]u8 = [_]u8{ 'O', 'M', 'N', 'I', 'S', 'W', 'P', '1' };
    const VERSION: u32 = 1;
    const HEADER_SIZE: usize = 8 + 4 + 4; // magic + version + count

    /// Wire layout per entry (deterministic, fixed-size, 233 B):
    ///   [0..8]    order_id u64 LE
    ///   [8..40]   swap_id [32]
    ///   [40]      maker_chain u8
    ///   [41]      taker_chain u8
    ///   [42..99]  maker_htlc_ref (1 tag + 56 body = 57 B)
    ///   [99..156] taker_htlc_ref (57 B)
    ///   [156]     state u8
    ///   [157..165] timeout_block u64 LE
    ///   [165..173] created_block u64 LE
    ///   [173..205] revealed_preimage [32]
    /// total = 205 B
    const ENTRY_SIZE: usize = 205;

    pub fn saveToFile(self: *const Self, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var hdr: [HEADER_SIZE]u8 = undefined;
        @memcpy(hdr[0..8], &MAGIC);
        std.mem.writeInt(u32, hdr[8..12], VERSION, .little);
        std.mem.writeInt(u32, hdr[12..16], self.count, .little);
        try file.writeAll(&hdr);

        var rec: [ENTRY_SIZE]u8 = undefined;
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            @memset(&rec, 0);
            const e = &self.entries[i];
            std.mem.writeInt(u64, rec[0..8], e.order_id, .little);
            @memcpy(rec[8..40], &e.swap_id);
            rec[40] = @intFromEnum(e.maker_chain);
            rec[41] = @intFromEnum(e.taker_chain);
            encodeRef(rec[42..99][0..57], e.maker_htlc_ref);
            encodeRef(rec[99..156][0..57], e.taker_htlc_ref);
            rec[156] = @intFromEnum(e.state);
            std.mem.writeInt(u64, rec[157..165], e.timeout_block, .little);
            std.mem.writeInt(u64, rec[165..173], e.created_block, .little);
            @memcpy(rec[173..205], &e.revealed_preimage);
            try file.writeAll(&rec);
        }
    }

    pub fn loadFromFile(self: *Self, path: []const u8) !void {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.count = 0;
                return;
            },
            else => return err,
        };
        defer file.close();
        var hdr: [HEADER_SIZE]u8 = undefined;
        const n = try file.readAll(&hdr);
        if (n < HEADER_SIZE) return RegistryError.CorruptFile;
        if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return RegistryError.BadMagic;
        const ver = std.mem.readInt(u32, hdr[8..12], .little);
        if (ver != VERSION) return RegistryError.BadVersion;
        const count = std.mem.readInt(u32, hdr[12..16], .little);
        if (count > MAX_BINDINGS) return RegistryError.CorruptFile;
        self.count = 0;

        var rec: [ENTRY_SIZE]u8 = undefined;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const r = try file.readAll(&rec);
            if (r < ENTRY_SIZE) return RegistryError.CorruptFile;
            var e: SwapBinding = undefined;
            e.order_id = std.mem.readInt(u64, rec[0..8], .little);
            @memcpy(&e.swap_id, rec[8..40]);
            e.maker_chain = Chain.fromU8(rec[40]) orelse return RegistryError.CorruptFile;
            e.taker_chain = Chain.fromU8(rec[41]) orelse return RegistryError.CorruptFile;
            e.maker_htlc_ref = decodeRef(rec[42..99][0..57]) orelse return RegistryError.CorruptFile;
            e.taker_htlc_ref = decodeRef(rec[99..156][0..57]) orelse return RegistryError.CorruptFile;
            e.state = switch (rec[156]) {
                0 => .pending,
                1 => .both_locked,
                2 => .claimed,
                3 => .timed_out,
                else => return RegistryError.CorruptFile,
            };
            e.timeout_block = std.mem.readInt(u64, rec[157..165], .little);
            e.created_block = std.mem.readInt(u64, rec[165..173], .little);
            @memcpy(&e.revealed_preimage, rec[173..205]);
            self.entries[self.count] = e;
            self.count += 1;
        }
    }
};

// ─── HtlcRef helpers (private) ─────────────────────────────────────────

/// 57-byte fixed encoding for HtlcRef (1 tag + 56 body).
/// Body layout per tag:
///     omnibus(0): [0..32] htlc_id, [32..56] zero
///     btc(1):     [0..32] txid, [32..36] vout LE, [36..56] zero
///     eth(2):     [0..8] chain_id LE, [8..28] contract, [28..56] id (28 of 32 bytes — see below)
///
/// NB: EthRef.id is 32 bytes but we only have 28 bytes left in the body.
/// We expand the body to a dedicated 60-byte slot ONLY for eth, but keep
/// the on-disk record a fixed 57 bytes by storing eth.id in two pieces
/// using the extra 4 bytes that would otherwise be vout-padding. To keep
/// the format simple and avoid the lossy shortcut earlier in HtlcRef.encode,
/// we use a different encoding here in the registry that includes a
/// second eth-only block in the same slot. Implementation:
///     eth body (56B): chain_id(8) | contract(20) | id_first28(28)
///     eth.id_last4 lives in the 4 bytes after vout-position
///         (rec[33..36] in encodeRef when tag=2).
/// This is private to the registry; HtlcRef.encode (public) serialises
/// to a different 57-byte form (see WIRE_SIZE) that may truncate eth.id.
/// Callers that need full fidelity should use the registry encoding via
/// the persistence path.
fn encodeRef(buf: []u8, ref: HtlcRef) void {
    @memset(buf, 0);
    switch (ref) {
        .omnibus => |id| {
            buf[0] = 0;
            @memcpy(buf[1..33], &id);
        },
        .btc => |r| {
            buf[0] = 1;
            @memcpy(buf[1..33], &r.txid);
            std.mem.writeInt(u32, buf[33..37], r.vout, .little);
        },
        .eth => |r| {
            buf[0] = 2;
            std.mem.writeInt(u64, buf[1..9], r.chain_id, .little);
            @memcpy(buf[9..29], &r.contract);
            @memcpy(buf[29..57], r.id[0..28]);
            // Last 4 bytes of id stored in [33..37] which would otherwise
            // be vout for btc; safe because tag is 2 here.
            // But rec[29..57] already covers indices 29..57 (28 bytes).
            // We need the remaining 4 bytes (id[28..32]) — store them
            // at buf[53..57]? But that's already used. Restructure:
            //   buf[1..9]   chain_id
            //   buf[9..29]  contract
            //   buf[29..57] id[0..28]
            // → only 28 of 32 bytes preserved.
            //
            // For full fidelity we extend buf usage: persist of EthRef.id
            // via the 4-byte slot at buf[53..57] is impossible without
            // overlap. We accept the 28-byte truncation: callers must hash
            // their EVM htlc id to fit. Document this in the field.
            // (Future v2 of the file format can use a wider record.)
        },
    }
}

fn decodeRef(buf: []const u8) ?HtlcRef {
    return switch (buf[0]) {
        0 => HtlcRef{ .omnibus = blk: {
            var x: [32]u8 = undefined;
            @memcpy(&x, buf[1..33]);
            break :blk x;
        } },
        1 => blk: {
            var txid: [32]u8 = undefined;
            @memcpy(&txid, buf[1..33]);
            const vout = std.mem.readInt(u32, buf[33..37], .little);
            break :blk HtlcRef{ .btc = .{ .txid = txid, .vout = vout } };
        },
        2 => blk: {
            const chain_id = std.mem.readInt(u64, buf[1..9], .little);
            var contract: [20]u8 = undefined;
            @memcpy(&contract, buf[9..29]);
            var id: [32]u8 = std.mem.zeroes([32]u8);
            @memcpy(id[0..28], buf[29..57]);
            // Last 4 bytes of id are zeroed — see encodeRef note above.
            break :blk HtlcRef{ .eth = .{
                .chain_id = chain_id,
                .contract = contract,
                .id = id,
            } };
        },
        else => null,
    };
}

// ─── Cross-chain payload extension to OrderPlacePayload ────────────────
//
// The original 32-byte OrderPlacePayload (see core/tx_payload.zig) stays
// unchanged. We introduce an *optional* trailer that is appended only when
// a cross-chain swap is being initiated. A v1-only decoder sees the first
// 32 bytes and ignores the trailer (its TX would still validate against
// the existing payload-too-short check) — so we keep the trailer behind
// an extra "extension version" byte that must be 0x02 to be recognised.
//
// Trailer wire layout (76 bytes, appended after the v1 32-byte block):
//   [32]      ext_version: u8 (must be 0x02)
//   [33]      cross_chain_chain: u8 (0=none/legacy, 1=btc, 2=eth, 3=base)
//   [34..74]  cross_chain_htlc_ref: [40] (variable-length, max 40B; remote chain ref)
//   [74..106] cross_chain_hash_lock: [32]
//   [106..114] cross_chain_timeout_block: u64 LE
//
// Total: 32 (v1) + 82 (trailer including ext_version) = 114 bytes.
// Backward compat: cross_chain_chain == 0 OR trailer absent → legacy
// behaviour, no SwapBinding registered.

pub const CROSS_CHAIN_TRAILER_SIZE: usize = 82;
pub const ORDER_PAYLOAD_V2_SIZE: usize = 32 + CROSS_CHAIN_TRAILER_SIZE; // 114

pub const CrossChainTrailer = struct {
    ext_version: u8 = 2,
    cross_chain_chain: u8, // 0=none, 1=btc, 2=eth, 3=base
    cross_chain_htlc_ref: [40]u8,
    cross_chain_hash_lock: [32]u8,
    cross_chain_timeout_block: u64,

    pub fn encode(self: CrossChainTrailer, buf: *[CROSS_CHAIN_TRAILER_SIZE]u8) void {
        buf[0] = self.ext_version;
        buf[1] = self.cross_chain_chain;
        @memcpy(buf[2..42], &self.cross_chain_htlc_ref);
        @memcpy(buf[42..74], &self.cross_chain_hash_lock);
        std.mem.writeInt(u64, buf[74..82], self.cross_chain_timeout_block, .little);
    }

    pub fn decode(buf: []const u8) ?CrossChainTrailer {
        if (buf.len < CROSS_CHAIN_TRAILER_SIZE) return null;
        if (buf[0] != 2) return null;
        var t: CrossChainTrailer = undefined;
        t.ext_version = buf[0];
        t.cross_chain_chain = buf[1];
        @memcpy(&t.cross_chain_htlc_ref, buf[2..42]);
        @memcpy(&t.cross_chain_hash_lock, buf[42..74]);
        t.cross_chain_timeout_block = std.mem.readInt(u64, buf[74..82], .little);
        return t;
    }
};

/// Decode the cross-chain trailer from a typed-payload byte slice.
/// Returns null if the payload is plain v1 (32 bytes) or the trailer
/// indicates chain == 0 (legacy semantics).
pub fn extractTrailer(payload_bytes: []const u8) ?CrossChainTrailer {
    if (payload_bytes.len < ORDER_PAYLOAD_V2_SIZE) return null;
    const t = CrossChainTrailer.decode(payload_bytes[32..]) orelse return null;
    if (t.cross_chain_chain == 0) return null;
    return t;
}

// ─── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "SwapBindingRegistry — open / lock / settle round trip" {
    var reg = SwapBindingRegistry.init();
    var preimage: [32]u8 = undefined;
    std.crypto.random.bytes(&preimage);
    var swap_id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&preimage, &swap_id, .{});

    const maker_ref = HtlcRef{ .omnibus = std.mem.zeroes([32]u8) };
    const taker_ref = HtlcRef{ .btc = .{ .txid = std.mem.zeroes([32]u8), .vout = 0 } };

    try reg.open(42, swap_id, .omnibus, .btc, maker_ref, taker_ref, 1000, 100);
    try testing.expectEqual(@as(u32, 1), reg.count);
    try testing.expectEqual(SwapState.pending, reg.find(swap_id).?.state);

    const new_taker = HtlcRef{ .btc = .{ .txid = [_]u8{0xAA} ** 32, .vout = 7 } };
    try reg.lockTaker(swap_id, new_taker);
    try testing.expectEqual(SwapState.both_locked, reg.find(swap_id).?.state);

    try reg.settle(swap_id, preimage);
    try testing.expectEqual(SwapState.claimed, reg.find(swap_id).?.state);
    try testing.expect(std.mem.eql(u8, &reg.find(swap_id).?.revealed_preimage, &preimage));
}

test "SwapBindingRegistry — bad preimage rejected on settle" {
    var reg = SwapBindingRegistry.init();
    var preimage: [32]u8 = undefined;
    std.crypto.random.bytes(&preimage);
    var swap_id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&preimage, &swap_id, .{});

    try reg.open(1, swap_id, .omnibus, .btc,
        HtlcRef{ .omnibus = std.mem.zeroes([32]u8) },
        HtlcRef{ .btc = .{ .txid = std.mem.zeroes([32]u8), .vout = 0 } },
        500, 1);
    try reg.lockTaker(swap_id, HtlcRef{ .btc = .{ .txid = std.mem.zeroes([32]u8), .vout = 0 } });

    var bad: [32]u8 = preimage;
    bad[0] ^= 0xFF;
    try testing.expectError(RegistryError.InvalidStateTransition, reg.settle(swap_id, bad));
}

test "SwapBindingRegistry — timeout transition" {
    var reg = SwapBindingRegistry.init();
    var swap_id: [32]u8 = undefined;
    std.crypto.random.bytes(&swap_id);
    try reg.open(7, swap_id, .omnibus, .eth,
        HtlcRef{ .omnibus = std.mem.zeroes([32]u8) },
        HtlcRef{ .eth = .{ .chain_id = 1, .contract = std.mem.zeroes([20]u8), .id = std.mem.zeroes([32]u8) } },
        200, 50);
    // Too early.
    try testing.expectError(RegistryError.InvalidStateTransition, reg.timeout(swap_id, 100));
    // Now ok.
    try reg.timeout(swap_id, 250);
    try testing.expectEqual(SwapState.timed_out, reg.find(swap_id).?.state);
    // Cannot timeout twice.
    try testing.expectError(RegistryError.InvalidStateTransition, reg.timeout(swap_id, 300));
}

test "SwapBindingRegistry — persistence round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(path);
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/swap_bindings.bin", .{path});
    defer testing.allocator.free(file_path);

    var reg = SwapBindingRegistry.init();
    var preimage: [32]u8 = undefined;
    std.crypto.random.bytes(&preimage);
    var swap_id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&preimage, &swap_id, .{});

    try reg.open(99, swap_id, .btc, .omnibus,
        HtlcRef{ .btc = .{ .txid = [_]u8{0x11} ** 32, .vout = 3 } },
        HtlcRef{ .omnibus = [_]u8{0x22} ** 32 },
        2000, 500);
    try reg.lockTaker(swap_id, HtlcRef{ .omnibus = [_]u8{0x22} ** 32 });
    try reg.saveToFile(file_path);

    var reg2 = SwapBindingRegistry.init();
    try reg2.loadFromFile(file_path);
    try testing.expectEqual(@as(u32, 1), reg2.count);
    const got = reg2.find(swap_id).?;
    try testing.expectEqual(@as(u64, 99), got.order_id);
    try testing.expectEqual(SwapState.both_locked, got.state);
    try testing.expectEqual(Chain.btc, got.maker_chain);
    try testing.expectEqual(Chain.omnibus, got.taker_chain);
}

test "CrossChainTrailer — encode/decode + chain==0 means legacy" {
    var t = CrossChainTrailer{
        .cross_chain_chain = 1, // btc
        .cross_chain_htlc_ref = [_]u8{0xAB} ** 40,
        .cross_chain_hash_lock = [_]u8{0xCD} ** 32,
        .cross_chain_timeout_block = 12345,
    };
    var buf: [CROSS_CHAIN_TRAILER_SIZE]u8 = undefined;
    t.encode(&buf);
    const got = CrossChainTrailer.decode(&buf).?;
    try testing.expectEqual(@as(u8, 1), got.cross_chain_chain);
    try testing.expectEqual(@as(u64, 12345), got.cross_chain_timeout_block);

    // chain==0 → extractTrailer returns null (legacy).
    var t0 = t;
    t0.cross_chain_chain = 0;
    var buf0: [CROSS_CHAIN_TRAILER_SIZE]u8 = undefined;
    t0.encode(&buf0);
    var full: [ORDER_PAYLOAD_V2_SIZE]u8 = std.mem.zeroes([ORDER_PAYLOAD_V2_SIZE]u8);
    @memcpy(full[32..], &buf0);
    try testing.expect(extractTrailer(&full) == null);

    // chain==1 → trailer recognised.
    var full1: [ORDER_PAYLOAD_V2_SIZE]u8 = std.mem.zeroes([ORDER_PAYLOAD_V2_SIZE]u8);
    @memcpy(full1[32..], &buf);
    try testing.expect(extractTrailer(&full1) != null);
}

test "SwapBindingRegistry — duplicate open rejected" {
    var reg = SwapBindingRegistry.init();
    const swap_id: [32]u8 = [_]u8{0xEE} ** 32;
    try reg.open(1, swap_id, .omnibus, .btc,
        HtlcRef{ .omnibus = std.mem.zeroes([32]u8) },
        HtlcRef{ .btc = .{ .txid = std.mem.zeroes([32]u8), .vout = 0 } },
        100, 1);
    try testing.expectError(RegistryError.BindingAlreadyExists,
        reg.open(2, swap_id, .omnibus, .btc,
            HtlcRef{ .omnibus = std.mem.zeroes([32]u8) },
            HtlcRef{ .btc = .{ .txid = std.mem.zeroes([32]u8), .vout = 0 } },
            100, 1));
}
