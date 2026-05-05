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
        },
        .order_cancel => {
            const p = try OrderCancelPayload.decode(data);
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
        // Other types are reserved — accept payload bytes but no decoder yet.
        // These will be filled in as their respective phases land.
        .order_modify,
        .bridge_deposit_report,
        .bridge_unlock_sign,
        .bridge_fraud_challenge,
        .htlc_claim,
        .htlc_refund,
        .intent_post,
        .intent_fill_commit,
        .intent_settle,
        .intent_timeout,
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

test "validatePayload OrderPlace rejects too-short" {
    try std.testing.expectError(PayloadError.PayloadTooShort, validatePayload(.order_place, &[_]u8{1}));
}
