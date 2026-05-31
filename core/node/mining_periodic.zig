// core/node/mining_periodic.zig
//
// Self-contained periodic blocks extracted from the mining loop in main.zig.
// Each function corresponds to one "// ── …" section that used to live inside
// `while (launcher.is_running …)`. Behavior is unchanged: same prints, same
// thresholds, same ordering when called sequentially from main.zig.

const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const state_trie_mod = @import("../state_trie.zig");
const finality_mod   = @import("../finality.zig");
const staking_mod    = @import("../staking.zig");
const miner_wallet_mod = @import("../miner_wallet.zig");
const metachain_mod  = @import("../metachain.zig");
const pouw_mod       = @import("../consensus_pouw.zig");
const price_oracle_mod = @import("../price_oracle.zig");
const agents_mod     = @import("agents.zig");

/// Canonical pair labels — mirrors exchange_listPairs RPC order. Kept here so
/// the WS broadcast helper does not depend on caller for the list.
pub const PAIR_LABELS = [7][]const u8{
    "OMNI/USDC", "BTC/USDC", "LCX/USDC",
    "ETH/USDC",  "OMNI/BTC", "OMNI/LCX", "OMNI/ETH",
};

/// WS: broadcast fills (trades) for the just-mined block + orderbook
/// snapshots for every active pair. Behavior preserved verbatim from
/// the original inline block in main.zig.
pub fn broadcastFillsAndOrderbook(
    bc: *blockchain_mod.Blockchain,
    ws_srv: anytype,
    new_block: anytype,
    block_count: u64,
) void {
    if (bc.fills_history.get(@intCast(new_block.index))) |fills| {
        for (fills) |fill| {
            const label = if (fill.pair_id < PAIR_LABELS.len)
                PAIR_LABELS[fill.pair_id] else "OMNI/USDC";
            ws_srv.broadcastTrade(
                fill.pair_id, label,
                fill.price_micro_usd, fill.amount_sat,
                "buy", block_count,
            );
        }
    }

    if (bc.exchange_engine) |eng| {
        for (PAIR_LABELS, 0..) |label, pid| {
            const pair_id: u16 = @intCast(pid);
            const bb = eng.bestBid(pair_id) orelse 0;
            const ba = eng.bestAsk(pair_id) orelse 0;
            const oc = eng.orderCountForPair(pair_id);
            if (bb > 0 or ba > 0 or oc > 0) {
                const sp = if (ba > bb) ba - bb else 0;
                ws_srv.broadcastOrderbook(pair_id, label, bb, ba, sp, oc, block_count);
            }
        }
    }
}

/// Per-block round engines tick:
///   - PoUW: calculate + reset
///   - AI Agents: tick all loaded agents
///   - Price Oracle: reset round
///   - Oracle Fetcher: every 10 blocks log latest snapshot + broadcast medians
///
/// `oracle_fetcher_opt` is the same `*?OracleFetcher` global from main.zig.
/// `ws_srv` is used only to broadcast medians (anytype to avoid import cycle).
pub fn tickRoundEngines(
    pouw: *pouw_mod.PoUWEngine,
    bc: *blockchain_mod.Blockchain,
    price_oracle: *price_oracle_mod.DistributedPriceOracle,
    oracle_fetcher_opt: anytype,
    ws_srv: anytype,
    block_count: u64,
) void {
    // PoUW
    pouw.calculateRewards(block_count);
    pouw.resetBlock();

    // AI Agents
    agents_mod.agentTickAll(bc, block_count);

    // Price oracle round reset
    price_oracle.resetRound();

    // Oracle fetcher periodic log
    if (block_count % 10 == 0) {
        if (oracle_fetcher_opt.*) |*fetcher| {
            const snap = fetcher.snapshot();
            var btc_ok: u8 = 0;
            var lcx_ok: u8 = 0;
            for (snap[0..3]) |p| { if (p.success) btc_ok += 1; }
            for (snap[3..6]) |p| { if (p.success) lcx_ok += 1; }
            if (fetcher.getMedianPrice()) |median| {
                std.debug.print("[ORACLE-FETCHER] BTC/USD median: ${d}.{d:0>2} ({d}/3 exchanges)\n",
                    .{ median / 1_000_000, (median % 1_000_000) / 10_000, btc_ok });
                ws_srv.broadcastOraclePrice("BTC/USD", median, btc_ok);
            } else {
                std.debug.print("[ORACLE-FETCHER] BTC: no prices available\n", .{});
            }
            if (fetcher.getMedianLcxPrice()) |median| {
                std.debug.print("[ORACLE-FETCHER] LCX/USD median: ${d}.{d:0>4} ({d}/3 exchanges)\n",
                    .{ median / 1_000_000, (median % 1_000_000) / 100, lcx_ok });
                ws_srv.broadcastOraclePrice("LCX/USD", median, lcx_ok);
            } else {
                std.debug.print("[ORACLE-FETCHER] LCX: no prices available\n", .{});
            }
        }
    }
}

/// Metachain: register a shard header for the just-mined block and
/// finalize the meta block. Returns the `block_hash_fixed` as the
/// caller still needs it for downstream helpers (finality).
pub fn registerMetaShard(
    metachain: *metachain_mod.Metachain,
    wallet_addr: []const u8,
    block_count: u64,
    new_block_hash: []const u8,
    tx_count: u32,
    reward_sat: u64,
) ![32]u8 {
    const shard_id = metachain.coordinator.getShardForAddress(wallet_addr);
    const meta_block = try metachain.beginMetaBlock();
    var block_hash_fixed: [32]u8 = std.mem.zeroes([32]u8);
    const hash_copy_len = @min(new_block_hash.len, 32);
    @memcpy(block_hash_fixed[0..hash_copy_len], new_block_hash[0..hash_copy_len]);
    try meta_block.addShardHeader(.{
        .shard_id     = shard_id,
        .block_height = block_count,
        .block_hash   = block_hash_fixed,
        .tx_count     = tx_count,
        .timestamp    = std.time.timestamp(),
        .miner        = wallet_addr,
        .reward_sat   = reward_sat,
    });
    try metachain.finalizeMetaBlock();

    if (block_count % 10 == 0) {
        std.debug.print("[METACHAIN] height={d} shard={d} active_shards={d}\n", .{
            metachain.getHeight(),
            shard_id,
            metachain.coordinator.num_shards,
        });
    }
    return block_hash_fixed;
}

/// Every-N-blocks periodic log lines for governance / DNS / guardian.
/// Called from the maintenance branch — `block_count` is used only for
/// time-based active checks inside DNS/Guardian.
pub fn maybeLogPeriodic(
    block_count: u64,
    governance: anytype,
    dns: anytype,
    guardian: anytype,
) void {
    if (governance.proposal_count > 0) {
        std.debug.print("[GOVERNANCE] Active proposals: {d}\n", .{governance.proposal_count});
    }
    const dns_active = dns.activeCount(block_count);
    if (dns_active > 0) {
        std.debug.print("[DNS] Registered names: {d}\n", .{dns_active});
    }
    const guarded = guardian.guardedCount(block_count);
    if (guarded > 0) {
        std.debug.print("[GUARDIAN] Guarded accounts: {d}\n", .{guarded});
    }
}

/// P2P maintenance: reconnect dead peers, evict expired bans, attempt
/// fork-recovery. Same three calls the mining-loop maintenance branch
/// used to do inline.
pub fn p2pMaintenance(p2p: anytype) void {
    p2p.processReconnects();
    p2p.evictExpiredBans();
    _ = p2p.tryForkRecovery();
}

/// State Trie: update account state for the current wallet at block_count.
/// Mirrors the original 5-line block verbatim.
pub fn updateStateTrie(
    state_trie: *state_trie_mod.StateTrie,
    address: []const u8,
    balance: u64,
    block_count: u64,
) !void {
    var addr_buf: [20]u8 = std.mem.zeroes([20]u8);
    const alen = @min(address.len, 20);
    @memcpy(addr_buf[0..alen], address[0..alen]);
    try state_trie.updateBalance(addr_buf, balance, @intCast(block_count));
    state_trie.block_height = @intCast(block_count);
}

/// Finality: propose checkpoint every CHECKPOINT_INTERVAL blocks and self-attest.
pub fn maybeProposeCheckpoint(
    finality: *finality_mod.FinalityEngine,
    block_count: u64,
    block_hash_fixed: [32]u8,
    wallet_priv: [32]u8,
) void {
    if (block_count % finality_mod.CHECKPOINT_INTERVAL == 0 and block_count > 0) {
        _ = finality.proposeCheckpoint(block_count, block_hash_fixed) catch {};
        // Self-attest (solo miner attests own checkpoint). The
        // attestation is signed with the miner's secp256k1 key and
        // verified against the validator registered above; the engine
        // ignores the advisory voting_power and uses the registry's.
        var self_att = finality_mod.Attestation{
            .validator_id = 0,
            .target_epoch = block_count / finality_mod.CHECKPOINT_INTERVAL,
            .source_epoch = finality.last_justified_epoch,
            .voting_power = 1000,
            .block_hash = block_hash_fixed,
            .timestamp = std.time.timestamp(),
        };
        self_att.sign(wallet_priv) catch {};
        finality.attest(self_att) catch {};
        std.debug.print("[FINALITY] Checkpoint epoch {d} | justified={d} finalized={d}\n",
            .{ block_count / finality_mod.CHECKPOINT_INTERVAL,
               finality.last_justified_epoch, finality.last_finalized_epoch });
    }
}

/// Staking: distribute rewards every REWARD_EPOCH_BLOCKS blocks.
pub fn maybeDistributeStakingRewards(
    staking: *staking_mod.StakingEngine,
    block_count: u64,
    reward_sat: u64,
) void {
    if (block_count % staking_mod.REWARD_EPOCH_BLOCKS == 0 and staking.activeCount() > 0) {
        staking.distributeRewards(reward_sat);
        std.debug.print("[STAKING] Epoch {d} | validators={d} | total_staked={d}\n",
            .{ staking.current_epoch, staking.activeCount(), staking.total_staked });
    }
}

/// F8: refresh balance cache for every miner-pool entry from chain state.
///
/// BUG FIX (2026-04-27): we previously also republished each pool entry's
/// `public_key_hex` into `bc.pubkey_registry`. When the entry was created via
/// `registerWithRandomKey` (the legacy `register(addr)` path), that pubkey was
/// a random key unrelated to the real address — registering it would poison
/// the registry and cause ECDSA verification to fail for any transaction
/// actually signed with the wallet's mnemonic. The `sendtransaction` RPC
/// handler is now the only authoritative writer; it registers the *real*
/// pubkey from `ctx.wallet.addresses[0].public_key_hex` before validation.
/// Pool entries with random keys are still useful for `getMinerForBlock`
/// rotation, just not for signing.
pub fn updateMinerPoolBalances(
    bc: *blockchain_mod.Blockchain,
    pool: *miner_wallet_mod.MinerWalletPool,
) void {
    pool.mutex.lock();
    const pool_count = pool.count;
    var addrs_buf: [miner_wallet_mod.MinerWalletPool.MAX][64]u8 = undefined;
    var lens_buf: [miner_wallet_mod.MinerWalletPool.MAX]u8 = undefined;
    for (0..pool_count) |pi| {
        addrs_buf[pi] = pool.wallets[pi].address;
        lens_buf[pi] = pool.wallets[pi].address_len;
    }
    pool.mutex.unlock();

    for (0..pool_count) |pi| {
        const maddr = addrs_buf[pi][0..lens_buf[pi]];
        const mbal = bc.getAddressBalance(maddr);
        pool.updateBalance(maddr, mbal);
    }
}
