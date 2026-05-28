// core/node/state_save.zig
//
// Background thread that calls saveBlockchain() on a fixed interval. Decoupled
// from the mining loop so a slow disk write never blocks block production.
// The mining loop holds bc.mutex briefly while applying TXs; the saver also
// takes that mutex to read a coherent snapshot, then writes outside the lock.
//
// Why this exists: commit b363095 disabled in-mining-loop saves to recover
// the p99 latency we lost to "every block does a 50 MB rewrite". The
// trade-off was that balances which weren't materialised as on-chain TXs
// (faucet grants written directly to bc.balances) didn't survive restart.
// Faucet recipients lost ~51 testnet balances at the next restart.
//
// This thread is the temporary fix. The proper fix is the Bitcoin-style
// storage refactor (blocks/blkNNNNN.dat append + chainstate/ KV) tracked
// in arch/leveldb-storage. See ARCH_BITCOIN_STORAGE.md for the full plan.

const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");

pub var g_state_save_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_state_save_thread: ?std.Thread = null;

// Reduced 60s → 30s ca extra safety net pe langa per-block save (vezi
// fix-ul din mining loop dupa applyBlock). Pana cand storage-ul devine
// incremental (Bitcoin-style blkNNNNN.dat), saveToDisc face un rewrite
// monolitic, dar la ~hundreds-of-ms ramane sub block time. Daca per-block
// save esueaza tranzitoriu, thread-ul ăsta prinde state-ul in 30s.
pub const STATE_SAVE_INTERVAL_SEC: i64 = 30;

fn stateSaveLoop(bc: *blockchain_mod.Blockchain) void {
    // First save runs after the interval, not at startup, because the
    // chain has just been restored from disk — saving immediately would
    // be a no-op write of identical bytes. We sleep first.
    while (g_state_save_run.load(.acquire)) {
        var slept_s: i64 = 0;
        while (slept_s < STATE_SAVE_INTERVAL_SEC and g_state_save_run.load(.acquire)) : (slept_s += 1) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
        if (!g_state_save_run.load(.acquire)) break;

        // saveToDisc takes bc.mutex internally for the snapshot read; it
        // does NOT hold it during the actual file write, so a slow disk
        // doesn't stall the mining loop. Worst case the saver itself waits
        // for the mining loop to release the mutex (~ms), which is fine.
        bc.saveToDisc() catch |err| {
            std.debug.print("[DB] Background save failed: {}\n", .{err});
        };
    }
}

pub fn startStateSaveThread(bc: *blockchain_mod.Blockchain) !void {
    if (g_state_save_run.load(.acquire)) return;
    g_state_save_run.store(true, .release);
    g_state_save_thread = try std.Thread.spawn(.{}, stateSaveLoop, .{bc});
    std.debug.print(
        "[DB] Background state-save thread started (interval = {d}s)\n",
        .{STATE_SAVE_INTERVAL_SEC},
    );
}

pub fn stopStateSaveThread() void {
    g_state_save_run.store(false, .release);
    if (g_state_save_thread) |t| {
        t.join();
        g_state_save_thread = null;
    }
}
