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
const registrar_mod    = @import("../registrar_addresses.zig");
const cli_mod          = @import("../cli.zig");

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

/// Post-load DNS finalize: Phase 2 migration + prune expired + treasury
/// wiring + fee/sign enforcement config. Fatal on missing registrar slot
/// or signed_required=false on mainnet. Matches the exact print lines
/// previously inlined in main.zig.
pub fn finalizeDns(
    dns: *dns_mod.DnsRegistry,
    bc_height: u64,
    chain_mode: cli_mod.ChainMode,
) !void {
    if (dns.entry_count > 0) {
        // Phase 2 auto-migration — backfill category from TLD + years from default
        // for legacy entries (no behavior change for entries already migrated).
        const migrated = dns.migrateLegacyEntries();
        if (migrated > 0) {
            std.debug.print("[DNS] Auto-migrated {d} legacy entries to Phase 2 (category from TLD)\n", .{migrated});
        }
        // Phase 2 lifecycle — drop entries whose grace period has fully
        // elapsed. One-shot at startup; steady-state cleanup is hooked into
        // the mining loop below (every 1000 blocks).
        const pruned = dns.pruneExpiredNames(bc_height);
        if (pruned > 0) {
            std.debug.print("[DNS] Pruned {d} expired (past-grace) names at startup\n", .{pruned});
        }
    }

    // Set treasury = ens.omnibus address from the canonical registrar table.
    //
    // The 10 registrar slots act as native "smart contracts" — they have
    // an on-chain address but NO private key. The chain itself enforces
    // their rules deterministically (pay-to-claim for ens, drip for faucet,
    // grid orders for exchange treasury, etc.). We never derive these from
    // a node-local mnemonic — every node reads the same hardcoded strings
    // and produces the same consensus. Same model Hyperliquid uses for its
    // protocol-owned addresses.
    const ens_treasury_addr = registrar_mod.addressOf(.ens) orelse {
        std.debug.print("[DNS] FATAL: ens slot empty in registrar_addresses.zig\n", .{});
        return error.MissingRegistrarSlot;
    };
    dns.setTreasury(ens_treasury_addr);
    // Pe testnet & regtest: fee_enforcement OFF (compat cu Kimi scripts).
    // Pe mainnet: fee_enforcement ON.
    dns.enableFee(chain_mode == .mainnet);
    std.debug.print("[DNS] Treasury: {s} | fee_enforcement: {}\n",
        .{ ens_treasury_addr, dns.fee_enforcement });
    // Phase 1 hardening: signed_required defaults true in DnsRegistry.init().
    // Log it explicitly so operators can verify auth is on at every launch.
    std.debug.print("[DNS] signed_required = {}\n", .{dns.signed_required});
    if (chain_mode == .mainnet and !dns.signed_required) {
        std.debug.print("[DNS] FATAL: signed_required must be true on mainnet\n", .{});
        return error.DnsSignedRequiredDisabled;
    }
}
