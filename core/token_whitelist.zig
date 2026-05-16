//! token_whitelist.zig — anti-fake-token allowlist for cross-chain pairs.
//!
//! When a buyer locks ERC-20 escrow on the EVM side of an OMNI/<EVM> pair,
//! the matching engine MUST verify the escrowed token contract is the
//! genuine one — not a copy a user deployed at a random address that looks
//! similar. Without this gate, an attacker could lock 5 fake-USDC and walk
//! away with 5 OMNI of real liquidity.
//!
//! Whitelist is hard-coded here (no governance yet) to keep the audit
//! surface minimal. Adding a token requires a code change + node upgrade.
//! When governance lands, this can move to chain state and become editable
//! via a 2/3 validator vote, but the hard-coded list ships now.
//!
//! Lookup is by (pair_id, chain_id, token_addr20). Same token can be
//! whitelisted on multiple chains (e.g. USDC on Sepolia AND Base Sepolia).
//!
//! ETH-native escrows: token_addr20 = all zeros. Whitelisted under pair_id 6
//! (OMNI/ETH) for both Sepolia + Base Sepolia.

const std = @import("std");

/// One entry: a single (pair_id, chain_id, token) tuple that's allowed.
pub const Entry = struct {
    pair_id: u16,
    chain_id: u64,
    token: [20]u8,
    /// Human label for logs/errors. e.g. "USDC (Circle, Sepolia)".
    label: []const u8,
};

/// Sentinel for native gas asset (ETH / Base ETH / Liberty LCX). Watcher
/// sets `token` to all zeros when the escrow was created via
/// `placeBuyOrderNative` — see OmnibusDEX.sol:170.
pub const NATIVE_TOKEN: [20]u8 = [_]u8{0} ** 20;

/// USDC (Circle official) per chain. Smallest unit = 1e-6 USDC.
const USDC_SEPOLIA      = hexToAddr("1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
const USDC_BASE_SEPOLIA = hexToAddr("036CbD53842c5426634e7929541eC2318f3dCF7e");
const USDC_ARB_SEPOLIA  = hexToAddr("75faf114eafb1BDbe2F0316DF893fd58CE46AA4d");
const USDC_OP_SEPOLIA   = hexToAddr("5fd84259d66Cd46123540766Be93DFE6D43130D7");
const USDC_POLYGON_AMOY = hexToAddr("41e94eb019c0762f9bfcf9fb1e58725bfb0e7582");
const USDC_AVAX_FUJI    = hexToAddr("5425890298aed601595a70AB815c96711a31Bc65");

/// EURC (Circle euro stablecoin) per chain.
const EURC_SEPOLIA      = hexToAddr("08210F9170F89Ab7658F0B5E3fF39b0E03C594D4");
const EURC_BASE_SEPOLIA = hexToAddr("808456652fdb597867f38412077A9182bf77359F");

/// The whitelist. Keep alphabetical-by-pair_id; group multi-chain entries.
pub const WHITELIST = [_]Entry{
    // pair_id 0 — OMNI/USDC (Circle official on every chain).
    .{ .pair_id = 0, .chain_id = 11155111, .token = USDC_SEPOLIA,      .label = "USDC (Circle, Sepolia)" },
    .{ .pair_id = 0, .chain_id = 84532,    .token = USDC_BASE_SEPOLIA, .label = "USDC (Circle, Base Sepolia)" },
    .{ .pair_id = 0, .chain_id = 421614,   .token = USDC_ARB_SEPOLIA,  .label = "USDC (Circle, Arb Sepolia)" },
    .{ .pair_id = 0, .chain_id = 11155420, .token = USDC_OP_SEPOLIA,   .label = "USDC (Circle, OP Sepolia)" },
    .{ .pair_id = 0, .chain_id = 80002,    .token = USDC_POLYGON_AMOY, .label = "USDC (Circle, Polygon Amoy)" },
    .{ .pair_id = 0, .chain_id = 43113,    .token = USDC_AVAX_FUJI,    .label = "USDC (Circle, Avalanche Fuji)" },

    // pair_id 6 — OMNI/ETH (native gas asset, no token contract).
    .{ .pair_id = 6, .chain_id = 11155111, .token = NATIVE_TOKEN,      .label = "ETH (native, Sepolia)" },
    .{ .pair_id = 6, .chain_id = 84532,    .token = NATIVE_TOKEN,      .label = "ETH (native, Base Sepolia)" },
    .{ .pair_id = 6, .chain_id = 421614,   .token = NATIVE_TOKEN,      .label = "ETH (native, Arb Sepolia)" },
    .{ .pair_id = 6, .chain_id = 11155420, .token = NATIVE_TOKEN,      .label = "ETH (native, OP Sepolia)" },
    // Polygon Amoy native = MATIC, Avalanche Fuji native = AVAX — different
    // tokens, but the contract stores them under `token=0x0` regardless. The
    // matching engine cares about pair_id, not which native asset; pair_id=6
    // means "native gas asset on the buyer's chain". So we whitelist them
    // too — semantically pair_id=6 is "OMNI/native".
    .{ .pair_id = 6, .chain_id = 80002,    .token = NATIVE_TOKEN,      .label = "MATIC (native, Polygon Amoy)" },
    .{ .pair_id = 6, .chain_id = 43113,    .token = NATIVE_TOKEN,      .label = "AVAX (native, Avalanche Fuji)" },

    // pair_id 1 — OMNI/EURC (Circle euro stablecoin).
    .{ .pair_id = 1, .chain_id = 11155111, .token = EURC_SEPOLIA,      .label = "EURC (Circle, Sepolia)" },
    .{ .pair_id = 1, .chain_id = 84532,    .token = EURC_BASE_SEPOLIA, .label = "EURC (Circle, Base Sepolia)" },

    // Future: pair_id 5 OMNI/LCX on Liberty when RPC is back online.
};

/// Check whether a (pair_id, chain_id, token) tuple is allowed. Returns
/// the matching label on success so callers can log which token landed.
/// Returns `null` if the tuple is NOT in the whitelist — caller must
/// reject the order with a clear error.
pub fn check(pair_id: u16, chain_id: u64, token: [20]u8) ?[]const u8 {
    for (WHITELIST) |e| {
        if (e.pair_id != pair_id) continue;
        if (e.chain_id != chain_id) continue;
        if (!std.mem.eql(u8, &e.token, &token)) continue;
        return e.label;
    }
    return null;
}

// ── Helpers ────────────────────────────────────────────────────────────

/// Compile-time hex-to-[20]u8 — turns "1c7D4B…7238" into the byte array
/// without runtime cost. Caller passes the 40-char address with NO 0x
/// prefix so a typo is caught at compile time (40 != 42).
fn hexToAddr(comptime hex: []const u8) [20]u8 {
    if (hex.len != 40) @compileError("token address must be 40 hex chars (no 0x)");
    var out: [20]u8 = undefined;
    inline for (0..20) |i| {
        out[i] = (nib(hex[i * 2]) << 4) | nib(hex[i * 2 + 1]);
    }
    return out;
}

fn nib(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("non-hex char in token address"),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "whitelist accepts USDC on Sepolia" {
    const usdc_sep = hexToAddr("1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
    try std.testing.expect(check(0, 11155111, usdc_sep) != null);
}

test "whitelist accepts ETH native on Sepolia for pair 6" {
    try std.testing.expect(check(6, 11155111, NATIVE_TOKEN) != null);
}

test "whitelist rejects unknown token on Sepolia" {
    var fake: [20]u8 = [_]u8{0} ** 20;
    fake[0] = 0xde; fake[1] = 0xad;
    try std.testing.expect(check(0, 11155111, fake) == null);
}

test "whitelist rejects USDC routed to wrong pair" {
    const usdc_sep = hexToAddr("1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
    // pair_id 6 expects native ETH, not USDC — reject.
    try std.testing.expect(check(6, 11155111, usdc_sep) == null);
}

test "whitelist rejects USDC on unknown chain" {
    const usdc_sep = hexToAddr("1c7D4B196Cb0C7B01d743Fbc6116a902379C7238");
    try std.testing.expect(check(0, 1, usdc_sep) == null); // ETH mainnet not whitelisted
}
