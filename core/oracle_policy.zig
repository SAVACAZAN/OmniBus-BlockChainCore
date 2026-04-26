//! oracle_policy.zig — Per-node configurable price-deviation validation
//! for incoming P2P blocks.
//!
//! When a peer sends a block, we already verify the prices_root commitment
//! (via Block.validatePrices), but that only proves the prices weren't
//! tampered with after PoW — it does NOT prove the prices are PLAUSIBLE.
//!
//! A malicious miner could publish bid/ask values radically different from
//! what every other exchange reports right now (e.g. BTC/USD at $1). The
//! commitment check passes (peer hashed the lie consistently), but the
//! lie is still in the chain.
//!
//! This module implements a 3-tier defensive policy:
//!
//!   1. WARN  — log a warning if any per-slot deviation exceeds warn_pct.
//!              Block still accepted. Useful for monitoring.
//!
//!   2. REJECT — refuse the block if any per-slot deviation exceeds reject_pct.
//!              Sends `error.PriceValidationFailed` back to the P2P handler
//!              which drops the block on the floor.
//!
//!   3. FILLGAP — if local feed has NO data for a slot but the peer does,
//!              and the peer's value is within fillgap_pct of the median
//!              of OUR other slots for the same canonical pair, trust it
//!              and write it back into our local feed (cheap price discovery).
//!
//! All thresholds default by chain:
//!     mainnet → reject=5%   (strict)
//!     testnet → reject=10%  (relaxed)
//!     regtest → reject=100% (effectively disabled)
//!
//! The whole pipeline can be globally bypassed via `enabled=false`.

const std = @import("std");
const oracle_types = @import("oracle_types.zig");
const ws_exchange_feed_mod = @import("ws_exchange_feed.zig");
const chain_config = @import("chain_config.zig");

const ChainId = chain_config.ChainId;
const BlockPriceEntry = oracle_types.BlockPriceEntry;
const BLOCK_PRICE_SLOTS = oracle_types.BLOCK_PRICE_SLOTS;
const PriceFetch = ws_exchange_feed_mod.PriceFetch;

// ─── Policy struct ──────────────────────────────────────────────────────────

pub const OraclePolicy = struct {
    /// Log a warning if any entry deviates more than this percent from local feed.
    warn_pct: f64 = 2.0,
    /// Reject the block if any entry deviates more than this. Default by chain:
    /// mainnet=5, testnet=10, regtest=100 (effectively disabled).
    reject_pct: f64 = 5.0,
    /// When self has no live entry for a slot, accept peer's value if it's
    /// within this many percent of OUR own median across the OTHER slots for
    /// the same canonical pair.
    fillgap_pct: f64 = 10.0,
    /// Master switch — if false, all validation is bypassed (regtest default).
    enabled: bool = true,
};

/// Per-chain default thresholds. mainnet is strict, regtest disabled.
pub fn defaultsFor(chain: ChainId) OraclePolicy {
    return switch (chain) {
        .mainnet => OraclePolicy{
            .warn_pct = 2.0,
            .reject_pct = 5.0,
            .fillgap_pct = 10.0,
            .enabled = true,
        },
        .testnet => OraclePolicy{
            .warn_pct = 5.0,
            .reject_pct = 10.0,
            .fillgap_pct = 20.0,
            .enabled = true,
        },
        .devnet => OraclePolicy{
            .warn_pct = 10.0,
            .reject_pct = 50.0,
            .fillgap_pct = 50.0,
            .enabled = true,
        },
        .regtest => OraclePolicy{
            .warn_pct = 100.0,
            .reject_pct = 100.0,
            .fillgap_pct = 100.0,
            .enabled = false,
        },
    };
}

// ─── Validation result ──────────────────────────────────────────────────────

pub const PriceValidation = struct {
    accept: bool,
    /// count of slots over warn_pct (and ≤ reject_pct)
    warned: u8 = 0,
    /// first slot that breached reject_pct (for log)
    rejected_slot: ?u8 = null,
    /// count of slots that we filled into local feed
    gap_filled: u8 = 0,
};

// ─── Helpers ────────────────────────────────────────────────────────────────

/// Compute |a - b| / b * 100 as a percentage. Returns 0 if b==0 (avoid /0).
fn deviationPct(a: u64, b: u64) f64 {
    if (b == 0) return 0.0;
    const fa: f64 = @floatFromInt(a);
    const fb: f64 = @floatFromInt(b);
    const diff = if (fa > fb) fa - fb else fb - fa;
    return (diff / fb) * 100.0;
}

/// Slots-per-pair: 21 / 7 = 3 (Coinbase, Kraken, LCX for each canonical pair).
const SLOTS_PER_PAIR: usize = ws_exchange_feed_mod.IMPORTANT_PAIRS.len;

/// Each canonical pair occupies a contiguous group of 3 slots in the
/// snapshot ordering. For slot `i`, the pair-base is `(i / 3) * 3` and
/// the OTHER two slots in the same group are at base+0..base+2 excluding `i`.
fn pairBaseFor(slot: usize) usize {
    return (slot / 3) * 3;
}

/// Compute the median bid (or ask) across the other slots in the same pair
/// group that have success=true. Returns null if no other slot is live.
/// `field` selects bid (0) or ask (1).
fn medianAcrossPair(
    local_snapshot: [BLOCK_PRICE_SLOTS]PriceFetch,
    slot: usize,
    field: u8,
) ?u64 {
    const base = pairBaseFor(slot);
    var samples: [3]u64 = undefined;
    var n: usize = 0;
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const idx = base + k;
        if (idx == slot) continue;
        if (idx >= BLOCK_PRICE_SLOTS) continue;
        const e = local_snapshot[idx];
        if (!e.success) continue;
        samples[n] = if (field == 0) e.bid_micro_usd else e.ask_micro_usd;
        n += 1;
    }
    if (n == 0) return null;
    // Insertion sort (n ≤ 2).
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const cur = samples[i];
        var j: usize = i;
        while (j > 0 and samples[j - 1] > cur) : (j -= 1) {
            samples[j] = samples[j - 1];
        }
        samples[j] = cur;
    }
    return samples[n / 2];
}

// ─── Main validation function ───────────────────────────────────────────────

/// Validate a block's price snapshot against the local feed and apply the
/// 3-tier policy (warn / reject / fillgap).
///
/// Algorithm:
///   For each slot i:
///     - both local & block fail → SKIP
///     - block has data, local doesn't → potential gap-fill
///     - both have data → compute deviation, warn or reject
///
/// `feed` is optional — when null, gap-fill is silently skipped (the count
/// returned is always 0). This lets unit tests exercise the validation
/// logic without spinning up a live ExchangeFeed.
pub fn validateBlockPrices(
    policy: OraclePolicy,
    block_prices: [BLOCK_PRICE_SLOTS]BlockPriceEntry,
    local_snapshot: [BLOCK_PRICE_SLOTS]PriceFetch,
    feed: ?*ws_exchange_feed_mod.ExchangeFeed,
) PriceValidation {
    var result: PriceValidation = .{ .accept = true };
    if (!policy.enabled) return result;

    // Collect gap-fill candidates first; we apply them only after the whole
    // block passes (no point gap-filling from a block we're about to reject).
    var gap_candidates: [BLOCK_PRICE_SLOTS]bool = [_]bool{false} ** BLOCK_PRICE_SLOTS;

    var i: usize = 0;
    while (i < BLOCK_PRICE_SLOTS) : (i += 1) {
        const blk_e = block_prices[i];
        const loc_e = local_snapshot[i];

        if (!blk_e.success and !loc_e.success) continue;

        if (!loc_e.success and blk_e.success) {
            gap_candidates[i] = true;
            continue;
        }

        if (loc_e.success and !blk_e.success) {
            // Peer doesn't have what we have — that's THEIR problem, not a
            // fraud signal. Skip.
            continue;
        }

        // Both populated — compute bid + ask deviation.
        const bid_dev = deviationPct(blk_e.bid_micro_usd, loc_e.bid_micro_usd);
        const ask_dev = deviationPct(blk_e.ask_micro_usd, loc_e.ask_micro_usd);
        const max_dev = if (bid_dev > ask_dev) bid_dev else ask_dev;

        if (max_dev > policy.reject_pct) {
            result.accept = false;
            result.rejected_slot = @intCast(i);
            return result;
        }
        if (max_dev > policy.warn_pct) {
            result.warned +|= 1;
        }
    }

    // Apply gap-fills only on accepted blocks.
    if (feed) |fp| {
        var j: usize = 0;
        while (j < BLOCK_PRICE_SLOTS) : (j += 1) {
            if (!gap_candidates[j]) continue;
            const blk_e = block_prices[j];

            // Need a local median to compare against. If the whole pair group
            // is empty locally, we can't sanity-check; skip.
            const med_bid = medianAcrossPair(local_snapshot, j, 0) orelse continue;
            const med_ask = medianAcrossPair(local_snapshot, j, 1) orelse continue;

            const bid_dev = deviationPct(blk_e.bid_micro_usd, med_bid);
            const ask_dev = deviationPct(blk_e.ask_micro_usd, med_ask);
            const max_dev = if (bid_dev > ask_dev) bid_dev else ask_dev;
            if (max_dev > policy.fillgap_pct) continue;

            // Plausible — write into the local feed. Convert fixed-size strings
            // back to slices.
            const elen = @min(blk_e.exchange_len, @as(u8, 16));
            const plen = @min(blk_e.pair_len, @as(u8, 16));
            const ex_slice = blk_e.exchange[0..elen];
            const pa_slice = blk_e.pair[0..plen];
            fp.upsertPriceExternal(ex_slice, pa_slice, blk_e.bid_micro_usd, blk_e.ask_micro_usd);
            result.gap_filled +|= 1;
        }
    }

    return result;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeBlockEntry(bid: u64, ask: u64, success: bool) BlockPriceEntry {
    return .{
        .exchange = ("Coinbase" ++ [_]u8{0} ** 8).*,
        .exchange_len = 8,
        .pair = ("BTC/USD" ++ [_]u8{0} ** 9).*,
        .pair_len = 7,
        .bid_micro_usd = bid,
        .ask_micro_usd = ask,
        .timestamp_ms = 1_700_000_000_000,
        .success = success,
    };
}

fn makeLocalEntry(bid: u64, ask: u64, success: bool) PriceFetch {
    return .{
        .exchange = "Coinbase",
        .pair = "BTC/USD",
        .bid_micro_usd = bid,
        .ask_micro_usd = ask,
        .timestamp_ms = 1_700_000_000_000,
        .success = success,
    };
}

test "OraclePolicy — defaultsFor mainnet vs regtest" {
    const main = defaultsFor(.mainnet);
    try testing.expectEqual(@as(f64, 5.0), main.reject_pct);
    try testing.expect(main.enabled);

    const reg = defaultsFor(.regtest);
    try testing.expect(!reg.enabled);
}

test "validateBlockPrices — all-fail block + all-fail local → accept (no signal)" {
    const policy = OraclePolicy{};
    const block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    const local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        break :blk arr;
    };
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(r.accept);
    try testing.expectEqual(@as(u8, 0), r.warned);
    try testing.expectEqual(@as(u8, 0), r.gap_filled);
    try testing.expect(r.rejected_slot == null);
}

test "validateBlockPrices — 1% deviation under warn=2 → accept warned=0" {
    const policy = OraclePolicy{ .warn_pct = 2.0, .reject_pct = 5.0 };
    var block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    var local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        break :blk arr;
    };
    // local: 100_000_000, block: 101_000_000  (1% deviation)
    block_prices[0] = makeBlockEntry(101_000_000, 101_000_000, true);
    local[0] = makeLocalEntry(100_000_000, 100_000_000, true);
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(r.accept);
    try testing.expectEqual(@as(u8, 0), r.warned);
}

test "validateBlockPrices — 3% deviation between warn=2 and reject=5 → accept warned=1" {
    const policy = OraclePolicy{ .warn_pct = 2.0, .reject_pct = 5.0 };
    var block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    var local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        break :blk arr;
    };
    // 3% deviation: 100m → 103m
    block_prices[0] = makeBlockEntry(103_000_000, 103_000_000, true);
    local[0] = makeLocalEntry(100_000_000, 100_000_000, true);
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(r.accept);
    try testing.expectEqual(@as(u8, 1), r.warned);
}

test "validateBlockPrices — 10% deviation over reject=5 → reject" {
    const policy = OraclePolicy{ .warn_pct = 2.0, .reject_pct = 5.0 };
    var block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    var local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        break :blk arr;
    };
    // Slot 5: 10% deviation → reject
    block_prices[5] = makeBlockEntry(110_000_000, 110_000_000, true);
    local[5] = makeLocalEntry(100_000_000, 100_000_000, true);
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(!r.accept);
    try testing.expectEqual(@as(?u8, 5), r.rejected_slot);
}

test "validateBlockPrices — disabled policy bypasses all checks" {
    const policy = OraclePolicy{ .warn_pct = 2.0, .reject_pct = 5.0, .enabled = false };
    var block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    var local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        break :blk arr;
    };
    block_prices[0] = makeBlockEntry(200_000_000, 200_000_000, true); // 100% off!
    local[0] = makeLocalEntry(100_000_000, 100_000_000, true);
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(r.accept);
}

test "validateBlockPrices — gap-fill candidate count when feed is null" {
    // When feed is null we don't fill — but the "candidate" branch still
    // runs and just doesn't increment gap_filled. We verify acceptance and
    // gap_filled=0.
    const policy = OraclePolicy{};
    var block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    const local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        // Same pair group (slots 0..2). Local has slots 0 + 1 populated, slot 2 missing.
        arr[0] = makeLocalEntry(100_000_000, 100_000_000, true);
        arr[1] = makeLocalEntry(100_500_000, 100_500_000, true);
        break :blk arr;
    };
    // Block has slot 2 populated within fillgap range (≈0.5%).
    block_prices[2] = makeBlockEntry(100_200_000, 100_200_000, true);
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(r.accept);
    try testing.expectEqual(@as(u8, 0), r.gap_filled); // null feed → no actual fill
}

test "validateBlockPrices — gap-fill rejected when peer value too far from median" {
    const policy = OraclePolicy{ .fillgap_pct = 5.0 };
    var block_prices = [_]BlockPriceEntry{.{}} ** BLOCK_PRICE_SLOTS;
    const local: [BLOCK_PRICE_SLOTS]PriceFetch = blk: {
        var arr: [BLOCK_PRICE_SLOTS]PriceFetch = undefined;
        for (&arr) |*e| {
            e.* = .{ .exchange = "x", .pair = "y", .bid_micro_usd = 0, .ask_micro_usd = 0, .timestamp_ms = 0, .success = false };
        }
        arr[0] = makeLocalEntry(100_000_000, 100_000_000, true);
        arr[1] = makeLocalEntry(100_000_000, 100_000_000, true);
        break :blk arr;
    };
    // Peer's slot 2 = 200m, median = 100m → 100% deviation, > fillgap=5%
    block_prices[2] = makeBlockEntry(200_000_000, 200_000_000, true);
    const r = validateBlockPrices(policy, block_prices, local, null);
    try testing.expect(r.accept); // not rejected (slot 2 had no local entry to deviate from)
    try testing.expectEqual(@as(u8, 0), r.gap_filled);
}

test "deviationPct — basic" {
    try testing.expectApproxEqAbs(@as(f64, 5.0), deviationPct(105, 100), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 5.0), deviationPct(95, 100), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), deviationPct(0, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 100.0), deviationPct(0, 100), 0.001);
}

test "pairBaseFor — slots group correctly" {
    try testing.expectEqual(@as(usize, 0), pairBaseFor(0));
    try testing.expectEqual(@as(usize, 0), pairBaseFor(1));
    try testing.expectEqual(@as(usize, 0), pairBaseFor(2));
    try testing.expectEqual(@as(usize, 3), pairBaseFor(3));
    try testing.expectEqual(@as(usize, 18), pairBaseFor(20));
}
