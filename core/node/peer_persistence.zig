// core/node/peer_persistence.zig
//
// Path setup + initial load for two per-chain persistent files used by the
// P2P stack:
//
//   - peer-bans.dat     — load via peer_persist.loadFromFile.
//   - dns_registry.bin  — load via dns.loadFromFile.
//
// Periodic-save call sites stay inline in the mining loop (they need
// access to the timestamps `peer_bans_last_save` / chain head etc.). These
// helpers only handle the bufPrint + load + the corresponding log lines,
// then return the resolved path slice so the caller can reuse it for
// periodic saves without re-formatting.

const std = @import("std");
const peer_scoring_mod = @import("../peer_scoring.zig");
const peer_persist_mod = @import("../peer_persist.zig");
const dns_mod          = @import("../dns_registry.zig");

/// Ban-list persistence: per-chain file alongside the chain DB. Bans
/// outlive node restarts (and crashes) so a banned peer can't dodge by
/// waiting for the operator to bounce the process. Format documented in
/// core/peer_persist.zig (magic+version+payload+CRC32).
pub fn loadPeerBans(
    scoring: *peer_scoring_mod.PeerScoringEngine,
    chain_name: []const u8,
    path_buf: *[256]u8,
) []const u8 {
    const peer_bans_path = std.fmt.bufPrint(
        path_buf,
        "data/{s}/peer-bans.dat",
        .{chain_name},
    ) catch "data/peer-bans.dat";
    peer_persist_mod.loadFromFile(scoring, peer_bans_path) catch |err| {
        std.debug.print("[PEER-BANS] Load from {s} failed: {s} (starting empty)\n",
            .{ peer_bans_path, @errorName(err) });
    };
    if (scoring.persistentBanCount() > 0) {
        std.debug.print("[PEER-BANS] Loaded {d} persistent bans from {s}\n",
            .{ scoring.persistentBanCount(), peer_bans_path });
    }
    return peer_bans_path;
}

/// DNS registry persistence: per-chain file at data/<chain>/dns_registry.bin.
/// Only the load step is here — Phase 2 migration / pruning that follow the
/// load remain inline at the call site (they depend on the chain head).
pub fn loadDnsRegistry(
    dns: *dns_mod.DnsRegistry,
    chain_name: []const u8,
    path_buf: *[256]u8,
) []const u8 {
    const dns_persist_path = std.fmt.bufPrint(
        path_buf,
        "data/{s}/dns_registry.bin",
        .{chain_name},
    ) catch "data/dns_registry.bin";
    dns.loadFromFile(dns_persist_path) catch |err| {
        std.debug.print("[DNS] Load from {s} failed: {s} (starting empty)\n",
            .{ dns_persist_path, @errorName(err) });
    };
    if (dns.entry_count > 0) {
        std.debug.print("[DNS] Loaded {d} names from {s}\n", .{ dns.entry_count, dns_persist_path });
    }
    return dns_persist_path;
}
