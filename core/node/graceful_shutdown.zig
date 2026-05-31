// core/node/graceful_shutdown.zig
//
// Graceful shutdown sequence — saves all persistent state before the
// `defer` cleanups in main() run. Extracted from main.zig to keep the
// entry point readable; the call site in main.zig is a single
// `runGracefulShutdown(.{ ... })` invocation.
//
// Order of operations (must stay in this order):
//   1. Stop background state-save thread (avoid race with final save).
//   2. Save PersistentBlockchain (full chain dump).
//   3. Checkpoint + close g_chainstate (dump memtable, truncate WAL).
//   4. Save DNS registry (names registered after last auto-save).
//   5. Save HTLC registry (pending/claimed states must survive).
//   6. Save payment channels (open channels would leak locked funds).
//   7. Save intent registry (bonds posted at intent_post / fill_commit).
//   8. Save peer ban list (bans survive the restart).
//   9. Print final summary.

const std = @import("std");

const database_mod      = @import("../database.zig");
const blockchain_mod    = @import("../blockchain.zig");
const dns_mod           = @import("../dns_registry.zig");
const peer_scoring_mod  = @import("../peer_scoring.zig");
const payment_mod       = @import("../payment_channel.zig");
const chainstate_mod    = @import("../store/chainstate.zig");

const state_save_mod    = @import("state_save.zig");
const peer_persist_mod  = @import("../peer_persist.zig");
const htlc_persist      = @import("../htlc_persist.zig");
const channel_persist   = @import("../channel_persist.zig");

const PersistentBlockchain = database_mod.PersistentBlockchain;
const Blockchain           = blockchain_mod.Blockchain;
const DnsRegistry          = dns_mod.DnsRegistry;
const PeerScoringEngine    = peer_scoring_mod.PeerScoringEngine;
const ChannelManager       = payment_mod.ChannelManager;
const ChainState           = chainstate_mod.ChainState;

pub const ShutdownContext = struct {
    pbc: *PersistentBlockchain,
    bc: *Blockchain,
    db_path: []const u8,
    chainstate: *?ChainState,
    dns: *DnsRegistry,
    dns_persist_path: []const u8,
    htlc_persist_path: []const u8,
    channel_mgr: *ChannelManager,
    channels_path: []const u8,
    intent_persist_path: []const u8,
    peer_scoring: *PeerScoringEngine,
    peer_bans_path: []const u8,
};

pub fn runGracefulShutdown(ctx: ShutdownContext) void {
    std.debug.print("\n[SHUTDOWN] Saving chain to disc...\n", .{});

    // Stop the background state-save thread first so it doesn't race with
    // the final shutdown save. join() blocks until the worker finishes its
    // current iteration; in the worst case we wait one save-interval.
    state_save_mod.stopStateSaveThread();

    ctx.pbc.saveBlockchain(ctx.bc, ctx.db_path) catch |err| {
        std.debug.print("[SHUTDOWN] Save failed: {} — data may be lost!\n", .{err});
    };
    // PHASE-C.4: final chainstate checkpoint + close. The checkpoint
    // dumps the memtable to .snap and truncates the WAL, so the next
    // startup loads in O(1) instead of replaying every WAL record.
    if (ctx.chainstate.*) |*cs| {
        cs.checkpoint() catch |err| {
            std.debug.print("[SHUTDOWN] chainstate checkpoint failed: {}\n", .{err});
        };
        cs.close();
        std.debug.print("[SHUTDOWN] chainstate checkpointed and closed\n", .{});
    }
    // Save DNS registry too — names registered after last auto-save would be lost otherwise.
    ctx.dns.saveToFile(ctx.dns_persist_path) catch |err| {
        std.debug.print("[SHUTDOWN] DNS save failed: {s}\n", .{@errorName(err)});
    };
    // Save HTLC registry — same reasoning: pending/claimed states must survive.
    htlc_persist.saveToFile(&ctx.bc.htlc_registry, ctx.htlc_persist_path) catch |err| {
        std.debug.print("[SHUTDOWN] HTLC save failed: {s}\n", .{@errorName(err)});
    };
    // Save payment channels — open channels would otherwise leak locked funds.
    channel_persist.saveToFile(ctx.channel_mgr, ctx.channels_path) catch |err| {
        std.debug.print("[SHUTDOWN] Channels save failed: {s}\n", .{@errorName(err)});
    };
    // Save intent registry — bonds locked at intent_post / fill_commit
    // must survive restart so they can still be settled / refunded.
    ctx.bc.intent_registry.saveToFile(ctx.intent_persist_path) catch |err| {
        std.debug.print("[SHUTDOWN] Intent registry save failed: {s}\n", .{@errorName(err)});
    };
    // Save peer ban list so bans survive the restart.
    peer_persist_mod.saveToFile(ctx.peer_scoring, ctx.peer_bans_path) catch |err| {
        std.debug.print("[SHUTDOWN] Peer ban save failed: {s}\n", .{@errorName(err)});
    };
    std.debug.print("[SHUTDOWN] Saved {d} blocks, {d} addresses, {d} names\n", .{ ctx.bc.chain.items.len, ctx.bc.balances.count(), ctx.dns.entry_count });
    std.debug.print("[SHUTDOWN] Cleaning up (P2P, WS, wallet via defer)... Goodbye!\n", .{});
    // p2p.deinit(), ws_srv.deinit(), bc.deinit(), pbc.deinit() etc. run via defer
}
