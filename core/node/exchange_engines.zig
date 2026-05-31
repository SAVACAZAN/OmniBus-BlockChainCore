// core/node/exchange_engines.zig
//
// Helpers extracted from main.zig to keep node startup readable. Behavior
// is preserved verbatim from the pre-extract main.zig (same log lines,
// same heap allocation pattern, same null-on-failure semantics).
//
//   - initFillsLog:     persistent trade-fills journal under data/<chain>/.
//   - initBridgeState:  heap-allocate the cross-chain BridgeState.
//   - initGridRegistry: heap-allocate + load grid registry from disk.
//   - deriveKycIssuer:  derive the slot-4 (`kyc.omnibus`) address from the
//                       same mnemonic the local wallet uses.

const std = @import("std");
const fills_log_mod    = @import("../fills_log.zig");
const bridge_mod       = @import("../bridge_native.zig");
const grid_mod         = @import("../grid_engine.zig");
const bip32_wallet_mod = @import("../bip32_wallet.zig");

/// Returns the chain subdir name for a (testnet, regtest) flag pair.
/// Mirrors the inline ternary used at the call sites pre-extract.
pub fn chainSubdir(testnet: bool, regtest: bool) []const u8 {
    if (testnet) return "testnet";
    if (regtest) return "regtest";
    return "mainnet";
}

/// Trade fills log — append-only binary journal of every executed fill.
/// Lives alongside other per-chain data so a node restart preserves the
/// user's trade history. Heap-allocated so the RPC thread can keep a
/// stable pointer for the process lifetime.
pub fn initFillsLog(allocator: std.mem.Allocator, chain_subdir: []const u8) ?*fills_log_mod.FillsLog {
    const dir = std.fmt.allocPrint(allocator, "data/{s}", .{chain_subdir}) catch return null;
    defer allocator.free(dir);
    const log_ptr = allocator.create(fills_log_mod.FillsLog) catch return null;
    const inited = fills_log_mod.FillsLog.init(allocator, dir) catch {
        allocator.destroy(log_ptr);
        return null;
    };
    log_ptr.* = inited;
    std.debug.print("[FILLS-LOG] persistent log at {s}/fills_log.bin\n", .{dir});
    return log_ptr;
}

/// KYC issuer address: the wallet at registrar slot 4 (`kyc.omnibus`).
/// We re-derive from the same mnemonic the local wallet was built from.
/// On testnet that's enough; mainnet would also cross-check against the
/// hardcoded constant in `registrar_addresses.zig:REGISTRAR_ADDRESSES`.
pub fn deriveKycIssuer(mnemonic: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    var bip32 = bip32_wallet_mod.BIP32Wallet.initFromMnemonic(mnemonic, allocator) catch return null;
    const addr = bip32.deriveAddressForDomain(777, 4, "ob", allocator) catch return null;
    std.debug.print("[KYC] issuer (slot 4 / kyc.omnibus): {s}\n", .{addr});
    return addr;
}

/// Bridge state — heap-allocated so the pointer stays valid across the
/// RPC thread lifetime. BridgeState.init() needs an allocator.
pub fn initBridgeState(allocator: std.mem.Allocator) ?*bridge_mod.BridgeState {
    const bridge_state_ptr = allocator.create(bridge_mod.BridgeState) catch return null;
    bridge_state_ptr.* = bridge_mod.BridgeState.init(allocator);
    std.debug.print("[BRIDGE] Native cross-chain bridge initialized\n", .{});
    return bridge_state_ptr;
}

/// Grid trading registry — heap-allocated, persisted in
/// data/<chain>/grid_registry.bin. Returns both the registry pointer and
/// the owned path string (caller is responsible for the lifetime of both;
/// pre-extract behavior left them alive for the process lifetime).
pub const GridInit = struct {
    registry: ?*grid_mod.GridRegistry,
    path: ?[]u8,
};

pub fn initGridRegistry(allocator: std.mem.Allocator, chain_subdir: []const u8) GridInit {
    const grid_registry_ptr = allocator.create(grid_mod.GridRegistry) catch return .{ .registry = null, .path = null };
    const grid_path_owned = std.fmt.allocPrint(allocator, "data/{s}/grid_registry.bin", .{chain_subdir}) catch null;
    grid_registry_ptr.* = grid_mod.GridRegistry.init();
    if (grid_path_owned) |p| {
        std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
        grid_registry_ptr.loadFromFile(p) catch {};
        std.debug.print("[GRID] Grid engine ON — registry: {s} ({d} grids loaded)\n", .{ p, grid_registry_ptr.count });
    }
    return .{ .registry = grid_registry_ptr, .path = grid_path_owned };
}
