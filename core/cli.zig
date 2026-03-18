const std = @import("std");
const node_launcher = @import("node_launcher.zig");

/// CLI argument parser for node startup
pub const CLI = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CLI {
        return CLI{ .allocator = allocator };
    }

    /// Parse command-line arguments and return NodeConfig
    /// Usage:
    ///   omnibus-node --mode seed --primary --port 9000
    ///   omnibus-node --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000 --hashrate 1000
    pub fn parseArgs(self: CLI, args: []const []const u8) !node_launcher.NodeConfig {
        var mode: ?node_launcher.NodeMode = null;
        var node_id: []const u8 = "unknown";
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 9000;
        var is_primary: bool = false;
        var max_peers: u32 = 100;
        var seed_host: ?[]const u8 = null;
        var seed_port: ?u16 = null;
        var hashrate: ?u64 = null;

        var i: usize = 1; // Skip program name
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--mode")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                const mode_str = args[i];

                if (std.mem.eql(u8, mode_str, "seed")) {
                    mode = node_launcher.NodeMode.seed;
                } else if (std.mem.eql(u8, mode_str, "miner")) {
                    mode = node_launcher.NodeMode.miner;
                } else {
                    return error.InvalidMode;
                }
            } else if (std.mem.eql(u8, arg, "--node-id")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                node_id = args[i];
            } else if (std.mem.eql(u8, arg, "--host")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                host = args[i];
            } else if (std.mem.eql(u8, arg, "--port")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
            } else if (std.mem.eql(u8, arg, "--primary")) {
                is_primary = true;
            } else if (std.mem.eql(u8, arg, "--max-peers")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                max_peers = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidMaxPeers;
            } else if (std.mem.eql(u8, arg, "--seed-host")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                seed_host = args[i];
            } else if (std.mem.eql(u8, arg, "--seed-port")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                seed_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidSeedPort;
            } else if (std.mem.eql(u8, arg, "--hashrate")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                hashrate = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidHashrate;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return error.HelpRequested;
            } else {
                std.debug.print("[CLI] Unknown argument: {s}\n", .{arg});
                return error.UnknownArgument;
            }
        }

        if (mode == null) {
            return error.MissingMode;
        }

        return node_launcher.NodeConfig{
            .mode = mode.?,
            .node_id = node_id,
            .host = host,
            .port = port,
            .is_primary = is_primary,
            .max_peers = max_peers,
            .seed_host = seed_host,
            .seed_port = seed_port,
            .hashrate = hashrate,
            .allocator = self.allocator,
        };
    }

    /// Print usage information
    fn printUsage() void {
        std.debug.print(
            \\
            \\OMNIBUS Node Launcher
            \\
            \\USAGE:
            \\  omnibus-node --mode [seed|miner] [OPTIONS]
            \\
            \\MODES:
            \\  seed                 Run as seed/bootstrap node
            \\  miner                Run as mining participant
            \\
            \\OPTIONS (Seed Node):
            \\  --node-id ID         Unique node identifier (default: "unknown")
            \\  --host ADDRESS       Bind to address (default: 127.0.0.1)
            \\  --port PORT          Listen on port (default: 9000)
            \\  --primary            Mark as primary seed node
            \\  --max-peers COUNT    Maximum peers (default: 100)
            \\
            \\OPTIONS (Miner Node):
            \\  --node-id ID         Unique miner identifier
            \\  --host ADDRESS       Bind to address (default: 127.0.0.1)
            \\  --port PORT          Listen on port (default: 9001+)
            \\  --seed-host ADDRESS  Seed node address (required)
            \\  --seed-port PORT     Seed node port (required)
            \\  --hashrate H/s       Mining hashrate in H/s (default: 1000)
            \\
            \\EXAMPLES:
            \\  # Start primary seed node
            \\  omnibus-node --mode seed --node-id seed-1 --primary --port 9000
            \\
            \\  # Start secondary seed node
            \\  omnibus-node --mode seed --node-id seed-2 --port 9001
            \\
            \\  # Start miner connecting to seed
            \\  omnibus-node --mode miner --node-id miner-1 \
            \\    --seed-host 127.0.0.1 --seed-port 9000 --hashrate 2000
            \\
            \\  # Start multiple miners
            \\  omnibus-node --mode miner --node-id miner-2 \
            \\    --host 192.168.1.101 --port 9002 \
            \\    --seed-host 10.0.0.1 --seed-port 9000 --hashrate 1500
            \\
            \\
        , .{});
    }
};

// Tests
const testing = std.testing;

test "parse seed node arguments" {
    var cli = CLI.init(testing.allocator);

    const args = [_][]const u8{ "omnibus-node", "--mode", "seed", "--node-id", "seed-1", "--primary", "--port", "9000" };
    const config = try cli.parseArgs(&args);

    try testing.expectEqual(config.mode, node_launcher.NodeMode.seed);
    try testing.expectEqualStrings(config.node_id, "seed-1");
    try testing.expectEqual(config.port, 9000);
    try testing.expect(config.is_primary);
}

test "parse miner node arguments" {
    var cli = CLI.init(testing.allocator);

    const args = [_][]const u8{ "omnibus-node", "--mode", "miner", "--node-id", "miner-1", "--seed-host", "127.0.0.1", "--seed-port", "9000", "--hashrate", "2000" };
    const config = try cli.parseArgs(&args);

    try testing.expectEqual(config.mode, node_launcher.NodeMode.miner);
    try testing.expectEqualStrings(config.node_id, "miner-1");
    try testing.expectEqual(config.hashrate, 2000);
    try testing.expectEqualStrings(config.seed_host.?, "127.0.0.1");
    try testing.expectEqual(config.seed_port, 9000);
}
