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
