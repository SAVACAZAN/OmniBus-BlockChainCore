// core/node/swap_persistence.zig
//
// Init + load helpers for the four cross-chain-swap subsystems that all
// follow the same per-chain on-disk layout:
//
//   - data/<chain>/htlc_registry.bin   — HTLC on-chain registry
//   - data/<chain>/channels.dat        — payment channel manager
//   - data/<chain>/intent_registry.bin — cross-chain intent bonds
//   - Guardian engine                  — in-memory only (no persistence)
//
// Each load helper mirrors the shape of node/peer_persistence.zig: caller
// owns the path_buf, helper writes into it via bufPrint and returns the
// resolved path slice so periodic-save call sites in the mining loop can
// reuse it without re-formatting. Periodic save / shutdown save remain
// inline at the call site.
//
// Guardian has no on-disk state today, but its init lives here so all
// swap-stack startup noise is in one file.

const std            = @import("std");
const htlc_mod       = @import("../htlc.zig");
const htlc_persist   = @import("../htlc_persist.zig");
const payment_mod    = @import("../payment_channel.zig");
const channel_persist = @import("../channel_persist.zig");
const intent_reg_mod = @import("../intent_registry.zig");
const guardian_mod   = @import("../guardian.zig");

/// HTLC registry persistence: per-chain file at data/<chain>/htlc_registry.bin.
/// bc.htlc_registry is default-initialised inside Blockchain.init; this just
/// loads prior on-disk state so pending/claimed/refunded HTLCs survive a
/// restart. Returns the resolved path for reuse by periodic + shutdown save.
pub fn loadHtlcRegistry(
    registry: *htlc_mod.HtlcOnChainRegistry,
    chain_name: []const u8,
    path_buf: *[256]u8,
) []const u8 {
    const p = std.fmt.bufPrint(
        path_buf,
        "data/{s}/htlc_registry.bin",
        .{chain_name},
    ) catch "data/htlc_registry.bin";
    htlc_persist.loadFromFile(registry, p) catch |err| {
        std.debug.print("[HTLC] Load from {s} failed: {s} (starting empty)\n",
            .{ p, @errorName(err) });
    };
    if (registry.entry_count > 0) {
        std.debug.print("[HTLC] Loaded {d} entries ({d} active) from {s}\n",
            .{ registry.entry_count, registry.activeCount(), p });
    }
    return p;
}

/// Payment-channel persistence: per-chain file at data/<chain>/channels.dat.
/// g_channel_mgr is process-global; load any prior state so open channels
/// and pending closes survive node restart. Returns the resolved path.
pub fn loadPaymentChannels(
    mgr: *payment_mod.ChannelManager,
    chain_name: []const u8,
    path_buf: *[256]u8,
) []const u8 {
    const p = std.fmt.bufPrint(
        path_buf,
        "data/{s}/channels.dat",
        .{chain_name},
    ) catch "data/channels.dat";
    channel_persist.loadFromFile(mgr, p) catch |err| {
        std.debug.print("[CHANNELS] Load from {s} failed: {s} (starting empty)\n",
            .{ p, @errorName(err) });
    };
    if (mgr.channel_count > 0) {
        std.debug.print("[CHANNELS] Loaded {d} channels from {s}\n",
            .{ mgr.channel_count, p });
    }
    return p;
}

/// Intent registry persistence: per-chain file at data/<chain>/intent_registry.bin.
/// Tracks bond accounting for cross-chain intents (maker bond at intent_post,
/// taker bond at fill_commit, both refunded on settle, taker slashed → maker
/// on timeout). Loaded so pending intents survive a node restart; saved on
/// chain auto-save + shutdown by inline call sites.
pub fn loadIntentRegistry(
    registry: *intent_reg_mod.IntentRegistry,
    chain_name: []const u8,
    path_buf: *[256]u8,
) []const u8 {
    const p = std.fmt.bufPrint(
        path_buf,
        "data/{s}/intent_registry.bin",
        .{chain_name},
    ) catch "data/intent_registry.bin";
    registry.loadFromFile(p) catch |err| {
        std.debug.print("[INTENT] Load from {s} failed: {s} (starting empty)\n",
            .{ p, @errorName(err) });
    };
    if (registry.count > 0) {
        std.debug.print("[INTENT] Loaded {d} entries from {s}\n",
            .{ registry.count, p });
    }
    return p;
}

/// Guardian engine init. No on-disk state today; helper exists so all
/// swap-stack startup lives in one file. Returned by value — main.zig
/// stores it in a local `var` and the mining loop reads via .guardedCount().
pub fn initGuardian() guardian_mod.GuardianEngine {
    return guardian_mod.GuardianEngine.init();
}
