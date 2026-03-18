const std = @import("std");
const blockchain_mod = @import("blockchain.zig");
const rpc_mod = @import("rpc_server.zig");
const wallet_mod = @import("wallet.zig");

const Blockchain = blockchain_mod.Blockchain;
const RPCServer = rpc_mod.RPCServer;
const Wallet = wallet_mod.Wallet;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== OmniBus Blockchain Node ===\n", .{});
    std.debug.print("Version: 1.0.0-dev\n", .{});
    std.debug.print("Language: Zig 0.15.2\n", .{});
    std.debug.print("Platform: Cross-Platform (Windows + Linux)\n\n", .{});

    // Initialize blockchain
    var bc = try Blockchain.init(allocator);
    defer bc.deinit();

    std.debug.print("[INIT] Blockchain initialized\n", .{});
    std.debug.print("  - Genesis block created\n", .{});
    std.debug.print("  - Difficulty: {d}\n", .{bc.difficulty});
    std.debug.print("  - Chain length: {d}\n\n", .{bc.chain.items.len});

    // Initialize wallet
    var wallet = try Wallet.init(allocator);
    defer wallet.deinit();

    std.debug.print("[WALLET] Wallet initialized\n", .{});
    std.debug.print("  - Address: {s}\n", .{wallet.address});
    std.debug.print("  - Balance: {d} SAT\n\n", .{wallet.balance});

    // Initialize RPC server
    var rpc = try RPCServer.init(allocator, &bc, &wallet);
    defer rpc.deinit();

    std.debug.print("[RPC] JSON-RPC 2.0 Server\n", .{});
    std.debug.print("  - Listening on: http://localhost:8332\n", .{});
    std.debug.print("  - WebSocket: ws://localhost:8333\n\n", .{});

    std.debug.print("[STATUS] OmniBus Blockchain running\n", .{});
    std.debug.print("  - Blocks: {d}\n", .{bc.chain.items.len});
    std.debug.print("  - Transactions: {d}\n", .{bc.mempool.items.len});
    std.debug.print("  - Wallet balance: {d} SAT\n\n", .{wallet.balance});

    // Main event loop
    std.debug.print("[LOOP] Starting mining loop...\n", .{});

    var block_counter: u32 = 0;
    while (true) {
        // Mine a new block
        _ = try bc.mineBlock();
        block_counter += 1;

        if (block_counter % 10 == 0) {
            std.debug.print("[MINING] Mined {d} blocks | Difficulty: {d}\n", .{ block_counter, bc.difficulty });
        }

        // Sleep for block time (10 seconds)
        std.time.sleep(10 * std.time.ns_per_s);
    }
}
