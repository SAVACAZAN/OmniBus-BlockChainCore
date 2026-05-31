// core/node/p2p_init.zig
//
// Bundle of P2P / SubBlock / Sync / LightClient init blocks extracted from
// main.zig. Same args, same print lines, same behavior.
//
// Notes for caller (main.zig):
//   - `stack.p2p_heap` is heap-allocated; main keeps the existing
//     `defer { stack.p2p_heap.deinit(); allocator.destroy(stack.p2p_heap); }`.
//   - `defer stack.light_client.deinit();` must remain in main.zig.
//   - knock-knock, attachBlockchain, attachLightClient stay in main (they
//     are wiring, not init, and require &bc / sync_mgr live in main scope).

const std = @import("std");

const p2p_mod          = @import("../p2p.zig");
const sub_block_mod    = @import("../sub_block.zig");
const sync_mod         = @import("../sync.zig");
const light_client_mod = @import("../light_client.zig");
const chain_config_mod = @import("../chain_config.zig");

pub const P2PStack = struct {
    p2p_heap:     *p2p_mod.P2PNode,
    sb_engine:    sub_block_mod.SubBlockEngine,
    sync_mgr:     sync_mod.SyncManager,
    light_client: light_client_mod.LightClient,
};

/// Initialize the P2P stack (P2P node + listener + heartbeat + sub-block
/// engine + sync manager + light client). Same prints and behavior as the
/// inline blocks in main.zig.
pub fn initP2PStack(
    allocator:    std.mem.Allocator,
    node_id:      []const u8,
    host:         []const u8,
    port:         u16,
    chain_id:     chain_config_mod.ChainId,
    seed_host:    ?[]const u8,
    seed_port:    ?u16,
    local_height: u64,
) !P2PStack {
    // ── Init P2P Node ─────────────────────────────────────────────────────────
    // P2PNode is ~1.5 MB. We allocate on the heap AND populate in-place via
    // initInPlace() — never via `heap.* = init(...)` because that intermediate
    // value still lives on the stack inside init() and overruns the Linux
    // guard page (silent SEGV right after [SUBSYSTEMS] log).
    const p2p_heap = try allocator.create(p2p_mod.P2PNode);
    p2p_heap.initInPlace(node_id, host, port, allocator);
    p2p_heap.setChainMagic(chain_config_mod.NetworkMagic.forChain(chain_id).bytes);
    // Conecteaza la seed node daca e miner (best-effort, nu blocheaza)
    if (seed_host) |sh| {
        if (seed_port) |sp| {
            p2p_heap.connectToPeer(sh, sp, "seed-primary") catch |err| {
                std.debug.print("[P2P] Seed connect failed (va incerca mai tarziu): {}\n", .{err});
            };
        }
    }
    p2p_heap.printStatus();

    // ── TCP Listener inbound — accepta conexiuni de la alti mineri ────────────
    p2p_heap.startListener() catch |err| {
        std.debug.print("[P2P] Listener failed (port ocupat?): {} — fara inbound\n", .{err});
    };

    // ── Heartbeat — PING periodic catre peers cu inaltimea curenta. Fara asta
    // peer.height ramane stale dupa handshake si IBD se opreste cand consumam
    // toate blocurile vazute la HELLO, chiar daca peer-ul a urcat intre timp.
    p2p_heap.startHeartbeat() catch |err| {
        std.debug.print("[P2P] Heartbeat failed: {} — peer heights vor fi stale\n", .{err});
    };

    // ── SubBlock Engine — 10 × 0.1s → 1 Key-Block ────────────────────────────
    const sb_engine = sub_block_mod.SubBlockEngine.init(node_id, 0, allocator);
    std.debug.print("[SUB-BLOCK] Engine init | {d} sub-blocks × {d}ms = 1s bloc\n\n", .{
        sub_block_mod.SUB_BLOCKS_PER_BLOCK,
        sub_block_mod.SUB_BLOCK_INTERVAL_MS,
    });

    // ── Sync Manager — sincronizare blockchain cu peerii ──────────────────────
    const sync_mgr = sync_mod.SyncManager.init(local_height, allocator);
    std.debug.print("[SYNC] Manager init | local height: {d}\n\n", .{local_height});

    // ── Light Client (SPV) — only for --mode light ──────────────────────────
    const light_client = light_client_mod.LightClient.init(allocator);

    return .{
        .p2p_heap     = p2p_heap,
        .sb_engine    = sb_engine,
        .sync_mgr     = sync_mgr,
        .light_client = light_client,
    };
}
