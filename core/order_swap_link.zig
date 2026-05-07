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
    btc     = 1,
    eth     = 2,   // Ethereum Sepolia (chain_id 11155111)
    base    = 3,   // Base Sepolia     (chain_id 84532)
    liberty = 4,   // LCX Liberty      (chain_id 76847801)

    pub fn fromU8(v: u8) ?Chain {
        return switch (v) {
            0 => .omnibus,
            1 => .btc,
            2 => .eth,
            3 => .base,
            4 => .liberty,
            else => null,
        };
    }

    /// EVM chain_id for EthRef encoding (0 for non-EVM chains).
    pub fn evmChainId(self: Chain) u64 {
        return switch (self) {
            .eth     => 11155111,
            .base    => 84532,
            .liberty => 76847801,
            else     => 0,
        };
    }

    pub fn label(self: Chain) []const u8 {
        return switch (self) {
            .omnibus => "OmniBus",
            .btc     => "Bitcoin",
            .eth     => "Sepolia",
            .base    => "Base Sepolia",
            .liberty => "LCX Liberty",
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

    // Layout: 1B tag + max(32, 36, 60) body = 61B
    //   omnibus(0): tag(1) + id(32)           = 33B used, padded to 61
    //   btc(1):     tag(1) + txid(32) + vout(4) = 37B used, padded to 61
    //   eth(2):     tag(1) + chain_id(8) + contract(20) + id(32) = 61B exact
    pub const WIRE_SIZE: usize = 61;

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
                @memcpy(buf[29..61], &r.id);
            },
        }
    }

    pub fn decode(buf: *const [WIRE_SIZE]u8) ?HtlcRef {
        return switch (buf[0]) {
            0 => HtlcRef{ .omnibus = buf[1..33].* },
            1 => blk: {
                const vout = std.mem.readInt(u32, buf[33..37], .little);
                break :blk HtlcRef{ .btc = .{ .txid = buf[1..33].*, .vout = vout } };
            },
            2 => HtlcRef{ .eth = .{
                .chain_id = std.mem.readInt(u64, buf[1..9], .little),
                .contract = buf[9..29].*,
                .id = buf[29..61].*,
            } },
            else => null,
        };
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

    const MAGIC: [8]u8 = [_]u8{ 'O', 'M', 'N', 'I', 'S', 'W', 'P', '2' };
    const VERSION: u32 = 2;
    const HEADER_SIZE: usize = 8 + 4 + 4; // magic + version + count

    /// Wire layout per entry (deterministic, fixed-size):
    ///   [0..8]     order_id u64 LE
    ///   [8..40]    swap_id [32]
    ///   [40]       maker_chain u8
    ///   [41]       taker_chain u8
    ///   [42..103]  maker_htlc_ref (HtlcRef.WIRE_SIZE = 61 B)
    ///   [103..164] taker_htlc_ref (61 B)
    ///   [164]      state u8
    ///   [165..173] timeout_block u64 LE
    ///   [173..181] created_block u64 LE
    ///   [181..213] revealed_preimage [32]
    /// total = 213 B
    const ENTRY_SIZE: usize = 213;

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
            e.maker_htlc_ref.encode(rec[42..103][0..61]);
            e.taker_htlc_ref.encode(rec[103..164][0..61]);
            rec[164] = @intFromEnum(e.state);
            std.mem.writeInt(u64, rec[165..173], e.timeout_block, .little);
            std.mem.writeInt(u64, rec[173..181], e.created_block, .little);
            @memcpy(rec[181..213], &e.revealed_preimage);
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
            e.maker_htlc_ref = HtlcRef.decode(rec[42..103][0..61]) orelse return RegistryError.CorruptFile;
            e.taker_htlc_ref = HtlcRef.decode(rec[103..164][0..61]) orelse return RegistryError.CorruptFile;
            e.state = switch (rec[164]) {
                0 => .pending,
                1 => .both_locked,
                2 => .claimed,
                3 => .timed_out,
                else => return RegistryError.CorruptFile,
            };
            e.timeout_block = std.mem.readInt(u64, rec[165..173], .little);
            e.created_block = std.mem.readInt(u64, rec[173..181], .little);
            @memcpy(&e.revealed_preimage, rec[181..213]);
            self.entries[self.count] = e;
            self.count += 1;
        }
    }
};

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

// ─── Pair routing table ────────────────────────────────────────────────
//
// Each trading pair maps to two chains + two HTLC contract addresses.
// Maker always provides the BASE asset, taker provides the QUOTE asset.
//
//   pair_id 0: OMNI/USDC  — maker locks OMNI on OmniBus (nativ), taker locks USDC on Base
//   pair_id 1: BTC/USDC   — future (BTC HTLC + Base USDC)
//   pair_id 2: LCX/USDC   — maker locks LCX on Liberty, taker locks USDC on Base
//   pair_id 3: ETH/USDC   — maker locks ETH on Sepolia, taker locks USDC on Base
//   pair_id 4: OMNI/BTC   — future
//   pair_id 5: OMNI/LCX   — maker locks OMNI on OmniBus (nativ), taker locks LCX on Liberty
//   pair_id 6: OMNI/ETH   — maker locks OMNI on OmniBus (nativ), taker locks ETH on Sepolia
//   pair_id 7: LCX/ETH    — maker locks LCX on Liberty, taker locks ETH on Sepolia

// ─── HTLC contract addresses per EVM chain ─────────────────────────────
// Same OmnibusHTLC.sol deployed on all 3 chains (slot1/slot6 wallets).

pub const HTLC_CONTRACT_SEPOLIA  = "270D74dDAccd7a4ABf668DA6F9b238c042353739"; // Sepolia slot6
pub const HTLC_CONTRACT_BASE     = "8396666C7345D5AFA4BBcd2Dcea3B6C8B9096eB6"; // Base slot1
pub const HTLC_CONTRACT_LIBERTY  = "a4ad3f9bA14500F6F1d991b0D8F897E0E8eDEfFb"; // Liberty slot1

/// HTLC contract address for a given EVM chain (hex, no 0x prefix).
/// Returns empty string for non-EVM chains (OmniBus uses native htlc.zig).
pub fn htlcContractFor(chain: Chain) []const u8 {
    return switch (chain) {
        .eth     => HTLC_CONTRACT_SEPOLIA,
        .base    => HTLC_CONTRACT_BASE,
        .liberty => HTLC_CONTRACT_LIBERTY,
        else     => "",
    };
}

// ─── Asset → accepted chains mapping ──────────────────────────────────
//
// Each asset can live on multiple chains. When a maker/taker places or
// accepts an order, they pick which chain they want to use from this list.
// The OmniBus node accepts HTLC refs from ANY chain in the list.
//
//   OMNI  → OmniBus chain only (native)
//   LCX   → Liberty testnet (native), NOT on ETH/Base testnet yet
//   ETH   → Sepolia, Base Sepolia (WETH on Base counts as ETH here)
//   USDC  → Sepolia (Circle USDC), Base Sepolia (Circle USDC)

pub const AssetChains = struct {
    asset:    []const u8,
    /// chains[0] is the preferred/default chain for this asset
    chains:   []const Chain,
};

const ETH_CHAINS   = [_]Chain{ .eth, .base };       // Sepolia preferred
const USDC_CHAINS  = [_]Chain{ .base, .eth };        // Base preferred (more USDC liquidity)
const LCX_CHAINS   = [_]Chain{ .liberty };
const OMNI_CHAINS  = [_]Chain{ .omnibus };

pub const ASSET_CHAINS = [_]AssetChains{
    .{ .asset = "OMNI", .chains = &OMNI_CHAINS },
    .{ .asset = "LCX",  .chains = &LCX_CHAINS  },
    .{ .asset = "ETH",  .chains = &ETH_CHAINS   },
    .{ .asset = "USDC", .chains = &USDC_CHAINS  },
};

pub fn chainsForAsset(asset: []const u8) []const Chain {
    for (&ASSET_CHAINS) |*a| {
        if (std.mem.eql(u8, a.asset, asset)) return a.chains;
    }
    return &[_]Chain{};
}

// ─── 3 trading pairs ───────────────────────────────────────────────────
// pair_id matches exchange matching engine (rpc_server.zig pairIdToLabel).
// Maker always sells BASE asset, taker always sells QUOTE asset.
// Both sides can use any chain from ASSET_CHAINS for their asset.

pub const PairRoute = struct {
    pair_id:     u16,
    base_asset:  []const u8,
    quote_asset: []const u8,
};

pub const PAIR_ROUTES = [_]PairRoute{
    .{ .pair_id = 0, .base_asset = "OMNI", .quote_asset = "USDC" },
    .{ .pair_id = 2, .base_asset = "LCX",  .quote_asset = "USDC" },
    .{ .pair_id = 3, .base_asset = "ETH",  .quote_asset = "USDC" },
    .{ .pair_id = 5, .base_asset = "OMNI", .quote_asset = "LCX"  },
    .{ .pair_id = 6, .base_asset = "OMNI", .quote_asset = "ETH"  },
};

pub fn routeForPair(pair_id: u16) ?*const PairRoute {
    for (&PAIR_ROUTES) |*r| {
        if (r.pair_id == pair_id) return r;
    }
    return null;
}

// ───────────────────────────────────────────────────────────────────────

pub const CROSS_CHAIN_TRAILER_SIZE: usize = 82;
pub const ORDER_PAYLOAD_V2_SIZE: usize = 32 + CROSS_CHAIN_TRAILER_SIZE; // 114

pub const CrossChainTrailer = struct {
    ext_version: u8 = 2,
    cross_chain_chain: u8, // 0=none, 1=btc, 2=eth, 3=base, 4=liberty
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

test "HtlcRef.encode/decode — EthRef preserves all 32 bytes of id" {
    const eth_id = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20,
    };
    const ref = HtlcRef{ .eth = .{
        .chain_id = 0xDEADBEEFCAFEBABE,
        .contract = [_]u8{0xFF} ** 20,
        .id = eth_id,
    } };
    var buf: [HtlcRef.WIRE_SIZE]u8 = undefined;
    ref.encode(&buf);
    const got = HtlcRef.decode(&buf).?;
    try testing.expectEqual(ref.eth.chain_id, got.eth.chain_id);
    try testing.expectEqualSlices(u8, &ref.eth.contract, &got.eth.contract);
    try testing.expectEqualSlices(u8, &eth_id, &got.eth.id);
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
