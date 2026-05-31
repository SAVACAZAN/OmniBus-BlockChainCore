//! core/node/db_setup.zig
//!
//! Bundles four init blocks extracted from main.zig:
//!   1. resolveDbPath          — DB path selection per chain (OMNIBUS_DATA_DIR / legacy / dbPathForChain)
//!   2. loadPersistentDb       — PersistentBlockchain.loadFromDisk + stats print
//!   3. loadPqIdentities       — pq_identity_map JSONL sidecar load + persist path arm
//!   4. openChainstateKV       — open Bitcoin-style chainstate KV + initial RAM→KV sync
//!
//! Path strings allocated here are returned to the caller, which owns the
//! lifetime (defer allocator.free in main.zig). Helpers that only need a
//! short-lived path build/free it internally.

const std = @import("std");
const database_mod   = @import("../database.zig");
const blockchain_mod = @import("../blockchain.zig");
const chainstate_mod = @import("../store/chainstate.zig");

const PersistentBlockchain = database_mod.PersistentBlockchain;
const Blockchain           = blockchain_mod.Blockchain;
const ChainState           = chainstate_mod.ChainState;

const LEGACY_DB_PATH = "omnibus-chain.dat"; // mainnet fallback only

/// Strip "omnibus-" prefix from chain name → "mainnet"/"testnet"/"regtest".
pub fn shortChainName(chain_name: []const u8) []const u8 {
    const prefix = "omnibus-";
    if (std.mem.startsWith(u8, chain_name, prefix)) {
        return chain_name[prefix.len..];
    }
    return chain_name;
}

/// Result of resolveDbPath. Caller owns `db_path` (free with allocator).
/// `env_data_dir` is set when OMNIBUS_DATA_DIR was honored; caller must free it too.
pub const DbPathResult = struct {
    db_path: []u8,
    env_data_dir: ?[]u8,
};

/// Resolve the chain DB file path. Honors OMNIBUS_DATA_DIR first, then legacy
/// mainnet file, then database_mod.dbPathForChain. Caller owns returned strings.
pub fn resolveDbPath(
    allocator: std.mem.Allocator,
    short_name: []const u8,
) !DbPathResult {
    const env_data_dir = std.process.getEnvVarOwned(allocator, "OMNIBUS_DATA_DIR") catch null;

    if (env_data_dir) |dir| {
        std.fs.cwd().makePath(dir) catch {};
        const p = try std.fmt.allocPrint(allocator, "{s}/chain.dat", .{dir});
        std.debug.print("[DB] Using chain DB at {s} (OMNIBUS_DATA_DIR)\n", .{p});
        return .{ .db_path = p, .env_data_dir = dir };
    }

    if (std.mem.eql(u8, short_name, "mainnet")) {
        const legacy_exists = std.fs.cwd().access(LEGACY_DB_PATH, .{}) catch null;
        if (legacy_exists != null) {
            std.debug.print("[DB] Using legacy mainnet DB at {s}\n", .{LEGACY_DB_PATH});
            return .{
                .db_path = try allocator.dupe(u8, LEGACY_DB_PATH),
                .env_data_dir = null,
            };
        }
    }

    const new_path = try database_mod.dbPathForChain(allocator, short_name);
    std.debug.print("[DB] Using chain DB at {s}\n", .{new_path});
    return .{ .db_path = new_path, .env_data_dir = null };
}

/// Load the PersistentBlockchain from disk and print the loaded stats line.
pub fn loadPersistentDb(
    allocator: std.mem.Allocator,
    db_path: []const u8,
) !PersistentBlockchain {
    var pbc = try PersistentBlockchain.loadFromDisk(allocator, db_path);
    const loaded_stats = pbc.getStats();
    std.debug.print("[DB] Loaded: {d} blocks, {d} addresses from {s}\n",
        .{ loaded_stats.total_blocks, loaded_stats.total_addresses, db_path });
    return pbc;
}

/// Load pq_identity_map persistence sidecar (data/<chain>/pq_identities.jsonl).
/// Best-effort: any failure is logged and the persist path is armed for the
/// next mutation so future writes still hit disk.
pub fn loadPqIdentities(
    bc: *Blockchain,
    short_name: []const u8,
    allocator: std.mem.Allocator,
) void {
    const pq_path = std.fmt.allocPrint(allocator, "data/{s}/pq_identities.jsonl", .{short_name}) catch null;
    if (pq_path) |p| {
        defer allocator.free(p);
        blockchain_mod.loadPqIdentitiesFromDisk(bc, p) catch |err| {
            std.debug.print("[PQ-IDENT] load failed: {} (starting fresh)\n", .{err});
            blockchain_mod.pqPersistSetPath(p);
        };
    }
}

/// Open the Bitcoin-style chainstate KV at data/<chain>/chainstate and seed
/// it from the freshly-recalculated `bc.balances`. Returns the open ChainState
/// (or null on failure) so the caller can install it into the global slot.
pub fn openChainstateKV(
    bc: *Blockchain,
    short_name: []const u8,
    allocator: std.mem.Allocator,
) ?ChainState {
    const cs_base = std.fmt.allocPrint(allocator, "data/{s}/chainstate", .{short_name}) catch null;
    var cs_opt: ?ChainState = null;

    if (cs_base) |path| {
        defer allocator.free(path);
        if (ChainState.open(allocator, path)) |cs| {
            cs_opt = cs;
            std.debug.print(
                "[CHAINSTATE] opened at data/{s}/chainstate ({d} balance entries loaded)\n",
                .{ short_name, cs_opt.?.balanceCount() },
            );
        } else |err| {
            std.debug.print("[CHAINSTATE] open failed: {} — running without persistent KV\n", .{err});
        }
    }

    // Sync chainstate from the freshly-recalculated bc.balances. This handles
    // (a) first run, chainstate empty; (b) restart, chainstate may already
    // have state but bc.balances was just rebuilt from chain replay so it's
    // authoritative for now.
    if (cs_opt) |*cs| {
        var it = bc.balances.iterator();
        var synced: usize = 0;
        while (it.next()) |kv| {
            cs.putBalance(kv.key_ptr.*, kv.value_ptr.*) catch |err| {
                std.debug.print("[CHAINSTATE] initial putBalance failed: {}\n", .{err});
            };
            synced += 1;
        }
        std.debug.print("[CHAINSTATE] initial sync: {d} balances written from RAM\n", .{synced});
    }

    return cs_opt;
}
