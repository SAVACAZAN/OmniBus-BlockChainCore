// core/node/light_loop.zig
// SPV Light Client header sync loop.
//
// Extracted from main.zig (2026-05-30). Periodically requests new headers
// from peers via getheaders; sleeps in 250 ms chunks so SIGTERM unblocks
// within 250 ms instead of hitting systemd's 30 s SIGKILL timeout.

const std = @import("std");
const p2p_mod = @import("../p2p.zig");
const light_client_mod = @import("../light_client.zig");
const shutdown_mod = @import("shutdown.zig");

pub fn runLightLoop(p2p: *p2p_mod.P2PNode, light_client: *light_client_mod.LightClient) void {
    var maint_counter_light: u32 = 0;
    std.debug.print("[LIGHT] Entering SPV header sync loop...\n\n", .{});
    // Send initial Bloom filter + getheaders to all peers
    p2p.sendBloomFilter();
    p2p.syncHeaders();

    while (!shutdown_mod.g_shutdown.load(.monotonic)) {
        // Periodically request new headers (every 10s = 1 block time).
        // Sleep in 250ms chunks so SIGTERM unblocks within 250ms instead
        // of forcing systemd to SIGKILL after 30s timeout (Bug B7).
        var slept_ms: u64 = 0;
        while (slept_ms < 10_000 and !shutdown_mod.g_shutdown.load(.monotonic)) {
            std.Thread.sleep(250 * std.time.ns_per_ms);
            slept_ms += 250;
        }
        if (shutdown_mod.g_shutdown.load(.monotonic)) break;
        p2p.syncHeaders();

        const height = light_client.getHeight();
        const hdr_count = light_client.getHeaderCount();
        if (maint_counter_light % 6 == 0) {
            std.debug.print("[LIGHT] SPV status: {d} headers, height {d}, peers {d}\n",
                .{ hdr_count, height, p2p.peers.items.len });
        }
        maint_counter_light +%= 1;
    }
    std.debug.print("[LIGHT] SPV sync loop exited — shutdown\n", .{});
}
