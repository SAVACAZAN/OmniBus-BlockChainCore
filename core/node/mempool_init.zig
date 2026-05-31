// core/node/mempool_init.zig
// Extracted from main.zig (2026-05-31): Mempool FIFO construction + verifier wiring.

const std = @import("std");
const mempool_mod = @import("../mempool.zig");

const Mempool = mempool_mod.Mempool;
const TxVerifierFn = mempool_mod.TxVerifierFn;

/// Constructs the FIFO Mempool and wires the signature verifier callback
/// (HIGH-05 enforcement — both initial submit and RBF check sigs). Without a
/// verifier, the gate stays inactive and an attacker can replace a victim's
/// pending TX with no valid signature.
pub fn initMempool(
    allocator: std.mem.Allocator,
    verifier_ctx: ?*anyopaque,
    verifier_fn: TxVerifierFn,
) !Mempool {
    var mempool = Mempool.init(allocator);
    mempool.verifier_ctx = verifier_ctx;
    mempool.verifier = verifier_fn;
    std.debug.print("[MEMPOOL] FIFO init | Max: {d} TX / {d} KB | Expiry: 14 days | sig_verifier=ON\n\n",
        .{ mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES / 1024 });
    return mempool;
}
