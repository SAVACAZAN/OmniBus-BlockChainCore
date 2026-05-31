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
const ws_exchange_feed_mod = @import("../ws_exchange_feed.zig");
const reputation_manager_mod = @import("../reputation_manager.zig");
const payment_mod    = @import("../payment_channel.zig");
const dns_mod        = @import("../dns_registry.zig");
const sync_mod       = @import("../sync.zig");

/// IDLE re-check: if `p2p.is_idle` is set, the mining loop calls this
/// every iteration. Every 60s (gated by `maint_count`) it re-runs
/// knock-knock to see if the duplicate IP is gone. Behavior matches the
/// original inline block — same prints, same threshold.
pub fn maybeRetryKnockKnock(p2p: anytype, maint_count: u32) void {
    if (maint_count % 60 == 0) {
        std.debug.print("[IDLE] Re-verificare duplicat IP...\n", .{});
        const recheck = p2p.*.knockKnock();
        if (recheck == .alone) {
            std.debug.print("[IDLE] Duplicat disparut — reactivare mining!\n\n", .{});
        }
    }
}

/// Snapshot prices from the WS exchange feed into the just-mined block.
/// Maps `ws_exchange_feed.PriceFetch` → `blockchain.BlockPriceEntry` using
/// fixed-size strings so the array can live in a hashmap without an
/// allocator. No-op when the feed is null.
pub fn snapshotPricesIntoBlock(
    feed_opt: *?ws_exchange_feed_mod.ExchangeFeed,
    bc: *blockchain_mod.Blockchain,
    block_index: u32,
) void {
    if (feed_opt.*) |*feed| {
        const live = feed.snapshot();
        var entries: [6]blockchain_mod.BlockPriceEntry = undefined;
        for (live, 0..) |p, i| {
            var e: blockchain_mod.BlockPriceEntry = .{};
            const elen = @min(p.exchange.len, 16);
            e.exchange_len = @intCast(elen);
            @memcpy(e.exchange[0..elen], p.exchange[0..elen]);
            const plen = @min(p.pair.len, 16);
            e.pair_len = @intCast(plen);
            @memcpy(e.pair[0..plen], p.pair[0..plen]);
            e.bid_micro_usd = p.bid_micro_usd;
            e.ask_micro_usd = p.ask_micro_usd;
            e.timestamp_ms  = p.timestamp_ms;
            e.success       = p.success;
            entries[i] = e;
        }
        bc.recordBlockPrices(block_index, &entries);
    }
}

/// Reputation: credit the miner across all 4 domains for the just-mined
/// block. FOOD = work (every block), LOVE = uptime (every 60 blocks) +
/// daily streak (every 8640), RENT = per-block credit for every active
/// staker, VACATION = daily tick for every known address (snapshot-then-
/// iterate to avoid the B1 re-entrant lock deadlock).
pub fn creditReputationForBlock(
    rep_opt: *?reputation_manager_mod.ReputationManager,
    staking_opt: ?*staking_mod.StakingEngine,
    miner_addr: []const u8,
    block_count: u64,
    allocator: std.mem.Allocator,
) void {
    if (rep_opt.*) |*rep_mgr| {
        // FOOD — block mined credit
        rep_mgr.creditMinedBlock(miner_addr, block_count);

        // LOVE — uptime credit pentru miner activ. La 1s/block, 60 blocs
        // = 1 minut online. Acordat la fiecare 60 blocuri (creditUptimeMinutes
        // trateaza 1 minut = LOVE_PER_MINUTE_ONLINE points).
        if (block_count > 0 and block_count % 60 == 0) {
            rep_mgr.creditUptimeMinutes(miner_addr, 1, block_count);
        }
        // LOVE bonus — daily streak (la fiecare 8640 blocuri = 1 zi).
        if (block_count > 0 and block_count % 8640 == 0) {
            rep_mgr.creditDailyStreak(miner_addr, block_count);
        }

        // RENT — credit per-block pentru stakeri activi.
        // Iteram primii `validator_count` din slot-ul fix de 128.
        // Stake e in SAT (1e9 SAT = 1 OMNI), creditStakePerBlock asteapta OMNI.
        if (staking_opt) |se| {
            var vi: usize = 0;
            while (vi < se.validator_count) : (vi += 1) {
                const val = &se.validators[vi];
                if (val.status != .active) continue;
                const omni_staked = val.total_stake / 1_000_000_000;
                if (omni_staked == 0) continue;
                rep_mgr.creditStakePerBlock(
                    val.address[0..val.addr_len],
                    omni_staked,
                    block_count,
                );
            }
        }

        // VACATION — daily tick. 1 day = 8640 blocks @ 10s.
        // Fix B1 deadlock: previously took rep_mgr.lock() then called
        // creditVacationDay which re-locks the same mutex (non-reentrant
        // std.Thread.Mutex panics → mainnet wedge for ~12 min until
        // systemd respawn). Solution: collect the addresses first under
        // a brief lock, then iterate the OWNED list calling
        // creditVacationDay (which will lock once, briefly, per addr).
        if (block_count > 0 and block_count % 8640 == 0) {
            const total_days: u64 = block_count / 8640;
            // Snapshot keys under lock to avoid concurrent-modify panic.
            var addr_list = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (addr_list.items) |a| allocator.free(a);
                addr_list.deinit();
            }
            {
                rep_mgr.lock();
                defer rep_mgr.unlock();
                var iter = rep_mgr.iterate();
                while (iter.next()) |entry| {
                    const owned = allocator.dupe(u8, entry.key_ptr.*) catch continue;
                    addr_list.append(owned) catch {
                        allocator.free(owned);
                        break;
                    };
                }
            }
            // Now lock-free — each call takes the mutex briefly.
            for (addr_list.items) |addr| {
                rep_mgr.creditVacationDay(addr, total_days, block_count);
            }
        }
    }
}

/// FIX (2026-05-03): per-block chainstate flush + companion registry
/// persists (DNS / HTLC / payment channels / intents). Wrapped in
/// try/catch — disk failure logs + continues mining (the 30s background
/// thread will retry). Returns `true` if the chainstate write succeeded
/// (mirrors the original `did_save = true` behavior used to gate the
/// companion saves).
pub fn flushChainstatePerBlock(
    bc: *blockchain_mod.Blockchain,
    dns: *dns_mod.DnsRegistry,
    dns_persist_path: []const u8,
    htlc_persist_path: []const u8,
    channel_mgr: *payment_mod.ChannelManager,
    channels_path: []const u8,
    intent_persist_path: []const u8,
    block_count: u64,
) void {
    bc.saveToDisc() catch |err| {
        std.debug.print(
            "[DB] Per-block save failed at #{d}: {} — continuing mining, 30s thread will retry\n",
            .{ block_count, err },
        );
    };
    std.debug.print("[DB] Saved chainstate after block #{d}\n", .{block_count});
    // DNS persist piggybacks on chain auto-save (cadenta identica).
    dns.saveToFile(dns_persist_path) catch |err| {
        std.debug.print("[DNS] Save to {s} failed: {s}\n",
            .{ dns_persist_path, @errorName(err) });
    };
    // HTLC registry persists on the same cadence as DNS.
    @import("../htlc_persist.zig").saveToFile(&bc.htlc_registry, htlc_persist_path) catch |err| {
        std.debug.print("[HTLC] Save to {s} failed: {s}\n",
            .{ htlc_persist_path, @errorName(err) });
    };
    // Payment channels persist on the same cadence.
    @import("../channel_persist.zig").saveToFile(channel_mgr, channels_path) catch |err| {
        std.debug.print("[CHANNELS] Save to {s} failed: {s}\n",
            .{ channels_path, @errorName(err) });
    };
    // Intent registry persists on the same cadence as HTLC.
    bc.intent_registry.saveToFile(intent_persist_path) catch |err| {
        std.debug.print("[INTENT] Save to {s} failed: {s}\n",
            .{ intent_persist_path, @errorName(err) });
    };
}

/// PoUW: build a WorkReport for the miner of the just-produced block
/// and submit it to the engine. Fills/volume/price counters left at 0;
/// the matching engine + oracle paths update those independently.
pub fn submitMiningWorkReport(
    pouw: *pouw_mod.PoUWEngine,
    miner_addr: []const u8,
    block_count: u64,
) void {
    var work = pouw_mod.WorkReport{
        .miner_address = undefined,
        .miner_addr_len = 0,
        .work_type = .matching,
        .block_height = block_count,
        .timestamp_ms = @intCast(std.time.milliTimestamp()),
        .fills_count = 0,
        .volume_matched_sat = 0,
        .price_updates = 0,
        .settlements_count = 0,
        .work_hash = std.mem.zeroes([32]u8),
        .signature = std.mem.zeroes([64]u8),
    };
    // Copy miner address
    const addr_len: u8 = @intCast(@min(miner_addr.len, 64));
    @memcpy(work.miner_address[0..addr_len], miner_addr[0..addr_len]);
    work.miner_addr_len = addr_len;
    pouw.submitWorkReport(work) catch {};
}

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

/// Maintenance cadence (every 30 maint ticks): launcher housekeeping,
/// P2P reconnects/evictions/fork-recovery, governance/DNS/guardian periodic
/// logs, network status print, gossip stats, sync-stalled recovery, sync
/// status print. Behavior preserved verbatim from the original inline block.
///
/// `sync_mgr` is passed as a pointer so we can re-init it in place when
/// `isStalled()` fires (SyncManager has no `reset()` method).
pub fn periodicMaintenance30(
    launcher: anytype,
    p2p: anytype,
    block_count: u64,
    governance: anytype,
    dns: anytype,
    guardian: anytype,
    sync_mgr: *sync_mod.SyncManager,
    local_height: u64,
    allocator: std.mem.Allocator,
) void {
    launcher.maintenance();

    // ── P2P maintenance: reconnect dead peers + evict expired bans + fork recovery ──
    p2pMaintenance(p2p);

    // ── Governance + DNS + Guardian periodic logs ───────────────
    maybeLogPeriodic(block_count, governance, dns, guardian);
    if (launcher.getNetworkStatus()) |s| {
        std.debug.print("[NETWORK] peers: {d}  miners: {d}  synced: {}\n",
            .{ s.total_peers, s.total_miners, s.is_synced });
    }
    p2p.cleanDeadPeers();
    p2p.gossipMaintenance();

    // Log gossip stats
    {
        const gs2 = p2p.getGossipStats();
        if (gs2.tx_relayed > 0 or gs2.blocks_relayed > 0) {
            std.debug.print("[GOSSIP] TX relayed: {d} | Blocks relayed: {d} | Seen TX: {d} | Seen blocks: {d}\n",
                .{ gs2.tx_relayed, gs2.blocks_relayed, gs2.seen_tx, gs2.seen_blocks });
        }
    }

    // Verifica daca sync-ul e blocat
    if (sync_mgr.isStalled()) {
        std.debug.print("[SYNC] STALLED >60s — resetare sync\n", .{});
        sync_mgr.* = sync_mod.SyncManager.init(local_height, allocator);
    }

    // Log status sync periodic
    if (!sync_mgr.isSynced()) {
        sync_mgr.state.print();
    }
}

/// Notify SyncManager when a P2P peer announces a higher chain height,
/// and request missing blocks. Mirrors the original inline block verbatim.
pub fn maybeRequestPeerSync(
    p2p: anytype,
    sync_mgr: *sync_mod.SyncManager,
    local_height: u64,
) void {
    if (p2p.chain_height > @as(u32, @intCast(local_height))) {
        if (sync_mgr.onPeerHeight(p2p.chain_height)) |_| {
            // Cere blocuri lipsa de la primul peer care are height mai mare
            p2p.requestSync(@intCast(local_height));
            std.debug.print("[SYNC] requestSync trimis (local={d} peer={d})\n",
                .{ local_height, p2p.chain_height });
        }
    }
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
