//! mineBlock + mineBlockForMiner extracted from blockchain.zig.
//!
//! PoW mining loop, mempool drain, miner reward, validator-set refresh,
//! difficulty retarget. Kept as free functions taking `*Blockchain`;
//! the Blockchain struct exposes thin method shims that delegate here.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const block_mod = @import("../block.zig");
const main_mod = @import("../main.zig");
const hex_utils = @import("../hex_utils.zig");
const oracle_types = @import("../oracle_types.zig");
const utxo_mod = @import("../utxo.zig");
const spark_consensus = @import("../spark_consensus.zig");

const array_list = std.array_list;

const Blockchain = blockchain_mod.Blockchain;
const Block = blockchain_mod.Block;
const Transaction = blockchain_mod.Transaction;
const BlockPriceEntry = blockchain_mod.BlockPriceEntry;
const RETARGET_INTERVAL = blockchain_mod.RETARGET_INTERVAL;
const TARGET_INTERVAL_S = blockchain_mod.TARGET_INTERVAL_S;
const FEE_BURN_PCT = blockchain_mod.FEE_BURN_PCT;
const blockRewardAt = blockchain_mod.blockRewardAt;
const retargetDifficulty = blockchain_mod.retargetDifficulty;

pub fn mineBlock(self: *Blockchain) !Block {
    return self.mineBlockForMiner("");
}

pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
    // PHASE C.3 — open the legitimate-write window for the duration
    // of the mine. The credit/debit calls below funnel through
    // creditBalance (mutex + creditBalanceLocked), and the audit
    // counter inside *Locked checks self.in_apply_block.
    self.in_apply_block = true;
    defer self.in_apply_block = false;

    // NU lock aici — PoW dureaza secunde, ar bloca tot RPC-ul
    // Lock doar pe secțiunile critice (read chain, write chain, update balances)
    if (self.chain.items.len == 0) {
        return error.EmptyChain;
    }

    // Lock doar pentru citire chain state
    self.mutex.lock();
    const previous_block = self.chain.items[self.chain.items.len - 1];
    const index = self.chain.items.len;
    self.mutex.unlock();
    const timestamp = std.time.timestamp();

    const reward = if (miner_address.len > 0) blockRewardAt(@intCast(index)) else 0;

    // Copy miner address — slice-ul extern poate fi din MinerPool global
    const miner_addr_owned = try self.allocator.dupe(u8, miner_address);

    var block = Block{
        .index = @intCast(index),
        .timestamp = timestamp,
        .transactions = self.mempool,
        .previous_hash = previous_block.hash,
        .nonce = 0,
        .hash = "",
        .miner_address = miner_addr_owned,
        .miner_heap = true,
        .reward_sat = reward,
    };

    // Calculate Merkle Root (commits to all TX in block header, like Bitcoin)
    block.merkle_root = block.calculateMerkleRoot();

    // ── Snapshot oracle prices into the block BEFORE PoW ────────────────
    // Why before PoW: calculateHash() now mixes prices_root into the
    // header. If prices were attached after mining, an attacker could
    // swap them without redoing PoW. By calling setPrices() first we
    // bind the snapshot to the work the miner is about to do — any
    // tampering invalidates the nonce.
    //
    // Conversion: ws_exchange_feed.PriceFetch (slice-backed strings)
    // → oracle_types.BlockPriceEntry (fixed-size strings, no allocator).
    // Genesis path never reaches here (index==0 chain is rejected at the
    // top), but if the WS feed is null we just leave the default-init
    // empty entries → prices_root stays all-zeros.
    if (main_mod.g_ws_feed) |*feed| {
        const live = feed.getImportantSnapshot();
        var entries: [oracle_types.BLOCK_PRICE_SLOTS]oracle_types.BlockPriceEntry = undefined;
        for (live, 0..) |p, i| {
            var e: oracle_types.BlockPriceEntry = .{};
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
        block.setPrices(entries);
    }

    // Proof-of-Work hot loop — optimized 2026-05 (PERF_HOTSPOTS #1).
    //
    // Old path: per nonce we rebuilt the entire SHA-256 input, hex-encoded
    // the result into a heap-allocated 64-byte string, and walked ASCII
    // chars to count leading '0's. Each miss heap-freed the string. That
    // burned ~95% of the cycle budget on formatting and allocation rather
    // than hashing.
    //
    // New path:
    //   1. Pre-seed an SHA-256 state with the static prefix (index|ts|
    //      prev_hash_len) once per block attempt.
    //   2. Per nonce: clone the state, feed nonce decimal digits + tx
    //      hashes, finalize → [32]u8.
    //   3. Compare raw bytes against the difficulty target (no hex).
    // Hex conversion only happens once, on the accepted nonce, to keep
    // block.hash in its canonical 64-char hex form for storage/RPC.
    //
    // Consensus-equivalent: hex_utils.MiningPrefix.buildHash() feeds the
    // hasher in exactly the same byte order as the legacy path
    // (calculateBlockHashHex), so the digest for any (header, nonce) pair
    // is bit-identical. Difficulty check via meetsDifficultyRaw matches
    // isValidHashDifficulty's leading-hex-zero semantics.
    var tx_hashes_buf: [10000][]const u8 = undefined;
    const tx_count = @min(block.transactions.items.len, 10000);
    for (0..tx_count) |i| {
        tx_hashes_buf[i] = block.transactions.items[i].hash;
    }
    const tx_hashes_slice = tx_hashes_buf[0..tx_count];
    const mining_prefix = hex_utils.MiningPrefix.init(
        block.index, block.timestamp, block.previous_hash.len, &.{},
    );

    var nonce: u64 = 0;
    const MAX_NONCE: u64 = 4_294_967_296; // 2^32 — if not found, re-roll with new timestamp
    while (nonce < MAX_NONCE) {
        const raw = mining_prefix.buildHash(nonce, tx_hashes_slice);
        if (hex_utils.meetsDifficultyRaw(raw, self.difficulty)) {
            block.nonce = nonce;
            block.hash = try hex_utils.bytesToHexAlloc(raw, self.allocator);
            break;
        }
        nonce += 1;
    }

    // Proceseaza tranzactiile: debiteaza sender (amount + fee), crediteaza receiver, incrementeaza nonce
    var total_fees: u64 = 0;
    for (block.transactions.items) |tx| {
        const total_needed = tx.amount + tx.fee;
        // UTXO: spend sender's inputs.
        // FIX (2026-05-03): nu mai sarim TX-urile cand selectUTXOs esueaza.
        // Pentru wire-v1 (fara inputs[]/outputs[] explicite), validateTransaction
        // a verificat deja balance >= amount+fee inainte de mempool-add. Daca
        // selectUTXOs nu reuseste totusi sa acopere need-ul (ex: UTXO-uri inca
        // ne-indexate dupa restart sau tranzactii externe semnate de noi useri),
        // facem fallback la per-address balance bookkeeping si lasam UTXO-ul
        // recipient-ului sa fie creat pe baza credit-ului. recalculateFromHeight
        // la urmatorul restart va reconcilia UTXO-urile complet.
        var selection_opt: ?utxo_mod.UTXOSet.Selection = null;
        if (self.utxo_set.selectUTXOs(tx.from_address, total_needed, @intCast(index), self.allocator)) |sel| {
            selection_opt = sel;
        } else |err| {
            std.debug.print("[MINE] selectUTXOs failed for {s}: {} — fallback la balance check (v1)\n",
                .{tx.from_address[0..@min(20, tx.from_address.len)], err});
        }
        if (selection_opt) |*selection| {
            defer selection.utxos.deinit(self.allocator);
            for (selection.utxos.items) |utxo| {
                _ = self.utxo_set.spendUTXO(utxo.tx_hash, utxo.output_index) catch |err| {
                    std.debug.print("[MINE] spendUTXO failed: {}\n", .{err});
                };
            }
            // UTXO: change output back to sender
            if (selection.total > total_needed) {
                const change = selection.total - total_needed;
                self.utxo_set.addUTXO(tx.hash, 1, tx.from_address, change, @intCast(index), "", false) catch {};
            }
        }

        self.debitBalance(tx.from_address, tx.amount + tx.fee) catch {}; // debit amount + fee
        self.creditBalance(tx.to_address, tx.amount) catch {};
        total_fees += tx.fee;
        // Incrementeaza nonce-ul sender-ului (anti-replay: urmatoarea TX trebuie nonce+1)
        const current_nonce = self.nonces.get(tx.from_address) orelse 0;
        self.nonces.put(tx.from_address, current_nonce + 1) catch {};
        // Track TX → block height for confirmation counting
        self.tx_block_height.put(tx.hash, @intCast(index)) catch {};
        // Update derived stake/agent state from op_return memo
        self.applyOpReturnRoles(tx);
        // Index TX for both sender and receiver address history
        self.indexAddressTx(tx.from_address, tx.hash);
        self.indexAddressTx(tx.to_address, tx.hash);
        // UTXO: create output for recipient at index 0
        self.utxo_set.addUTXO(tx.hash, 0, tx.to_address, tx.amount, @intCast(index), "", false) catch {};
    }

    // Fee split: FEE_BURN_PCT% burned (deflationary, like EIP-1559), rest to miner
    const fees_burned = total_fees * FEE_BURN_PCT / 100;
    const fees_to_miner = total_fees - fees_burned;
    blockchain_mod.total_fees_burned_sat += fees_burned;

    // Block reward + miner's share of fees
    if (miner_address.len > 0 and (reward > 0 or fees_to_miner > 0)) {
        self.creditBalance(miner_address, reward + fees_to_miner) catch {};
        // UTXO: coinbase output for miner (needs 100 confirmations to spend)
        self.utxo_set.addUTXO(block.hash, 0, miner_address, reward + fees_to_miner, @intCast(index), "", true) catch {};
        std.debug.print("[REWARD] Miner {s} +{d} SAT ({d:.2} OMNI) + {d} fees ({d} burned) @ block {d}\n",
            .{ miner_address[0..@min(16, miner_address.len)], reward,
               @as(f64, @floatFromInt(reward)) / 1e9, fees_to_miner, fees_burned, index });
    }

    // Lock pentru chain write + balance update
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.chain.append(block);

    // ── SPARK Sub-Block Consensus — 10-layer validation ──────────────────────
    // Run all 10 validation layers against the freshly mined block.
    // Uses the miner's own address as the validator identity (node = single
    // validator on testnet; multi-validator on mainnet each runs this loop
    // independently and broadcasts their votes via P2P).
    //
    // No allocator used inside validateBlock — all stack/global.
    {
        var validator_addr: [20]u8 = [_]u8{0} ** 20;
        const addr_bytes = @min(miner_address.len, 20);
        @memcpy(validator_addr[0..addr_bytes], miner_address[0..addr_bytes]);

        const spark_votes = spark_consensus.validateBlock(
            self.allocator, &block, validator_addr, self,
        );

        var consensus_state = spark_consensus.BlockConsensusState.init(
            blk: {
                // Extract [32]u8 from block.hash (64-char hex)
                var raw: [32]u8 = [_]u8{0} ** 32;
                if (block.hash.len == 64) {
                    for (0..32) |bi| {
                        const hi = std.fmt.charToDigit(block.hash[bi * 2], 16) catch 0;
                        const lo = std.fmt.charToDigit(block.hash[bi * 2 + 1], 16) catch 0;
                        raw[bi] = (hi << 4) | lo;
                    }
                }
                break :blk raw;
            },
        );
        for (spark_votes) |vote| consensus_state.addVote(vote);
        const trust = consensus_state.computeTrust();

        if (trust == .rejected) {
            std.debug.print("[SPARK] Block #{d} REJECTED by sub-block consensus (attest={d}/10)\n",
                .{ index, consensus_state.attest_count });
        } else if (trust == .low) {
            std.debug.print("[SPARK] Block #{d} LOW TRUST (attest={d}/10) — finalized with warning\n",
                .{ index, consensus_state.attest_count });
        } else {
            std.debug.print("[SPARK] Block #{d} HIGH TRUST (attest={d}/10)\n",
                .{ index, consensus_state.attest_count });
        }

        // Record state for RPC queries (spark_status / spark_votes)
        spark_consensus.recordState(consensus_state);
    }

    // Refresh validator set after a new block: a miner that just
    // crossed MIN_VALIDATOR_BALANCE joins automatically; one whose
    // balance dropped below the threshold drops out. Keeps the set
    // consistent across all nodes (chain-derived → deterministic).
    self.rebuildValidatorSetFromChain() catch |err| {
        std.debug.print("[VALIDATOR-SET] rebuild after mine failed: {}\n", .{err});
    };

    // Difficulty retarget la fiecare RETARGET_INTERVAL blocuri
    if (index % RETARGET_INTERVAL == 0 and index > 0) {
        const retarget_start = index - RETARGET_INTERVAL;
        const old_block_ts = self.chain.items[retarget_start].timestamp;
        const new_block_ts = block.timestamp;
        const actual_time = new_block_ts - old_block_ts;
        const new_diff = retargetDifficulty(self.difficulty, actual_time);
        if (new_diff != self.difficulty) {
            std.debug.print("[RETARGET] Block {d}: difficulty {d} → {d} (actual {d}s, target {d}s)\n",
                .{ index, self.difficulty, new_diff, actual_time, TARGET_INTERVAL_S });
            self.difficulty = new_diff;
        }
    }

    // Reset mempool
    self.mempool = array_list.Managed(Transaction).init(self.allocator);

    return block;
}
