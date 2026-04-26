const std = @import("std");
const node_launcher = @import("node_launcher.zig");
const ChainId = @import("chain_config.zig").ChainId;

/// Chain mode selection for CLI — subset of ChainId that is actually
/// wired up in the launcher right now. We intentionally do NOT expose
/// `.devnet` here to avoid advertising a mode that isn't implemented.
pub const ChainMode = enum {
    mainnet,
    testnet,
    regtest,

    /// Map the CLI-facing enum into the chain_config.ChainId used internally.
    pub fn toChainId(self: ChainMode) ChainId {
        return switch (self) {
            .mainnet => ChainId.mainnet,
            .testnet => ChainId.testnet,
            .regtest => ChainId.regtest,
        };
    }
};

/// Full parsed CLI result. Wraps the legacy `NodeConfig` (unchanged, for
/// backward compat with existing callers) with the new explicit `chain_mode`.
/// Callers that want the new multi-chain selection should use `parseArgsFull`;
/// older callers that only care about node setup can keep using `parseArgs`.
pub const ParsedArgs = struct {
    node: node_launcher.NodeConfig,
    chain_mode: ChainMode,
    /// Oracle price-deviation policy overrides (null = use defaults for chain).
    /// See core/oracle_policy.zig — defaultsFor(chain_mode) is applied at
    /// startup when these are null. Non-null fields override per-knob.
    price_warn_pct: ?f64 = null,
    price_reject_pct: ?f64 = null,
    price_fillgap_pct: ?f64 = null,
    /// When true, the master switch in OraclePolicy is forced false at
    /// startup (validation completely bypassed).
    price_validation_disabled: bool = false,
};

/// CLI argument parser for node startup
pub const CLI = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CLI {
        return CLI{ .allocator = allocator };
    }

    /// Parse command-line arguments and return NodeConfig (legacy entrypoint).
    /// Preserved for backward compat — any caller using `--testnet` still works.
    /// For explicit chain selection (mainnet/testnet/regtest), use `parseArgsFull`.
    ///
    /// Usage:
    ///   omnibus-node --mode seed --primary --port 9000
    ///   omnibus-node --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000 --hashrate 1000
    pub fn parseArgs(self: CLI, args: []const []const u8) !node_launcher.NodeConfig {
        const full = try self.parseArgsFull(args);
        return full.node;
    }

    /// Parse command-line arguments and return full ParsedArgs including chain_mode.
    pub fn parseArgsFull(self: CLI, args: []const []const u8) !ParsedArgs {
        var mode: ?node_launcher.NodeMode = null;
        var node_id: []const u8 = "unknown";
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 9000;
        var is_primary: bool = false;
        var max_peers: u32 = 100;
        var seed_host: ?[]const u8 = null;
        var seed_port: ?u16 = null;
        var hashrate: ?u64 = null;
        var mnemonic: ?[]const u8 = null;
        var wallet_index: u32 = 0;
        var testnet: bool = false;
        // Explicit chain selection. Default = mainnet. We keep `testnet` bool
        // above for backward compat (legacy callers).
        var chain_mode: ChainMode = .mainnet;
        // Track whether ANY chain flag was provided, so repeated / conflicting
        // flags produce a clear error instead of silent last-wins.
        var chain_flag_seen: bool = false;
        // Oracle price-deviation policy overrides (null = chain default).
        var price_warn_pct: ?f64 = null;
        var price_reject_pct: ?f64 = null;
        var price_fillgap_pct: ?f64 = null;
        var price_validation_disabled: bool = false;

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
                } else if (std.mem.eql(u8, mode_str, "light")) {
                    mode = node_launcher.NodeMode.light;
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
            } else if (std.mem.eql(u8, arg, "--generate-wallet")) {
                // Generate wallet from OMNIBUS_MNEMONIC env var, print address, exit
                const vault_reader = @import("vault_reader.zig");
                const wallet_mod = @import("wallet.zig");
                const gen_mnemonic = try vault_reader.readMnemonic(self.allocator);
                var w = try wallet_mod.Wallet.fromMnemonic(gen_mnemonic, "", self.allocator);
                defer w.deinit();
                std.debug.print("{{\"address\":\"{s}\",\"mnemonic\":\"{s}\"}}\n", .{ w.address, gen_mnemonic });
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--mnemonic")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                mnemonic = args[i];
            } else if (std.mem.eql(u8, arg, "--wallet-index")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                wallet_index = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidWalletIndex;
            } else if (std.mem.eql(u8, arg, "--chain")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                const chain_str = args[i];
                const new_mode: ChainMode = if (std.mem.eql(u8, chain_str, "mainnet"))
                    .mainnet
                else if (std.mem.eql(u8, chain_str, "testnet"))
                    .testnet
                else if (std.mem.eql(u8, chain_str, "regtest"))
                    .regtest
                else {
                    std.debug.print("[CLI] Invalid --chain value: {s} (expected: mainnet|testnet|regtest)\n", .{chain_str});
                    return error.InvalidChain;
                };
                if (chain_flag_seen and chain_mode != new_mode) {
                    std.debug.print("[CLI] Conflicting chain flags: already set to {s}, got --chain {s}\n", .{ @tagName(chain_mode), chain_str });
                    return error.ConflictingChainFlags;
                }
                chain_mode = new_mode;
                chain_flag_seen = true;
                testnet = (new_mode == .testnet);
            } else if (std.mem.eql(u8, arg, "--mainnet")) {
                if (chain_flag_seen and chain_mode != .mainnet) {
                    std.debug.print("[CLI] Conflicting chain flags: already set to {s}, got --mainnet\n", .{@tagName(chain_mode)});
                    return error.ConflictingChainFlags;
                }
                chain_mode = .mainnet;
                chain_flag_seen = true;
                testnet = false;
            } else if (std.mem.eql(u8, arg, "--testnet")) {
                if (chain_flag_seen and chain_mode != .testnet) {
                    std.debug.print("[CLI] Conflicting chain flags: already set to {s}, got --testnet\n", .{@tagName(chain_mode)});
                    return error.ConflictingChainFlags;
                }
                chain_mode = .testnet;
                chain_flag_seen = true;
                testnet = true;
            } else if (std.mem.eql(u8, arg, "--regtest")) {
                if (chain_flag_seen and chain_mode != .regtest) {
                    std.debug.print("[CLI] Conflicting chain flags: already set to {s}, got --regtest\n", .{@tagName(chain_mode)});
                    return error.ConflictingChainFlags;
                }
                chain_mode = .regtest;
                chain_flag_seen = true;
                testnet = false;
            } else if (std.mem.eql(u8, arg, "--price-deviation-warn")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                price_warn_pct = std.fmt.parseFloat(f64, args[i]) catch return error.InvalidPriceDeviationWarn;
            } else if (std.mem.eql(u8, arg, "--price-deviation-reject")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                price_reject_pct = std.fmt.parseFloat(f64, args[i]) catch return error.InvalidPriceDeviationReject;
            } else if (std.mem.eql(u8, arg, "--price-deviation-fillgap")) {
                i += 1;
                if (i >= args.len) return error.MissingArgument;
                price_fillgap_pct = std.fmt.parseFloat(f64, args[i]) catch return error.InvalidPriceDeviationFillgap;
            } else if (std.mem.eql(u8, arg, "--no-price-validation")) {
                price_validation_disabled = true;
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

        // Final validation: chain_mode is always one of the 3 valid variants
        // (enum cannot hold anything else). If no chain flag was provided,
        // `chain_flag_seen == false` and chain_mode defaults to .mainnet.
        // This is intentional and documented behavior.
        std.debug.assert(chain_mode == .mainnet or chain_mode == .testnet or chain_mode == .regtest);

        return ParsedArgs{
            .node = node_launcher.NodeConfig{
                .mode = mode.?,
                .node_id = node_id,
                .host = host,
                .port = port,
                .is_primary = is_primary,
                .max_peers = max_peers,
                .seed_host = seed_host,
                .seed_port = seed_port,
                .hashrate = hashrate,
                .mnemonic = mnemonic,
                .wallet_index = wallet_index,
                .testnet = testnet,
                .regtest = (chain_mode == .regtest),
                .allocator = self.allocator,
            },
            .chain_mode = chain_mode,
            .price_warn_pct = price_warn_pct,
            .price_reject_pct = price_reject_pct,
            .price_fillgap_pct = price_fillgap_pct,
            .price_validation_disabled = price_validation_disabled,
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
            \\  --mnemonic PHRASE    Use custom mnemonic (12/24 words)
            \\  --wallet-index N     BIP-44 derivation index (default: 0)
            \\
            \\CHAIN SELECTION (mutually exclusive):
            \\  --chain MODE         Chain to run on: mainnet (default), testnet, regtest
            \\  --mainnet            Alias for --chain mainnet
            \\  --testnet            Alias for --chain testnet (was: legacy boolean)
            \\  --regtest            Alias for --chain regtest (instant mining, devmode)
            \\
            \\ORACLE PRICE-DEVIATION POLICY (per-node, applied to incoming P2P blocks):
            \\  --price-deviation-warn PCT     Log warning above this % deviation (default: 2.0)
            \\  --price-deviation-reject PCT   Reject block above this % deviation (default: 5.0)
            \\  --price-deviation-fillgap PCT  Allow gap-fill within this % of own median (default: 10.0)
            \\  --no-price-validation          Disable price validation entirely (regtest default)
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
            \\  # Start miner with custom wallet (index 2 from saved wallets)
            \\  omnibus-node --mode miner --node-id miner-3 \
            \\    --mnemonic "flush live wheel sun govern..." --wallet-index 2
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

test "CLI — mod lipsa returneaza MissingMode" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{"omnibus-node"};
    try testing.expectError(error.MissingMode, cli.parseArgs(&args));
}

test "CLI — mod invalid returneaza InvalidMode" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "invalid" };
    try testing.expectError(error.InvalidMode, cli.parseArgs(&args));
}

test "CLI — --help returneaza HelpRequested" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--help" };
    try testing.expectError(error.HelpRequested, cli.parseArgs(&args));
}

test "CLI — argument necunoscut returneaza UnknownArgument" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "seed", "--foobar" };
    try testing.expectError(error.UnknownArgument, cli.parseArgs(&args));
}

test "CLI — valori default: host=127.0.0.1, port=9000, max-peers=100" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "seed" };
    const config = try cli.parseArgs(&args);
    try testing.expectEqualStrings("127.0.0.1", config.host);
    try testing.expectEqual(@as(u16, 9000), config.port);
    try testing.expect(!config.is_primary);
    try testing.expectEqual(@as(u32, 100), config.max_peers);
}

test "CLI — --primary seteaza is_primary=true" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "seed", "--primary" };
    const config = try cli.parseArgs(&args);
    try testing.expect(config.is_primary);
}

test "CLI — --port custom" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "seed", "--port", "8888" };
    const config = try cli.parseArgs(&args);
    try testing.expectEqual(@as(u16, 8888), config.port);
}

test "CLI — --max-peers custom" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "seed", "--max-peers", "50" };
    const config = try cli.parseArgs(&args);
    try testing.expectEqual(@as(u32, 50), config.max_peers);
}

test "CLI — miner fara seed: seed_host/port/hashrate null" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "miner" };
    const config = try cli.parseArgs(&args);
    try testing.expect(config.seed_host == null);
    try testing.expect(config.seed_port == null);
    try testing.expect(config.hashrate == null);
}

test "CLI — --host custom" {
    var cli = CLI.init(testing.allocator);
    const args = [_][]const u8{ "omnibus-node", "--mode", "seed", "--host", "10.0.0.1" };
    const config = try cli.parseArgs(&args);
    try testing.expectEqualStrings("10.0.0.1", config.host);
}
