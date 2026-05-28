// core/node/faucet_thread.zig
// Faucet auto-refill loop + organic auto-TX between miners.
// Extracted from main.zig (2026-05-29). Re-exported by main.zig so existing
// call sites (`std.Thread.spawn(.{}, faucetRefillLoop, .{ra})` and
// `autoTxBetweenMiners(&bc, block_count, allocator)`) keep working.

const std = @import("std");

const blockchain_mod = @import("../blockchain.zig");
const wallet_mod     = @import("../wallet.zig");
const mempool_mod    = @import("../mempool.zig");

const Blockchain = blockchain_mod.Blockchain;
const Wallet     = wallet_mod.Wallet;

// Access the global miner pool declared in main.zig (root).
const root = @import("root");

/// F8: Auto-TX — pick two funded miners and send a small TX between them.
/// Called from the mining loop every N blocks to create organic traffic.
pub fn autoTxBetweenMiners(bc: *Blockchain, block_count: u32, allocator: std.mem.Allocator) void {
    const pair = root.g_miner_pool.pickAutoTxPair(10000) orelse return;
    const sender_wallet = root.g_miner_pool.getWalletAt(pair.sender) orelse return;
    const receiver_wallet = root.g_miner_pool.getWalletAt(pair.receiver) orelse return;

    // Deterministic "random" amount: 1000-10000 SAT based on block number
    const auto_amount: u64 = 1000 + (@as(u64, block_count) * 7 + 13) % 9001;
    const auto_fee: u64 = 1;
    const auto_nonce = bc.getNextAvailableNonce(sender_wallet.getAddress());
    const auto_tx_id: u32 = 1_000_000 + block_count * 10;

    var auto_tx = sender_wallet.createSignedTx(
        receiver_wallet.getAddress(), auto_amount, auto_tx_id, auto_nonce, auto_fee, allocator,
    ) catch return;
    _ = &auto_tx;

    bc.addTransaction(auto_tx) catch |err| {
        std.debug.print("[AUTO-TX] Mempool reject: {}\n", .{err});
        return;
    };

    if (block_count % 50 == 0) {
        std.debug.print("[AUTO-TX] {s}... -> {s}... | {d} SAT\n", .{
            sender_wallet.getAddress()[0..@min(20, sender_wallet.address_len)],
            receiver_wallet.getAddress()[0..@min(20, receiver_wallet.address_len)],
            auto_amount,
        });
    }
}

// ─── Faucet auto-refill (Faza 5) ────────────────────────────────────────────
//
// When the faucet wallet's balance dips below FAUCET_REFILL_THRESHOLD_SAT,
// transfer FAUCET_REFILL_AMOUNT_SAT from the miner's primary wallet
// (savacazan or whoever runs --faucet-mode) into the faucet wallet. This
// keeps the faucet replenished automatically as the operator mines blocks.
//
// Both thresholds are deliberately conservative for testnet — operator with
// 1 OMNI of mining rewards can sustain ~10 refills before their primary
// wallet goes empty.

/// Below this SAT count, kick a refill on the next tick.
pub const FAUCET_REFILL_THRESHOLD_SAT: u64 = 500_000_000; // 0.5 OMNI
/// Send this much to faucet on each refill (=10 claims worth at 0.1 OMNI).
pub const FAUCET_REFILL_AMOUNT_SAT: u64 = 1_000_000_000; // 1 OMNI
/// Loop tick interval — slow enough not to spam the chain, fast enough
/// that a busy faucet stays funded.
pub const FAUCET_REFILL_TICK_S: u64 = 30;

pub const FaucetRefillArgs = struct {
    bc: *Blockchain,
    miner_wallet: *Wallet,
    faucet_wallet: *Wallet,
    grant_sat: u64,
    alloc: std.mem.Allocator,
};

pub fn faucetRefillLoop(args: *FaucetRefillArgs) void {
    defer args.alloc.destroy(args);
    var tx_counter: u32 = 9_000_000; // unique-ish nonce range for refill TXs
    // Exponential backoff after consecutive failures so we don't spam the
    // mempool when something is structurally wrong (e.g. miner balance
    // already pinned by an earlier rejected TX). Resets to base on success.
    var backoff_multiplier: u32 = 1;
    const MAX_BACKOFF_MULT: u32 = 32; // 30s × 32 = 16 minutes max sleep

    while (true) {
        const sleep_s = FAUCET_REFILL_TICK_S * backoff_multiplier;
        std.Thread.sleep(sleep_s * std.time.ns_per_s);

        const faucet_bal = args.bc.getAddressBalance(args.faucet_wallet.address);
        if (faucet_bal >= FAUCET_REFILL_THRESHOLD_SAT) {
            // Faucet is fine. Reset backoff so we react quickly when it drains.
            backoff_multiplier = 1;
            continue;
        }

        // Effective miner balance = on-chain balance MINUS amount already
        // committed by pending mempool TXs. If a previous refill is still
        // sitting in the mempool, asking for another would fail validation
        // (insufficient available balance) and lock the loop in retry hell.
        const miner_bal = args.bc.getAddressBalance(args.miner_wallet.address);
        const fee_sat: u64 = mempool_mod.TX_MIN_FEE_SAT;

        // Skip if miner already has a pending TX that hasn't confirmed —
        // adding another refill while one is in flight just multiplies the
        // failure. Waiting one more tick lets the queued one mine first.
        const next_nonce = args.bc.getNextAvailableNonce(args.miner_wallet.address);
        const chain_nonce = args.bc.nonces.get(args.miner_wallet.address) orelse 0;
        if (next_nonce > chain_nonce) {
            std.debug.print(
                "[FAUCET-REFILL] miner has {d} pending TX(s) — waiting for them to mine\n",
                .{next_nonce - chain_nonce},
            );
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        }

        if (miner_bal < FAUCET_REFILL_AMOUNT_SAT + fee_sat) {
            std.debug.print(
                "[FAUCET-REFILL] miner balance {d} too low to top up faucet (needs {d}+{d}), backing off\n",
                .{ miner_bal, FAUCET_REFILL_AMOUNT_SAT, fee_sat },
            );
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        }

        tx_counter +%= 1;
        var tx = args.miner_wallet.createTransactionFull(
            args.faucet_wallet.address,
            FAUCET_REFILL_AMOUNT_SAT,
            tx_counter,
            next_nonce,
            fee_sat,
            0,
            "",
            args.alloc,
        ) catch |err| {
            std.debug.print("[FAUCET-REFILL] sign error: {}\n", .{err});
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        };
        if (!tx.isValid()) {
            std.debug.print("[FAUCET-REFILL] TX failed isValid\n", .{});
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        }

        args.bc.registerPubkey(args.miner_wallet.address, args.miner_wallet.addresses[0].public_key_hex) catch {};
        args.bc.addTransaction(tx) catch |err| {
            std.debug.print("[FAUCET-REFILL] mempool refused: {} (backoff {d}x)\n", .{ err, backoff_multiplier });
            backoff_multiplier = @min(backoff_multiplier * 2, MAX_BACKOFF_MULT);
            continue;
        };

        std.debug.print(
            "[FAUCET-REFILL] queued top-up: miner -> faucet {d} SAT (faucet bal was {d}, miner bal {d})\n",
            .{ FAUCET_REFILL_AMOUNT_SAT, faucet_bal, miner_bal },
        );
        // Success — reset backoff for next round.
        backoff_multiplier = 1;
    }
}
