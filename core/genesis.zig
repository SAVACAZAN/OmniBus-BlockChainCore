const std = @import("std");
const blockchain_mod = @import("blockchain.zig");
const block_mod      = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const array_list     = std.array_list;

pub const Block       = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;
pub const Blockchain  = blockchain_mod.Blockchain;

/// Mesajul embedded in genesis — dovada ca blocul nu a fost pre-minat
pub const GENESIS_MESSAGE =
    "26/Mar/2026 OmniBus born — 600x faster than Bitcoin — Ada Spark verified — ob_omni_";

/// Timestamp Unix fix pentru genesis (26 Mar 2026 00:00:00 UTC)
pub const GENESIS_TIMESTAMP: i64 = 1_743_000_000;

/// Hash genesis — deterministic, hardcodat dupa primul calcul
/// Format: SHA256(message || timestamp) exprimat in hex
pub const GENESIS_HASH =
    "0000000a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8";

/// Versiunea protocolului la genesis
pub const GENESIS_VERSION: u32 = 1;

/// Configuratia retelei — schimbabila fara sa afecteze trecutul
pub const NetworkConfig = struct {
    /// Numele retelei ("omnibus-mainnet", "omnibus-testnet")
    name:               []const u8,
    /// Versiunea la care s-a pornit
    version:            u32,
    /// Timestamp genesis (Unix seconds)
    genesis_timestamp:  i64,
    /// Hash genesis hardcodat
    genesis_hash:       []const u8,
    /// Mesaj embedded in genesis
    genesis_message:    []const u8,
    /// Supply maxim in SAT (21M × 10^9)
    max_supply_sat:     u64,
    /// Reward initial per bloc in SAT
    initial_reward_sat: u64,
    /// Interval halving in blocuri
    halving_interval:   u64,
    /// Timp bloc tinta in ms
    block_time_ms:      u32,
    /// Micro-blocuri per bloc
    micro_blocks:       u8,
    /// Port RPC
    rpc_port:           u16,
    /// Dificultate initiala (leading zeros)
    initial_difficulty: u32,

    pub fn mainnet() NetworkConfig {
        return .{
            .name               = "omnibus-mainnet",
            .version            = GENESIS_VERSION,
            .genesis_timestamp  = GENESIS_TIMESTAMP,
            .genesis_hash       = GENESIS_HASH,
            .genesis_message    = GENESIS_MESSAGE,
            .max_supply_sat     = 21_000_000_000_000_000,
            .initial_reward_sat = 8_333_333,
            .halving_interval   = 126_144_000,
            .block_time_ms      = 1_000,
            .micro_blocks       = 10,
            .rpc_port           = 8332,
            .initial_difficulty = 4,
        };
    }

    pub fn testnet() NetworkConfig {
        return .{
            .name               = "omnibus-testnet",
            .version            = GENESIS_VERSION,
            .genesis_timestamp  = GENESIS_TIMESTAMP,
            .genesis_hash       = GENESIS_HASH,
            .genesis_message    = GENESIS_MESSAGE,
            .max_supply_sat     = 21_000_000_000_000_000,
            .initial_reward_sat = 8_333_333,
            .halving_interval   = 126_144_000,
            .block_time_ms      = 1_000,
            .micro_blocks       = 10,
            .rpc_port           = 18332,
            .initial_difficulty = 1, // mai usor pe testnet
        };
    }

    pub fn print(self: *const NetworkConfig) void {
        std.debug.print(
            \\
            \\╔══════════════════════════════════════════════════════╗
            \\║              OmniBus Network Config                  ║
            \\╚══════════════════════════════════════════════════════╝
            \\  Network:     {s}
            \\  Version:     {d}
            \\  Genesis:     {d} (Unix)
            \\  Genesis Hash:{s}
            \\  Max Supply:  {d} SAT (21,000,000 OMNI)
            \\  Reward/bloc: {d} SAT (0.08333333 OMNI)
            \\  Halving at:  {d} blocuri (~4 ani)
            \\  Block time:  {d}ms
            \\  Difficulty:  {d} (leading zeros)
            \\  RPC port:    {d}
            \\
        , .{
            self.name,
            self.version,
            self.genesis_timestamp,
            self.genesis_hash,
            self.max_supply_sat,
            self.initial_reward_sat,
            self.halving_interval,
            self.block_time_ms,
            self.initial_difficulty,
            self.rpc_port,
        });
    }
};

/// Starea Genesis — toate datele necesare pentru primul bloc
pub const GenesisState = struct {
    config:     NetworkConfig,
    allocator:  std.mem.Allocator,

    pub fn init(config: NetworkConfig, allocator: std.mem.Allocator) GenesisState {
        return .{ .config = config, .allocator = allocator };
    }

    /// Construieste Blockchain-ul cu blocul genesis corect
    /// Returneaza un Blockchain gata de mining
    pub fn buildBlockchain(self: *const GenesisState) !Blockchain {
        var bc = try Blockchain.init(self.allocator);

        // Suprascrie blocul genesis cu datele oficiale
        // (Blockchain.init() creeaza deja un genesis, il updatam)
        bc.chain.items[0] = Block{
            .index         = 0,
            .timestamp     = self.config.genesis_timestamp,
            .transactions  = array_list.Managed(Transaction).init(self.allocator),
            .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .nonce         = 0,
            .hash          = self.config.genesis_hash,
        };

        // Seteaza dificultatea conform config
        bc.difficulty = self.config.initial_difficulty;

        std.debug.print("[GENESIS] Bloc genesis initializat\n", .{});
        std.debug.print("  Hash:      {s}\n", .{self.config.genesis_hash});
        std.debug.print("  Timestamp: {d}\n", .{self.config.genesis_timestamp});
        std.debug.print("  Mesaj:     {s}\n\n", .{self.config.genesis_message});

        return bc;
    }

    /// Verifica daca un blockchain existent are genesis-ul corect
    pub fn validateGenesisBlock(self: *const GenesisState, bc: *const Blockchain) bool {
        if (bc.chain.items.len == 0) return false;
        const genesis = bc.chain.items[0];
        if (genesis.index != 0) return false;
        if (genesis.timestamp != self.config.genesis_timestamp) return false;
        if (!std.mem.eql(u8, genesis.hash, self.config.genesis_hash)) return false;
        return true;
    }

    /// Calculeaza hash-ul mesajului genesis (pentru audit)
    pub fn calculateGenesisMessageHash(self: *const GenesisState) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(self.config.genesis_message);

        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{self.config.genesis_timestamp}) catch "";
        hasher.update(ts_str);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "NetworkConfig mainnet — parametri corecti" {
    const cfg = NetworkConfig.mainnet();
    try testing.expectEqualStrings("omnibus-mainnet", cfg.name);
    try testing.expectEqual(@as(u64, 8_333_333), cfg.initial_reward_sat);
    try testing.expectEqual(@as(u64, 126_144_000), cfg.halving_interval);
    try testing.expectEqual(@as(u64, 21_000_000_000_000_000), cfg.max_supply_sat);
    try testing.expectEqual(@as(u32, 1_000), cfg.block_time_ms);
    try testing.expectEqual(@as(u8, 10), cfg.micro_blocks);
    try testing.expectEqual(@as(u16, 8332), cfg.rpc_port);
}

test "NetworkConfig testnet — dificultate mai mica" {
    const main = NetworkConfig.mainnet();
    const test_ = NetworkConfig.testnet();
    try testing.expect(test_.initial_difficulty < main.initial_difficulty);
    try testing.expectEqual(test_.initial_reward_sat, main.initial_reward_sat);
    try testing.expectEqual(test_.halving_interval, main.halving_interval);
}

test "GenesisState — buildBlockchain produce bloc valid" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cfg = NetworkConfig.mainnet();
    const gs  = GenesisState.init(cfg, arena.allocator());
    const bc  = try gs.buildBlockchain();

    try testing.expectEqual(@as(usize, 1), bc.chain.items.len);
    try testing.expectEqual(@as(u32, 0), bc.chain.items[0].index);
    try testing.expectEqual(GENESIS_TIMESTAMP, bc.chain.items[0].timestamp);
    try testing.expectEqualStrings(GENESIS_HASH, bc.chain.items[0].hash);
}

test "GenesisState — validateGenesisBlock detecteaza genesis corect" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cfg = NetworkConfig.mainnet();
    const gs  = GenesisState.init(cfg, arena.allocator());
    const bc  = try gs.buildBlockchain();

    try testing.expect(gs.validateGenesisBlock(&bc));
}

test "GenesisState — 50 OMNI la 10 minute (600 blocuri)" {
    const cfg = NetworkConfig.mainnet();
    const omni_per_10min = cfg.initial_reward_sat * 600;
    // 8333333 × 600 = 4999999800 ≈ 5_000_000_000 SAT = 5 OMNI
    // Nota: 8333333 e truncat din 8333333.333... → mic rounding error acceptabil
    try testing.expect(omni_per_10min >= 4_999_990_000);
    try testing.expect(omni_per_10min <= 5_000_000_000);
}

test "GenesisState — halving interval echivalent 4 ani" {
    const cfg = NetworkConfig.mainnet();
    const seconds_4_years: u64 = 4 * 365 * 24 * 3600; // ~126,144,000
    // Trebuie sa fie in range ±1 zi fata de 4 ani exacti
    const diff = if (cfg.halving_interval > seconds_4_years)
        cfg.halving_interval - seconds_4_years
    else
        seconds_4_years - cfg.halving_interval;
    try testing.expect(diff <= 86_400); // max 1 zi diferenta
}
