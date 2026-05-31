// core/node/wallet_setup.zig
// Extracted from main.zig (2026-05-31):
//   - loadOracleQuorum:    print wrapper around loadOracleQuorumPubkeys
//   - logKnockResult:      print the result of P2PNode.knockKnock()
//   - loadFaucetWallet:    load faucet wallet from OMNIBUS_FAUCET_PRIVKEY env
//   - setupFaucetLedger:   wire on-disk faucet claim ledger path
//   - registerSeedMiner:   register effective miner address in g_miner_pool
//
// These helpers keep main.zig free of print/branch noise. Locals that other
// code in main.zig still needs (e.g. faucet_wallet_opt) stay in main.zig —
// only the construction/printing/wiring moves here.

const std = @import("std");

const wallet_mod      = @import("../wallet.zig");
const p2p_mod         = @import("../p2p.zig");
const rpc_mod         = @import("../rpc_server.zig");
const oracle_bridge   = @import("oracle_bridge.zig");
const miner_wallet    = @import("../miner_wallet.zig");

const Wallet      = wallet_mod.Wallet;
const KnockResult = p2p_mod.KnockResult;

// ── Oracle Quorum ────────────────────────────────────────────────────────────
/// Loads pubkey set from data/<chain>/oracle_quorum.json and prints status.
/// Returns count of pubkeys loaded (0 = quorum disabled / dev-mode fallback).
pub fn loadOracleQuorum(quorum_path: []const u8) usize {
    const loaded_pubkeys = oracle_bridge.loadOracleQuorumPubkeys(quorum_path);
    if (loaded_pubkeys > 0) {
        std.debug.print("[ORACLE] Quorum: {d} pubkeys loaded, min={d}-of-{d}\n",
            .{ loaded_pubkeys, rpc_mod.ORACLE_QUORUM_MIN, loaded_pubkeys });
    } else {
        std.debug.print("[ORACLE] Quorum: 0 pubkeys loaded — oracle_recordHeader will reject all writes (or fall back to legacy dev-mode if quorum_ok=true)\n", .{});
    }
    return loaded_pubkeys;
}

// ── Knock-knock (anti-Sybil) ─────────────────────────────────────────────────
/// Prints the outcome of P2PNode.knockKnock(). `p2p.is_idle` is set internally
/// by knockKnock; this helper only handles the user-facing log.
pub fn logKnockResult(result: KnockResult) void {
    switch (result) {
        .alone => std.debug.print("[KNOCK] Miner activ — singur pe acest IP\n\n", .{}),
        .duplicate_ip => std.debug.print(
            "[KNOCK] IDLE — alt miner detectat pe acelasi IP\n" ++
            "        Acest nod monitorizeaza reteaua dar NU minaza\n\n", .{}),
        .broadcast_failed => std.debug.print(
            "[KNOCK] Broadcast indisponibil (VPN/firewall?) — continuam\n\n", .{}),
    }
}

// ── Faucet wallet loader (from raw private key env) ──────────────────────────
/// Reads OMNIBUS_FAUCET_PRIVKEY (64 hex) and constructs an isolated faucet
/// Wallet. Returns null when faucet is disabled (env missing or parse error).
/// Caller owns the returned Wallet (.deinit() in defer).
pub fn loadFaucetWallet(allocator: std.mem.Allocator, grant_sat: u64) ?Wallet {
    const fpk_hex_owned = std.process.getEnvVarOwned(allocator, "OMNIBUS_FAUCET_PRIVKEY") catch null;
    defer if (fpk_hex_owned) |s| allocator.free(s);
    if (fpk_hex_owned) |fpk_hex| {
        const trimmed = std.mem.trim(u8, fpk_hex, " \t\n\r");
        if (Wallet.parsePrivateKeyHex(trimmed)) |fpk| {
            if (Wallet.fromPrivateKey(fpk, allocator)) |fw| {
                std.debug.print("[FAUCET] Faucet wallet loaded from OMNIBUS_FAUCET_PRIVKEY (no mnemonic exposure)\n", .{});
                std.debug.print("[FAUCET] Faucet address: {s}\n", .{fw.address});
                std.debug.print("[FAUCET] Per-claim grant: {d} SAT ({d:.4} OMNI)\n\n",
                    .{ grant_sat, @as(f64, @floatFromInt(grant_sat)) / 1e9 });
                return fw;
            } else |err| {
                std.debug.print("[FAUCET] fromPrivateKey failed: {} — faucet disabled\n", .{err});
            }
        } else |err| {
            std.debug.print("[FAUCET] OMNIBUS_FAUCET_PRIVKEY parse failed: {} (expected 64 hex chars) — faucet disabled\n", .{err});
        }
    } else {
        std.debug.print("[FAUCET] --faucet-mode set but OMNIBUS_FAUCET_PRIVKEY env var missing — faucet disabled\n", .{});
    }
    return null;
}

/// Wires the on-disk faucet claim ledger path for the current chain mode.
/// Without this, the in-memory counter resets on every restart and lets
/// attackers re-claim. Safe to call only when faucet wallet is loaded.
pub fn setupFaucetLedger(allocator: std.mem.Allocator, testnet: bool, regtest: bool) void {
    const chain_subdir: []const u8 = if (testnet) "testnet" else if (regtest) "regtest" else "mainnet";
    const ledger_path = std.fmt.allocPrint(allocator, "data/{s}/faucet-claims.json", .{chain_subdir}) catch return;
    defer allocator.free(ledger_path);
    std.fs.cwd().makePath(std.fs.path.dirname(ledger_path) orelse ".") catch {};
    rpc_mod.faucetSetPersistPath(ledger_path);
    std.debug.print("[FAUCET] claim ledger: {s}\n", .{ledger_path});
}

// ── Miner pool registration ──────────────────────────────────────────────────
/// Register the effective miner address into the shared MinerWalletPool. When
/// the address matches the local wallet (mnemonic-on-miner), register with the
/// real mnemonic so the pool's pubkey matches the actual private key. For
/// external --miner-address (mnemonic offline), register address-only.
///
/// BUG FIX (2026-04-27, preserved): the legacy `register(addr)` path created
/// a RANDOM secp256k1 keypair under the address; F8 then published that bogus
/// pubkey and signature verification failed on every TX. See main.zig comment
/// block (now removed) for full history.
pub fn registerSeedMiner(
    pool: *miner_wallet.MinerWalletPool,
    effective_miner_addr: []const u8,
    local_wallet_addr: []const u8,
    mnemonic: []const u8,
    allocator: std.mem.Allocator,
) void {
    if (std.mem.eql(u8, effective_miner_addr, local_wallet_addr)) {
        _ = pool.registerWithMnemonic(effective_miner_addr, mnemonic, allocator) catch
            pool.register(effective_miner_addr);
    } else {
        pool.register(effective_miner_addr);
    }
}
