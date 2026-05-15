//! tx_payload.zig — Phase-2A typed-payload encoding for typed TXs.
//!
//! Each TxType (other than .transfer) carries a binary tagged payload in
//! Transaction.data. This module owns the wire format: encoders, decoders,
//! and per-type validation.
//!
//! Wire format conventions (matches Phase-2A design doc):
//!   - All multi-byte ints are little-endian.
//!   - Variable-length fields are length-prefixed with a single u16 LE.
//!   - Addresses are length-prefixed UTF-8 (max 64 bytes).
//!   - Hashes/keys are fixed 32-byte arrays.
//!   - No padding, no canonical-form ambiguity — the same struct → same bytes.
//!
//! This file deliberately avoids JSON, RLP, and protobuf to keep the
//! encoder ~50 lines per type, hand-auditable, and trivially deterministic.

const std = @import("std");
const transaction_mod = @import("transaction.zig");

const TxType = transaction_mod.TxType;

pub const PayloadError = error{
    PayloadTooShort,
    PayloadTooLong,
    InvalidVersion,
    InvalidSide,
    InvalidPair,
    InvalidPrice,
    InvalidAmount,
    InvalidExpiry,
    InvalidAddress,
    InvalidChainId,
    InvalidPreimage,
    InvalidTimelock,
    UnknownPayloadType,
    BufferOverflow,
};

/// Side of an order. Same byte values as matching_engine.zig Side enum
/// (kept identical so we can cast directly without translation).
pub const Side = enum(u8) {
    buy = 0,
    sell = 1,
};

// ─── 0x10 — OrderPlace ─────────────────────────────────────────────────

/// Payload for TxType.order_place.
/// Wire layout (deterministic, fixed where possible):
///   [0]      version: u8 (currently 1)
///   [1-2]    pair_id: u16 LE
///   [3]      side: u8 (0=buy, 1=sell)
///   [4-11]   price_micro_usd: u64 LE
///   [12-19]  amount_sat: u64 LE
///   [20-23]  expiry_block: u32 LE   (0 = no expiry)
///   [24-31]  nonce: u64 LE          (per-trader strictly increasing)
///   total: 32 bytes (fits well under MAX_TYPED_PAYLOAD=4096)
pub const OrderPlacePayload = struct {
    version: u8 = 1,
    pair_id: u16,
    side: Side,
    price_micro_usd: u64,
    amount_sat: u64,
    expiry_block: u32 = 0,
    nonce: u64,

    pub const WIRE_SIZE: usize = 32;

    pub fn encode(self: OrderPlacePayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        std.mem.writeInt(u16, buf[1..3], self.pair_id, .little);
        buf[3] = @intFromEnum(self.side);
        std.mem.writeInt(u64, buf[4..12], self.price_micro_usd, .little);
        std.mem.writeInt(u64, buf[12..20], self.amount_sat, .little);
        std.mem.writeInt(u32, buf[20..24], self.expiry_block, .little);
        std.mem.writeInt(u64, buf[24..32], self.nonce, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!OrderPlacePayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        const ver = data[0];
        if (ver != 1) return PayloadError.InvalidVersion;
        const side_byte = data[3];
        if (side_byte > 1) return PayloadError.InvalidSide;
        return OrderPlacePayload{
            .version = ver,
            .pair_id = std.mem.readInt(u16, data[1..3], .little),
            .side = @enumFromInt(side_byte),
            .price_micro_usd = std.mem.readInt(u64, data[4..12], .little),
            .amount_sat = std.mem.readInt(u64, data[12..20], .little),
            .expiry_block = std.mem.readInt(u32, data[20..24], .little),
            .nonce = std.mem.readInt(u64, data[24..32], .little),
        };
    }

    pub fn validate(self: OrderPlacePayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.price_micro_usd == 0) return PayloadError.InvalidPrice;
        if (self.amount_sat == 0) return PayloadError.InvalidAmount;
    }
};

/// Optional cross-chain trailer appended *after* the 32-byte v1
/// OrderPlacePayload to bind the order to a remote-chain HTLC.
///
/// Backward compatibility:
///   - 32-byte payload (no trailer)            → legacy Omnibus-only order.
///   - 32-byte v1 + 82-byte trailer with chain=0 → legacy semantics
///     (the trailer is structurally present but inert).
///   - 32-byte v1 + 82-byte trailer with chain in 1..3 → cross-chain order;
///     blockchain.applyOrderTxs will register a SwapBinding and the
///     matching engine still places the order normally so the on-chain
///     side can be filled by another local trader who agrees to the swap.
///
/// Wire layout (82 bytes):
///   [0]      ext_version: u8 (must be 2)
///   [1]      cross_chain_chain: u8 (0=none, 1=btc, 2=eth, 3=base)
///   [2..42]  cross_chain_htlc_ref: [40] (variable-length, max 40B)
///   [42..74] cross_chain_hash_lock: [32]
///   [74..82] cross_chain_timeout_block: u64 LE
pub const OrderCrossChainTrailer = struct {
    ext_version: u8 = 2,
    cross_chain_chain: u8,
    cross_chain_htlc_ref: [40]u8,
    cross_chain_hash_lock: [32]u8,
    cross_chain_timeout_block: u64,

    pub const WIRE_SIZE: usize = 82;

    pub fn encode(self: OrderCrossChainTrailer, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.ext_version;
        buf[1] = self.cross_chain_chain;
        @memcpy(buf[2..42], &self.cross_chain_htlc_ref);
        @memcpy(buf[42..74], &self.cross_chain_hash_lock);
        std.mem.writeInt(u64, buf[74..82], self.cross_chain_timeout_block, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!OrderCrossChainTrailer {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 2) return PayloadError.InvalidVersion;
        if (data[1] > 3) return PayloadError.InvalidChainId;
        var t: OrderCrossChainTrailer = undefined;
        t.ext_version = data[0];
        t.cross_chain_chain = data[1];
        @memcpy(&t.cross_chain_htlc_ref, data[2..42]);
        @memcpy(&t.cross_chain_hash_lock, data[42..74]);
        t.cross_chain_timeout_block = std.mem.readInt(u64, data[74..82], .little);
        return t;
    }
};

/// Try to decode an OrderPlacePayload + (optional) cross-chain trailer.
/// Returns null trailer for legacy 32-byte payloads or chain==0.
pub fn decodeOrderPlaceWithTrailer(data: []const u8) PayloadError!struct {
    order: OrderPlacePayload,
    trailer: ?OrderCrossChainTrailer,
} {
    const order = try OrderPlacePayload.decode(data);
    if (data.len < OrderPlacePayload.WIRE_SIZE + OrderCrossChainTrailer.WIRE_SIZE) {
        return .{ .order = order, .trailer = null };
    }
    const t = OrderCrossChainTrailer.decode(data[OrderPlacePayload.WIRE_SIZE..]) catch {
        return .{ .order = order, .trailer = null };
    };
    if (t.cross_chain_chain == 0) return .{ .order = order, .trailer = null };
    return .{ .order = order, .trailer = t };
}

// ─── 0x11 — OrderCancel ────────────────────────────────────────────────

/// Payload for TxType.order_cancel.
/// Wire layout:
///   [0]     version: u8 (1)
///   [1-8]   order_id: u64 LE
///   [9-16]  nonce: u64 LE
///   total: 17 bytes
pub const OrderCancelPayload = struct {
    version: u8 = 1,
    order_id: u64,
    nonce: u64,

    pub const WIRE_SIZE: usize = 17;

    pub fn encode(self: OrderCancelPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        std.mem.writeInt(u64, buf[1..9], self.order_id, .little);
        std.mem.writeInt(u64, buf[9..17], self.nonce, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!OrderCancelPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        return OrderCancelPayload{
            .version = data[0],
            .order_id = std.mem.readInt(u64, data[1..9], .little),
            .nonce = std.mem.readInt(u64, data[9..17], .little),
        };
    }

    pub fn validate(self: OrderCancelPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.order_id == 0) return PayloadError.InvalidAmount; // 0 is reserved
    }
};

// ─── 0x13 — TradeFill ──────────────────────────────────────────────────

/// Payload for TxType.trade_fill — chain-synthesized receipt when two
/// orders match in the matching engine. Emitted once per fill so each
/// participant has a permanent, queryable record in their wallet TX list.
///
/// `from_address` on the parent Transaction is the SELLER (debited OMNI);
/// `to_address` is the BUYER (credited OMNI). `amount` is the OMNI base
/// in SAT. The counterparty is derivable from from/to so we don't repeat
/// it here — instead the payload carries pair/price/quote-side metadata.
///
/// Wire layout (deterministic, fixed):
///   [0]      version: u8 (1)
///   [1-2]    pair_id: u16 LE
///   [3]      taker_side: u8 (0=buy taker, 1=sell taker)
///   [4-11]   price_micro_usd: u64 LE
///   [12-19]  amount_sat: u64 LE             (= parent TX amount, kept for audit)
///   [20-27]  fill_id: u64 LE                (matching engine internal id)
///   [28-35]  buy_order_id: u64 LE
///   [36-43]  sell_order_id: u64 LE
///   [44-51]  evm_chain_id: u64 LE           (0 = OMNI-only fill, no EVM leg)
///   [52-83]  evm_settle_tx_hash: [32]u8     (zero until settler confirms)
///   total: 84 bytes
pub const TradeFillPayload = struct {
    version: u8 = 1,
    pair_id: u16,
    taker_side: Side,
    price_micro_usd: u64,
    amount_sat: u64,
    fill_id: u64,
    buy_order_id: u64,
    sell_order_id: u64,
    evm_chain_id: u64 = 0,
    evm_settle_tx_hash: [32]u8 = [_]u8{0} ** 32,

    pub const WIRE_SIZE: usize = 84;

    pub fn encode(self: TradeFillPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        std.mem.writeInt(u16, buf[1..3], self.pair_id, .little);
        buf[3] = @intFromEnum(self.taker_side);
        std.mem.writeInt(u64, buf[4..12], self.price_micro_usd, .little);
        std.mem.writeInt(u64, buf[12..20], self.amount_sat, .little);
        std.mem.writeInt(u64, buf[20..28], self.fill_id, .little);
        std.mem.writeInt(u64, buf[28..36], self.buy_order_id, .little);
        std.mem.writeInt(u64, buf[36..44], self.sell_order_id, .little);
        std.mem.writeInt(u64, buf[44..52], self.evm_chain_id, .little);
        @memcpy(buf[52..84], &self.evm_settle_tx_hash);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!TradeFillPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        const side_byte = data[3];
        if (side_byte > 1) return PayloadError.InvalidSide;
        var out = TradeFillPayload{
            .version = data[0],
            .pair_id = std.mem.readInt(u16, data[1..3], .little),
            .taker_side = @enumFromInt(side_byte),
            .price_micro_usd = std.mem.readInt(u64, data[4..12], .little),
            .amount_sat = std.mem.readInt(u64, data[12..20], .little),
            .fill_id = std.mem.readInt(u64, data[20..28], .little),
            .buy_order_id = std.mem.readInt(u64, data[28..36], .little),
            .sell_order_id = std.mem.readInt(u64, data[36..44], .little),
            .evm_chain_id = std.mem.readInt(u64, data[44..52], .little),
            .evm_settle_tx_hash = undefined,
        };
        @memcpy(&out.evm_settle_tx_hash, data[52..84]);
        return out;
    }

    pub fn validate(self: TradeFillPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.amount_sat == 0) return PayloadError.InvalidAmount;
        if (self.fill_id == 0) return PayloadError.InvalidAmount;
        if (self.buy_order_id == 0 or self.sell_order_id == 0) return PayloadError.InvalidAmount;
    }
};

// ─── 0x20 — BridgeLock ─────────────────────────────────────────────────

/// Payload for TxType.bridge_lock — user locks OMNI on this chain,
/// requesting release of equivalent value on the destination chain.
/// Wire layout:
///   [0]      version: u8 (1)
///   [1-2]    dest_chain_id: u16 LE (CAIP-2 numeric: 1=ETH, 0=BTC, 8453=Base, …)
///   [3-34]   dest_addr: [32]u8 (left-padded; for 20-byte EVM use 12 zero prefix)
///   [35-42]  amount_sat: u64 LE
///   [43-50]  min_out: u64 LE (slippage protection)
///   [51-54]  deadline_block: u32 LE
///   total: 55 bytes
pub const BridgeLockPayload = struct {
    version: u8 = 1,
    dest_chain_id: u16,
    dest_addr: [32]u8,
    amount_sat: u64,
    min_out: u64,
    deadline_block: u32,

    pub const WIRE_SIZE: usize = 55;

    pub fn encode(self: BridgeLockPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        std.mem.writeInt(u16, buf[1..3], self.dest_chain_id, .little);
        @memcpy(buf[3..35], &self.dest_addr);
        std.mem.writeInt(u64, buf[35..43], self.amount_sat, .little);
        std.mem.writeInt(u64, buf[43..51], self.min_out, .little);
        std.mem.writeInt(u32, buf[51..55], self.deadline_block, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!BridgeLockPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = BridgeLockPayload{
            .version = data[0],
            .dest_chain_id = std.mem.readInt(u16, data[1..3], .little),
            .dest_addr = undefined,
            .amount_sat = std.mem.readInt(u64, data[35..43], .little),
            .min_out = std.mem.readInt(u64, data[43..51], .little),
            .deadline_block = std.mem.readInt(u32, data[51..55], .little),
        };
        @memcpy(&p.dest_addr, data[3..35]);
        return p;
    }

    pub fn validate(self: BridgeLockPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.dest_chain_id == 0) return PayloadError.InvalidChainId;
        if (self.amount_sat == 0) return PayloadError.InvalidAmount;
    }
};

// ─── 0x22 — BridgeUnlockRequest ────────────────────────────────────────

/// Payload for TxType.bridge_unlock_request — user requests withdraw
/// of OMNI/proxy from this chain to recipient on a source chain.
/// Wire layout:
///   [0]      version: u8 (1)
///   [1-2]    src_chain_id: u16 LE
///   [3-34]   recipient_addr: [32]u8 (left-padded)
///   [35-42]  amount_sat: u64 LE
///   [43-50]  nonce: u64 LE
///   total: 51 bytes
pub const BridgeUnlockRequestPayload = struct {
    version: u8 = 1,
    src_chain_id: u16,
    recipient_addr: [32]u8,
    amount_sat: u64,
    nonce: u64,

    pub const WIRE_SIZE: usize = 51;

    pub fn encode(self: BridgeUnlockRequestPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        std.mem.writeInt(u16, buf[1..3], self.src_chain_id, .little);
        @memcpy(buf[3..35], &self.recipient_addr);
        std.mem.writeInt(u64, buf[35..43], self.amount_sat, .little);
        std.mem.writeInt(u64, buf[43..51], self.nonce, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!BridgeUnlockRequestPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = BridgeUnlockRequestPayload{
            .version = data[0],
            .src_chain_id = std.mem.readInt(u16, data[1..3], .little),
            .recipient_addr = undefined,
            .amount_sat = std.mem.readInt(u64, data[35..43], .little),
            .nonce = std.mem.readInt(u64, data[43..51], .little),
        };
        @memcpy(&p.recipient_addr, data[3..35]);
        return p;
    }

    pub fn validate(self: BridgeUnlockRequestPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.src_chain_id == 0) return PayloadError.InvalidChainId;
        if (self.amount_sat == 0) return PayloadError.InvalidAmount;
    }
};

// ─── 0x30 — HtlcInit ───────────────────────────────────────────────────

/// Payload for TxType.htlc_init — lock OMNI under hash H for T blocks.
/// Wire layout:
///   [0]      version: u8 (1)
///   [1-32]   hash_lock: [32]u8 (sha256 of preimage)
///   [33-36]  timelock_block: u32 LE
///   [37-44]  amount_sat: u64 LE
///   total: 45 bytes
pub const HtlcInitPayload = struct {
    version: u8 = 1,
    hash_lock: [32]u8,
    timelock_block: u32,
    amount_sat: u64,

    pub const WIRE_SIZE: usize = 45;

    pub fn encode(self: HtlcInitPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        @memcpy(buf[1..33], &self.hash_lock);
        std.mem.writeInt(u32, buf[33..37], self.timelock_block, .little);
        std.mem.writeInt(u64, buf[37..45], self.amount_sat, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!HtlcInitPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = HtlcInitPayload{
            .version = data[0],
            .hash_lock = undefined,
            .timelock_block = std.mem.readInt(u32, data[33..37], .little),
            .amount_sat = std.mem.readInt(u64, data[37..45], .little),
        };
        @memcpy(&p.hash_lock, data[1..33]);
        return p;
    }

    pub fn validate(self: HtlcInitPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.timelock_block == 0) return PayloadError.InvalidTimelock;
        if (self.amount_sat == 0) return PayloadError.InvalidAmount;
    }
};

// ─── 0x31 — HtlcClaim ──────────────────────────────────────────────────

/// Payload for TxType.htlc_claim — recipient reveals preimage to claim
/// the locked OMNI from a previously-init'd HTLC.
/// Wire layout:
///   [0]      version: u8 (1)
///   [1-32]   htlc_id: [32]u8 (sha256d of the htlc_init TX hash, deterministic)
///   [33-64]  preimage: [32]u8 (sha256(preimage) MUST match init's hash_lock)
///   total: 65 bytes
pub const HtlcClaimPayload = struct {
    version: u8 = 1,
    htlc_id: [32]u8,
    preimage: [32]u8,

    pub const WIRE_SIZE: usize = 65;

    pub fn encode(self: HtlcClaimPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        @memcpy(buf[1..33], &self.htlc_id);
        @memcpy(buf[33..65], &self.preimage);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!HtlcClaimPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = HtlcClaimPayload{
            .version = data[0],
            .htlc_id = undefined,
            .preimage = undefined,
        };
        @memcpy(&p.htlc_id, data[1..33]);
        @memcpy(&p.preimage, data[33..65]);
        return p;
    }

    pub fn validate(self: HtlcClaimPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        // No further structural checks — the chain layer verifies that
        // sha256(preimage) == hash_lock against the registered HTLC.
        _ = self.htlc_id;
    }
};

// ─── 0x32 — HtlcRefund ─────────────────────────────────────────────────

/// Payload for TxType.htlc_refund — original sender reclaims funds after
/// the timelock has elapsed and no claim was made.
/// Wire layout:
///   [0]      version: u8 (1)
///   [1-32]   htlc_id: [32]u8
///   total: 33 bytes
pub const HtlcRefundPayload = struct {
    version: u8 = 1,
    htlc_id: [32]u8,

    pub const WIRE_SIZE: usize = 33;

    pub fn encode(self: HtlcRefundPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        @memcpy(buf[1..33], &self.htlc_id);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!HtlcRefundPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = HtlcRefundPayload{
            .version = data[0],
            .htlc_id = undefined,
        };
        @memcpy(&p.htlc_id, data[1..33]);
        return p;
    }

    pub fn validate(self: HtlcRefundPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        _ = self.htlc_id;
    }
};

// ─── 0x40 — IntentPost ─────────────────────────────────────────────────

/// Payload for TxType.intent_post — maker broadcasts a cross-chain intent
/// ("I want to sell X on Omnibus and receive Y on chain Z"). Solvers/takers
/// pick this up and commit to fill it via 0x41.
///
/// Wire layout (deterministic, fixed-size, 89 bytes):
///   [0]      version: u8 (1)
///   [1..33]  intent_id: [32]u8
///   [33..65] swap_id: [32]u8 (binds the intent to a SwapBinding / hash_lock)
///   [65..69] expiry_block: u32 LE
///   [69]     taker_chain: u8 (0=omnibus, 1=btc, 2=eth, 3=base)
///   [70..78] maker_amount_sat: u64 LE
///   [78..86] taker_min_sat: u64 LE (slippage bound)
///   [86..88] reserved: u16 (zero)
///   [88]     ext_flags: u8 (bit0 = has off-chain trailer; reserved, must be 0 in v1)
pub const IntentPostPayload = struct {
    version: u8 = 1,
    intent_id: [32]u8,
    swap_id: [32]u8,
    expiry_block: u32,
    taker_chain: u8,
    maker_amount_sat: u64,
    taker_min_sat: u64,
    reserved: u16 = 0,
    ext_flags: u8 = 0,

    pub const WIRE_SIZE: usize = 89;

    pub fn encode(self: IntentPostPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        @memcpy(buf[1..33], &self.intent_id);
        @memcpy(buf[33..65], &self.swap_id);
        std.mem.writeInt(u32, buf[65..69], self.expiry_block, .little);
        buf[69] = self.taker_chain;
        std.mem.writeInt(u64, buf[70..78], self.maker_amount_sat, .little);
        std.mem.writeInt(u64, buf[78..86], self.taker_min_sat, .little);
        std.mem.writeInt(u16, buf[86..88], self.reserved, .little);
        buf[88] = self.ext_flags;
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!IntentPostPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = IntentPostPayload{
            .version = data[0],
            .intent_id = undefined,
            .swap_id = undefined,
            .expiry_block = std.mem.readInt(u32, data[65..69], .little),
            .taker_chain = data[69],
            .maker_amount_sat = std.mem.readInt(u64, data[70..78], .little),
            .taker_min_sat = std.mem.readInt(u64, data[78..86], .little),
            .reserved = std.mem.readInt(u16, data[86..88], .little),
            .ext_flags = data[88],
        };
        @memcpy(&p.intent_id, data[1..33]);
        @memcpy(&p.swap_id, data[33..65]);
        return p;
    }

    pub fn validate(self: IntentPostPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.expiry_block == 0) return PayloadError.InvalidExpiry;
        if (self.taker_chain > 3) return PayloadError.InvalidChainId;
        if (self.maker_amount_sat == 0) return PayloadError.InvalidAmount;
        if (self.ext_flags != 0) return PayloadError.InvalidVersion;
    }
};

// ─── 0x41 — IntentFillCommit ───────────────────────────────────────────

/// Payload for TxType.intent_fill_commit — solver locks bond, commits to
/// fill an open intent. The Omnibus chain debits `bond_locked_sat` from
/// the taker; if the taker fails to deliver before expiry, intent_timeout
/// (0x43) slashes that bond to the maker.
///
/// Wire layout (49 bytes):
///   [0]      version: u8 (1)
///   [1..33]  intent_id: [32]u8
///   [33..41] bond_locked_sat: u64 LE
///   [41..49] commit_block: u64 LE (Omnibus block at which the commit is
///                                  expected to be applied; informational —
///                                  consensus uses block.index, not this.)
pub const IntentFillCommitPayload = struct {
    version: u8 = 1,
    intent_id: [32]u8,
    bond_locked_sat: u64,
    commit_block: u64,

    pub const WIRE_SIZE: usize = 49;

    pub fn encode(self: IntentFillCommitPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        @memcpy(buf[1..33], &self.intent_id);
        std.mem.writeInt(u64, buf[33..41], self.bond_locked_sat, .little);
        std.mem.writeInt(u64, buf[41..49], self.commit_block, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!IntentFillCommitPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = IntentFillCommitPayload{
            .version = data[0],
            .intent_id = undefined,
            .bond_locked_sat = std.mem.readInt(u64, data[33..41], .little),
            .commit_block = std.mem.readInt(u64, data[41..49], .little),
        };
        @memcpy(&p.intent_id, data[1..33]);
        return p;
    }

    pub fn validate(self: IntentFillCommitPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        if (self.bond_locked_sat == 0) return PayloadError.InvalidAmount;
    }
};

// ─── 0x43 — IntentTimeout ──────────────────────────────────────────────

/// Payload for TxType.intent_timeout — solver missed the deadline; bond
/// slashed to the maker (or burned, depending on policy). The chain layer
/// validates that current_block >= expiry stored at commit time.
///
/// Wire layout (41 bytes):
///   [0]      version: u8 (1)
///   [1..33]  intent_id: [32]u8
///   [33..41] slashed_bond_sat: u64 LE
pub const IntentTimeoutPayload = struct {
    version: u8 = 1,
    intent_id: [32]u8,
    slashed_bond_sat: u64,

    pub const WIRE_SIZE: usize = 41;

    pub fn encode(self: IntentTimeoutPayload, buf: []u8) PayloadError!usize {
        if (buf.len < WIRE_SIZE) return PayloadError.BufferOverflow;
        buf[0] = self.version;
        @memcpy(buf[1..33], &self.intent_id);
        std.mem.writeInt(u64, buf[33..41], self.slashed_bond_sat, .little);
        return WIRE_SIZE;
    }

    pub fn decode(data: []const u8) PayloadError!IntentTimeoutPayload {
        if (data.len < WIRE_SIZE) return PayloadError.PayloadTooShort;
        if (data[0] != 1) return PayloadError.InvalidVersion;
        var p = IntentTimeoutPayload{
            .version = data[0],
            .intent_id = undefined,
            .slashed_bond_sat = std.mem.readInt(u64, data[33..41], .little),
        };
        @memcpy(&p.intent_id, data[1..33]);
        return p;
    }

    pub fn validate(self: IntentTimeoutPayload) PayloadError!void {
        if (self.version != 1) return PayloadError.InvalidVersion;
        // slashed_bond_sat = 0 IS valid: the maker may waive the slash.
    }
};

// ─── Validation dispatcher ─────────────────────────────────────────────

/// Validates the payload bytes against the declared TxType.
/// Performs structural validation only (decode + range checks).
/// Cross-state validation (e.g., "does this trader have balance for the
/// order?", "is the bridge nonce already processed?") happens in the
/// blockchain consensus layer, not here.
pub fn validatePayload(tx_type: TxType, data: []const u8) PayloadError!void {
    switch (tx_type) {
        .transfer => {
            if (data.len > 0) return PayloadError.PayloadTooLong;
        },
        .order_place => {
            const p = try OrderPlacePayload.decode(data);
            try p.validate();
            // Optional cross-chain trailer (append-only, backward compat).
            if (data.len >= OrderPlacePayload.WIRE_SIZE + OrderCrossChainTrailer.WIRE_SIZE) {
                _ = try OrderCrossChainTrailer.decode(data[OrderPlacePayload.WIRE_SIZE..]);
            } else if (data.len > OrderPlacePayload.WIRE_SIZE) {
                // Trailing bytes that aren't a full trailer → reject as
                // ambiguous (a v1 client would silently accept this and
                // diverge from a v2 client).
                return PayloadError.PayloadTooLong;
            }
        },
        .order_cancel => {
            const p = try OrderCancelPayload.decode(data);
            try p.validate();
        },
        .trade_fill => {
            const p = try TradeFillPayload.decode(data);
            try p.validate();
        },
        .bridge_lock => {
            const p = try BridgeLockPayload.decode(data);
            try p.validate();
        },
        .bridge_unlock_request => {
            const p = try BridgeUnlockRequestPayload.decode(data);
            try p.validate();
        },
        .htlc_init => {
            const p = try HtlcInitPayload.decode(data);
            try p.validate();
        },
        .htlc_claim => {
            const p = try HtlcClaimPayload.decode(data);
            try p.validate();
        },
        .htlc_refund => {
            const p = try HtlcRefundPayload.decode(data);
            try p.validate();
        },
        .intent_post => {
            const p = try IntentPostPayload.decode(data);
            try p.validate();
        },
        .intent_fill_commit => {
            const p = try IntentFillCommitPayload.decode(data);
            try p.validate();
        },
        .intent_timeout => {
            const p = try IntentTimeoutPayload.decode(data);
            try p.validate();
        },
        // Other types are reserved — accept payload bytes but no decoder yet.
        // These will be filled in as their respective phases land.
        .order_modify,
        .bridge_deposit_report,
        .bridge_unlock_sign,
        .bridge_fraud_challenge,
        .intent_settle,
        .tss_dkg_commit,
        .tss_dkg_finalize,
        .tss_vault_rotate,
        .governance,
        => {
            // Accept any non-empty payload up to MAX_TYPED_PAYLOAD;
            // strict per-type decoders land in their respective phases.
            if (data.len == 0) return PayloadError.PayloadTooShort;
        },
        _ => return PayloadError.UnknownPayloadType,
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "OrderPlacePayload round-trip" {
    const orig = OrderPlacePayload{
        .pair_id = 1,
        .side = .sell,
        .price_micro_usd = 50_000_000_000, // 50 USD
        .amount_sat = 1_000_000_000,        // 1 OMNI
        .expiry_block = 100,
        .nonce = 42,
    };
    var buf: [OrderPlacePayload.WIRE_SIZE]u8 = undefined;
    const written = try orig.encode(&buf);
    try std.testing.expectEqual(@as(usize, OrderPlacePayload.WIRE_SIZE), written);

    const decoded = try OrderPlacePayload.decode(&buf);
    try std.testing.expectEqual(orig.pair_id, decoded.pair_id);
    try std.testing.expectEqual(orig.side, decoded.side);
    try std.testing.expectEqual(orig.price_micro_usd, decoded.price_micro_usd);
    try std.testing.expectEqual(orig.amount_sat, decoded.amount_sat);
    try std.testing.expectEqual(orig.expiry_block, decoded.expiry_block);
    try std.testing.expectEqual(orig.nonce, decoded.nonce);
}

test "OrderPlacePayload rejects invalid side" {
    var buf = [_]u8{0} ** OrderPlacePayload.WIRE_SIZE;
    buf[0] = 1; // version
    buf[3] = 99; // invalid side
    try std.testing.expectError(PayloadError.InvalidSide, OrderPlacePayload.decode(&buf));
}

test "OrderCancelPayload round-trip" {
    const orig = OrderCancelPayload{ .order_id = 12345, .nonce = 7 };
    var buf: [OrderCancelPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const decoded = try OrderCancelPayload.decode(&buf);
    try std.testing.expectEqual(orig.order_id, decoded.order_id);
    try std.testing.expectEqual(orig.nonce, decoded.nonce);
}

test "validatePayload transfer rejects non-empty data" {
    try std.testing.expectError(PayloadError.PayloadTooLong, validatePayload(.transfer, "garbage"));
}

test "validatePayload accepts empty for transfer" {
    try validatePayload(.transfer, "");
}

test "OrderCrossChainTrailer round-trip" {
    const orig = OrderCrossChainTrailer{
        .cross_chain_chain = 1,
        .cross_chain_htlc_ref = [_]u8{0xAB} ** 40,
        .cross_chain_hash_lock = [_]u8{0xCD} ** 32,
        .cross_chain_timeout_block = 999,
    };
    var buf: [OrderCrossChainTrailer.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const got = try OrderCrossChainTrailer.decode(&buf);
    try std.testing.expectEqual(orig.cross_chain_chain, got.cross_chain_chain);
    try std.testing.expectEqual(orig.cross_chain_timeout_block, got.cross_chain_timeout_block);
}

test "decodeOrderPlaceWithTrailer — legacy 32-byte payload" {
    const orig = OrderPlacePayload{
        .pair_id = 1,
        .side = .buy,
        .price_micro_usd = 1_000_000,
        .amount_sat = 1000,
        .nonce = 1,
    };
    var buf: [OrderPlacePayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const got = try decodeOrderPlaceWithTrailer(&buf);
    try std.testing.expect(got.trailer == null);
    try std.testing.expectEqual(orig.amount_sat, got.order.amount_sat);
}

test "decodeOrderPlaceWithTrailer — v2 with cross-chain trailer" {
    const order = OrderPlacePayload{
        .pair_id = 2,
        .side = .sell,
        .price_micro_usd = 500_000,
        .amount_sat = 5000,
        .nonce = 9,
    };
    const trailer = OrderCrossChainTrailer{
        .cross_chain_chain = 2, // eth
        .cross_chain_htlc_ref = [_]u8{0x12} ** 40,
        .cross_chain_hash_lock = [_]u8{0x34} ** 32,
        .cross_chain_timeout_block = 10000,
    };
    const TOTAL = OrderPlacePayload.WIRE_SIZE + OrderCrossChainTrailer.WIRE_SIZE;
    var buf: [TOTAL]u8 = undefined;
    _ = try order.encode(buf[0..OrderPlacePayload.WIRE_SIZE]);
    _ = try trailer.encode(buf[OrderPlacePayload.WIRE_SIZE..]);
    const got = try decodeOrderPlaceWithTrailer(&buf);
    try std.testing.expect(got.trailer != null);
    try std.testing.expectEqual(@as(u8, 2), got.trailer.?.cross_chain_chain);
    try std.testing.expectEqual(@as(u64, 10000), got.trailer.?.cross_chain_timeout_block);
    // validatePayload also accepts it.
    try validatePayload(.order_place, &buf);
}

test "validatePayload OrderPlace rejects too-short" {
    try std.testing.expectError(PayloadError.PayloadTooShort, validatePayload(.order_place, &[_]u8{1}));
}

test "HtlcInitPayload round-trip" {
    var hl: [32]u8 = undefined;
    @memset(&hl, 0xAB);
    const orig = HtlcInitPayload{
        .hash_lock = hl,
        .timelock_block = 12345,
        .amount_sat = 1_000_000_000,
    };
    var buf: [HtlcInitPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const dec = try HtlcInitPayload.decode(&buf);
    try std.testing.expectEqual(orig.timelock_block, dec.timelock_block);
    try std.testing.expectEqual(orig.amount_sat, dec.amount_sat);
    try std.testing.expectEqualSlices(u8, &orig.hash_lock, &dec.hash_lock);
}

test "HtlcClaimPayload round-trip" {
    var hid: [32]u8 = undefined; @memset(&hid, 0x11);
    var pim: [32]u8 = undefined; @memset(&pim, 0x22);
    const orig = HtlcClaimPayload{ .htlc_id = hid, .preimage = pim };
    var buf: [HtlcClaimPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const dec = try HtlcClaimPayload.decode(&buf);
    try std.testing.expectEqualSlices(u8, &orig.htlc_id, &dec.htlc_id);
    try std.testing.expectEqualSlices(u8, &orig.preimage, &dec.preimage);
}

test "HtlcRefundPayload round-trip" {
    var hid: [32]u8 = undefined; @memset(&hid, 0x33);
    const orig = HtlcRefundPayload{ .htlc_id = hid };
    var buf: [HtlcRefundPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const dec = try HtlcRefundPayload.decode(&buf);
    try std.testing.expectEqualSlices(u8, &orig.htlc_id, &dec.htlc_id);
}

test "validatePayload htlc_claim rejects too-short" {
    try std.testing.expectError(PayloadError.PayloadTooShort, validatePayload(.htlc_claim, &[_]u8{1}));
}

test "validatePayload htlc_refund rejects too-short" {
    try std.testing.expectError(PayloadError.PayloadTooShort, validatePayload(.htlc_refund, &[_]u8{1}));
}

test "IntentPostPayload round-trip" {
    var iid: [32]u8 = undefined; @memset(&iid, 0xAB);
    var sid: [32]u8 = undefined; @memset(&sid, 0xCD);
    const orig = IntentPostPayload{
        .intent_id = iid,
        .swap_id = sid,
        .expiry_block = 12345,
        .taker_chain = 2, // eth
        .maker_amount_sat = 1_000_000_000,
        .taker_min_sat = 999_000_000,
    };
    var buf: [IntentPostPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const dec = try IntentPostPayload.decode(&buf);
    try std.testing.expectEqualSlices(u8, &orig.intent_id, &dec.intent_id);
    try std.testing.expectEqualSlices(u8, &orig.swap_id, &dec.swap_id);
    try std.testing.expectEqual(orig.expiry_block, dec.expiry_block);
    try std.testing.expectEqual(orig.taker_chain, dec.taker_chain);
    try std.testing.expectEqual(orig.maker_amount_sat, dec.maker_amount_sat);
    try std.testing.expectEqual(orig.taker_min_sat, dec.taker_min_sat);
    try orig.validate();
    try validatePayload(.intent_post, &buf);
}

test "IntentPostPayload rejects invalid taker_chain" {
    var iid: [32]u8 = undefined; @memset(&iid, 0x01);
    var sid: [32]u8 = undefined; @memset(&sid, 0x02);
    const bad = IntentPostPayload{
        .intent_id = iid, .swap_id = sid,
        .expiry_block = 1, .taker_chain = 99,
        .maker_amount_sat = 1, .taker_min_sat = 1,
    };
    try std.testing.expectError(PayloadError.InvalidChainId, bad.validate());
}

test "IntentFillCommitPayload round-trip" {
    var iid: [32]u8 = undefined; @memset(&iid, 0x44);
    const orig = IntentFillCommitPayload{
        .intent_id = iid,
        .bond_locked_sat = 5_000_000_000,
        .commit_block = 777,
    };
    var buf: [IntentFillCommitPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const dec = try IntentFillCommitPayload.decode(&buf);
    try std.testing.expectEqualSlices(u8, &orig.intent_id, &dec.intent_id);
    try std.testing.expectEqual(orig.bond_locked_sat, dec.bond_locked_sat);
    try std.testing.expectEqual(orig.commit_block, dec.commit_block);
    try validatePayload(.intent_fill_commit, &buf);
}

test "IntentFillCommitPayload rejects zero bond" {
    var iid: [32]u8 = undefined; @memset(&iid, 0x55);
    const bad = IntentFillCommitPayload{
        .intent_id = iid, .bond_locked_sat = 0, .commit_block = 1,
    };
    try std.testing.expectError(PayloadError.InvalidAmount, bad.validate());
}

test "IntentTimeoutPayload round-trip" {
    var iid: [32]u8 = undefined; @memset(&iid, 0x66);
    const orig = IntentTimeoutPayload{
        .intent_id = iid,
        .slashed_bond_sat = 2_500_000_000,
    };
    var buf: [IntentTimeoutPayload.WIRE_SIZE]u8 = undefined;
    _ = try orig.encode(&buf);
    const dec = try IntentTimeoutPayload.decode(&buf);
    try std.testing.expectEqualSlices(u8, &orig.intent_id, &dec.intent_id);
    try std.testing.expectEqual(orig.slashed_bond_sat, dec.slashed_bond_sat);
    try validatePayload(.intent_timeout, &buf);
}

test "validatePayload intent_post rejects too-short" {
    try std.testing.expectError(PayloadError.PayloadTooShort, validatePayload(.intent_post, &[_]u8{1}));
}
