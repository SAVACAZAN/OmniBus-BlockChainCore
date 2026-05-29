//! applyBlock + applyOrderTxs extracted from blockchain.zig.
//!
//! Central state-transition logic + exchange-engine glue. Kept as free
//! functions taking `*Blockchain`; the Blockchain struct exposes thin
//! method shims that delegate here.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const block_mod = @import("../block.zig");
const transaction_mod = @import("../transaction.zig");
const tx_payload_mod = @import("../tx_payload.zig");
const matching_mod = @import("../matching_engine.zig");
const utxo_mod = @import("../utxo.zig");
const swap_link_mod = @import("../order_swap_link.zig");
const dns_mod = @import("../dns_registry.zig");
const registrar_mod = @import("../registrar_addresses.zig");
const sub_mod = @import("../subscription.zig");
const treasury_multi_mod = @import("../treasury_multi.zig");

const Blockchain = blockchain_mod.Blockchain;
const Block = blockchain_mod.Block;
const Transaction = blockchain_mod.Transaction;
const RETARGET_INTERVAL = blockchain_mod.RETARGET_INTERVAL;
const FEE_BURN_PCT = blockchain_mod.FEE_BURN_PCT;
const ConsensusParams = blockchain_mod.ConsensusParams;
const blockWork = blockchain_mod.blockWork;
const retargetDifficulty = blockchain_mod.retargetDifficulty;

pub fn applyBlock(self: *Blockchain, block: Block) !void {
    // PHASE C.3 — open the legitimate-write window.
    self.in_apply_block = true;
    defer self.in_apply_block = false;

    var total_fees: u64 = 0;

    // ─── PHASE 2B step 1: route typed TXs that DON'T move UTXOs ─────
    // Order place/cancel/modify and bridge management TXs are handled
    // by per-type processors AFTER the classic UTXO transfer loop, so
    // they share consensus state but don't accidentally hit the
    // implicit-coin-selection UTXO path. We collect their indices here
    // and apply them in deterministic order at the end.
    for (block.transactions.items) |tx| {
        const total_needed = tx.amount + tx.fee;
        // Skip non-transfer typed TXs in this loop — they have no UTXO
        // movement (the trader's collateral lock is virtual until fill).
        // Bridge_lock IS a UTXO movement (vault payment) and falls
        // through to the regular path; bridge_unlock_request is virtual.
        if (tx.tx_type != .transfer and tx.tx_type != .bridge_lock) {
            // PHASE 2F.2 — HTLC state transitions before the generic
            // typed-TX fallthrough. Funds are tracked virtually via
            // bc.balances: init debits sender, claim credits recipient,
            // refund credits sender. UTXOs are not touched (the typed
            // TX has amount=0 by convention).
            self.applyHtlcTx(tx, @intCast(block.index)) catch |err| {
                std.debug.print("[HTLC] apply tx {s} type={} failed: {}\n",
                    .{ tx.hash[0..@min(16, tx.hash.len)], tx.tx_type, err });
            };
            // Phase 2F.3 — intent TXs (0x40/0x41/0x43). Routes through
            // applyIntentTx; applyHtlcTx ignored these (else => {}). The
            // dispatch is by tx_type, so a TX won't be double-applied.
            self.applyIntentTx(tx, @intCast(block.index)) catch |err| {
                std.debug.print("[INTENT] apply tx {s} type={} failed: {}\n",
                    .{ tx.hash[0..@min(16, tx.hash.len)], tx.tx_type, err });
            };
            // Still increment nonce + index TX so listings show it.
            const cur_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, cur_nonce + 1) catch {};
            self.tx_block_height.put(tx.hash, @intCast(block.index)) catch {};
            self.indexAddressTx(tx.from_address, tx.hash);
            continue;
        }

        // PHASE-C wire v2: explicit inputs/outputs path.
        // When TX carries inputs[], spend exactly those — no
        // implicit coin-selection. Total of input UTXOs must
        // cover amount+fee (already enforced in validateTransaction).
        // Change goes back to from_address as a single synthetic
        // UTXO unless the TX explicitly listed it in outputs[].
        if (tx.isV2()) {
            var input_total: u64 = 0;
            for (tx.inputs) |inp| {
                if (self.utxo_set.spendUTXO(inp.tx_hash, inp.output_index)) |spent_utxo| {
                    input_total += spent_utxo.amount;
                } else |err| {
                    std.debug.print(
                        "[APPLY-BLOCK v2] spendUTXO failed for input {s}:{d}: {}\n",
                        .{ inp.tx_hash, inp.output_index, err },
                    );
                }
            }
            // Materialise explicit outputs.
            var out_total: u64 = 0;
            for (tx.outputs, 0..) |out, oi| {
                self.utxo_set.addUTXO(
                    tx.hash, @intCast(oi), out.address, out.amount,
                    @intCast(block.index), "", false,
                ) catch {};
                out_total += out.amount;
            }
            // Implicit change to sender if inputs over-pay outputs+fee.
            // (Wallets that want explicit change must list it in outputs.)
            if (input_total > out_total + tx.fee) {
                const change = input_total - out_total - tx.fee;
                const change_idx: u32 = @intCast(tx.outputs.len);
                self.utxo_set.addUTXO(
                    tx.hash, change_idx, tx.from_address, change,
                    @intCast(block.index), "", false,
                ) catch {};
            }
        } else {
            // v1 backward-compat: implicit coin-selection.
            // FIX (2026-05-03): la fel ca in mineBlockForMiner — daca selectUTXOs
            // esueaza pentru wire-v1, NU sarim TX-ul; lasam balance/nonce/index
            // sa fie procesate si lasam recipient UTXO-ul sa fie creat.
            var selection_opt: ?utxo_mod.UTXOSet.Selection = null;
            if (self.utxo_set.selectUTXOs(tx.from_address, total_needed, @intCast(block.index), self.allocator)) |sel| {
                selection_opt = sel;
            } else |err| {
                std.debug.print("[APPLY-BLOCK v1] selectUTXOs failed for {s}: {} — fallback la balance check\n",
                    .{tx.from_address[0..@min(20, tx.from_address.len)], err});
            }
            if (selection_opt) |*selection| {
                defer selection.utxos.deinit(self.allocator);
                for (selection.utxos.items) |utxo| {
                    _ = self.utxo_set.spendUTXO(utxo.tx_hash, utxo.output_index) catch |err| {
                        std.debug.print("[APPLY-BLOCK v1] spendUTXO failed: {}\n", .{err});
                    };
                }
                if (selection.total > total_needed) {
                    const change = selection.total - total_needed;
                    self.utxo_set.addUTXO(tx.hash, 1, tx.from_address, change, @intCast(block.index), "", false) catch {};
                }
            }
            // v1 implicit recipient output at index 0.
            self.utxo_set.addUTXO(tx.hash, 0, tx.to_address, tx.amount, @intCast(block.index), "", false) catch {};
        }

        // RAM cache mirror (write-only for non-replay code; read goes
        // through utxo_set.getBalance per Phase B).
        self.debitBalanceLocked(tx.from_address, tx.amount + tx.fee) catch {};
        self.creditBalanceLocked(tx.to_address, tx.amount) catch {};
        // Cold wallet incoming-receive hook
        self.cold_wallet_store.onReceive(tx.to_address, tx.amount);
        total_fees += tx.fee;
        const current_nonce = self.nonces.get(tx.from_address) orelse 0;
        self.nonces.put(tx.from_address, current_nonce + 1) catch {};
        self.tx_block_height.put(tx.hash, @intCast(block.index)) catch {};
        self.applyOpReturnRoles(tx);
        self.indexAddressTx(tx.from_address, tx.hash);
        self.indexAddressTx(tx.to_address, tx.hash);
    }

    // ─── PHASE 2B+2D: deterministic order matching + fill capture ──
    // Now that all transfers have settled, process order TXs in
    // canonical order (sort by pair_id, price, tx_hash) so every
    // node reaches identical fills regardless of mempool arrival
    // order. Fills produced are recorded in self.fills_history
    // (Phase 2D trade history) keyed by block height.
    self.applyOrderTxs(block) catch |err| {
        std.debug.print("[APPLY-BLOCK] order matching failed: {}\n", .{err});
    };

    const fees_burned = total_fees * FEE_BURN_PCT / 100;
    const fees_to_miner = total_fees - fees_burned;
    blockchain_mod.total_fees_burned_sat += fees_burned;

    // Drain accumulated network fees from applyExchangeFees into this
    // block's miner. See ConsensusParams.route_fees_to_miner. Reset to
    // zero whether or not we credited (orphan-block path may skip the
    // credit but still wants the slate clean for the next attempt).
    const exchange_fees_to_miner: u64 = if (self.consensus_params.route_fees_to_miner)
        self.pending_miner_fees
    else
        0;
    self.pending_miner_fees = 0;

    const total_miner_credit: u64 = block.reward_sat + fees_to_miner + exchange_fees_to_miner;
    if (block.miner_address.len > 0 and total_miner_credit > 0) {
        self.creditBalanceLocked(block.miner_address, total_miner_credit) catch {};
        self.utxo_set.addUTXO(block.hash, 0, block.miner_address, total_miner_credit, @intCast(block.index), "", true) catch {};
        self.total_miner_exchange_fees +|= exchange_fees_to_miner;
    }

    // ── Pay-to-claim NS scan ────────────────────────────────────────────
    //
    // Any TX in the block that pays >= feeForName to the NS treasury
    // (registrar slot 5 = ens.omnibus) AND carries an op_return memo
    // matching `ns_claim:<name>.<tld>` triggers an automatic registry
    // entry naming `<name>.<tld>` to `tx.from_address`. The TX itself
    // is the proof — no separate signed RPC call needed. Fee already
    // moved to treasury as part of the regular UTXO accounting above.
    //
    // Skipped when:
    //   - dns_registry pointer not attached (test paths, light nodes)
    //   - ens.omnibus slot has no canonical address yet (mainnet pre-fill)
    //   - registry full / name reserved / owner capped — claimByPayment
    //     reports the error, we log and continue (other TXs still apply).
    if (self.dns_registry) |dns| {
        if (registrar_mod.addressOf(.ens)) |ns_treasury| {
            for (block.transactions.items) |tx| {
                if (tx.op_return.len == 0) continue;
                const claim = dns_mod.parseClaimMemo(tx.op_return) orelse continue;
                if (!std.mem.eql(u8, tx.to_address, ns_treasury)) continue;
                // Sybil-resistant pricing: an owner already holding many
                // names pays a progressively larger fee per new claim.
                // Pay-to-claim is always 1-year (no `years` field in the
                // op_return memo), so feeForRegistrationWithOwnerCount
                // with years=1 reduces to feeForName × sybilMultiplier.
                const owner_count = dns.countNamesOwnedBy(
                    tx.from_address, @intCast(block.index));
                const required_fee = dns_mod.feeForRegistrationWithOwnerCount(
                    claim.name, claim.tld, 1, owner_count);
                if (tx.amount < required_fee) {
                    std.debug.print(
                        "[NS-CLAIM] underpaid: {s}.{s} need {d} got {d} (owner has {d} names)\n",
                        .{ claim.name, claim.tld, required_fee, tx.amount, owner_count },
                    );
                    continue;
                }
                dns.claimByPayment(claim.name, claim.tld, tx.from_address, @intCast(block.index)) catch |err| {
                    std.debug.print(
                        "[NS-CLAIM] reject {s}.{s} from {s}: {}\n",
                        .{ claim.name, claim.tld, tx.from_address, err },
                    );
                    continue;
                };
                std.debug.print(
                    "[NS-CLAIM] {s}.{s} -> {s} (paid {d} sat at block {d})\n",
                    .{ claim.name, claim.tld, tx.from_address, tx.amount, block.index },
                );
            }
        }
    }

    // ── Governance proposal finalization + auto-execute ─────────────────
    // finalizeProposals flips voting → passed/rejected/expired for any
    // proposal whose voting_end_block < current. autoExecutePassedProposals
    // then runs each newly-passed action against consensus_params and marks
    // it .executed so it never re-runs.
    self.gov_registry.finalizeProposals(@intCast(block.index));
    self.autoExecutePassedProposals(@intCast(block.index));

    // ── Escrow auto-refund (timeout expired) ────────────────────────────
    // Verifica escrow-uri timed-out si returneaza fondurile la from_address.
    {
        var timed_out: [32]u64 = undefined;
        const n_to = self.escrow_registry.collectTimedOut(@intCast(block.index), &timed_out);
        for (timed_out[0..n_to]) |esc_id| {
            const esc = self.escrow_registry.get(esc_id) orelse continue;
            // Auto-refund: nu necesita TX explicit, chain o face automat
            const amount = self.escrow_registry.tryRefund(
                esc_id, esc.fromSlice(), @intCast(block.index),
            );
            if (amount > 0) {
                const bal = self.balances.get(esc.fromSlice()) orelse 0;
                self.balances.put(esc.fromSlice(), bal + amount) catch {};
                std.debug.print("[ESCROW-TIMEOUT] id={d} refund={d} to={s}\n",
                    .{ esc_id, amount, esc.fromSlice()[0..@min(16, esc.fromSlice().len)] });
            }
        }
    }

    // ── Subscription auto-execution ─────────────────────────────────────
    // For every subscription due at this block height, debit the
    // subscriber and credit the recipient directly in the balance cache.
    // Skips if subscriber doesn't have enough funds (payment deferred to
    // next interval — subscription stays active, not cancelled).
    {
        var due_ids: [64]u64 = undefined;
        const n_due = self.sub_registry.collectDue(@intCast(block.index), &due_ids);
        for (due_ids[0..n_due]) |sub_id| {
            const sub = self.sub_registry.get(sub_id) orelse continue;
            const total_debit = sub.amount_sat + sub_mod.SUB_EXEC_FEE_SAT;
            const from_bal = self.balances.get(sub.fromSlice()) orelse 0;
            if (from_bal < total_debit) {
                // Insufficient funds — defer, advance next_block anyway
                self.sub_registry.markExecuted(sub_id, @intCast(block.index));
                continue;
            }
            self.balances.put(sub.fromSlice(), from_bal - total_debit) catch {};
            const to_bal = self.balances.get(sub.toSlice()) orelse 0;
            self.balances.put(sub.toSlice(), to_bal + sub.amount_sat) catch {};
            // SUB_EXEC_FEE goes to miner (already in block.reward via fee accounting)
            self.sub_registry.markExecuted(sub_id, @intCast(block.index));
            std.debug.print("[SUB-EXEC] id={d} from={s} to={s} amount={d}\n",
                .{ sub_id, sub.fromSlice()[0..@min(16, sub.fromSlice().len)],
                   sub.toSlice()[0..@min(16, sub.toSlice().len)], sub.amount_sat });
        }
    }

    // ── Treasury auto-distribution hook ─────────────────────────────────
    // Check all active treasuries; if balance >= trigger_amount_sat,
    // auto-distribute to destinations (split by share_bps).
    // NOTE: Treasury structs are large (~8.7 KB each); use heap to avoid
    // stack overflow on every block apply.
    {
        const treas_buf = try self.allocator.alloc(treasury_multi_mod.Treasury, 64);
        defer self.allocator.free(treas_buf);
        const n_treas = self.treasury_multi_store.listAll(treas_buf[0..64]);
        for (treas_buf[0..n_treas]) |treas| {
            if (treas.trigger_amount_sat == 0) continue; // manual-only
            const bal = self.balances.get(treas.treasurySlice()) orelse 0;
            if (bal < treas.trigger_amount_sat) continue;
            var distributed: u64 = 0;
            var di: usize = 0;
            while (di < treas.dest_count) : (di += 1) {
                const dest_amt = treas.destAmount(di, bal);
                if (dest_amt == 0) continue;
                if (bal < distributed + dest_amt) break;
                distributed += dest_amt;
                const to_bal = self.balances.get(treas.destinations[di].addressSlice()) orelse 0;
                self.balances.put(treas.destinations[di].addressSlice(), to_bal + dest_amt) catch {};
            }
            if (distributed > 0) {
                const from_bal = self.balances.get(treas.treasurySlice()) orelse 0;
                self.balances.put(treas.treasurySlice(), from_bal -| distributed) catch {};
                self.treasury_multi_store.recordDistribute(
                    treas.id[0..treasury_multi_mod.ID_HEX_LEN], distributed, @intCast(block.index),
                );
                std.debug.print("[TREASURY] auto-distribute {d} sat from {s}\n",
                    .{ distributed, treas.treasurySlice()[0..@min(20, treas.treasurySlice().len)] });
            }
        }
    }

    try self.chain.append(block);

    // Update cumulative work — proxy for 2^256 / target. Difficulty is
    // expressed as leading-zero hex digits, so adding a block at
    // difficulty D contributes work = 1 << (4*D). u128 prevents overflow
    // even at D=32 (work=2^128) over millions of blocks.
    self.cumulative_work += blockWork(self.difficulty);

    // Difficulty retarget
    const index = self.chain.items.len - 1;
    if (index % RETARGET_INTERVAL == 0 and index > 0) {
        const retarget_start = index - RETARGET_INTERVAL;
        const old_block_ts = self.chain.items[retarget_start].timestamp;
        const new_block_ts = block.timestamp;
        const actual_time = new_block_ts - old_block_ts;
        const new_diff = retargetDifficulty(self.difficulty, actual_time);
        if (new_diff != self.difficulty) {
            self.difficulty = new_diff;
        }
    }
}

pub fn applyOrderTxs(self: *Blockchain, block: Block) !void {
    // Engine may be null on light nodes / replay paths. Accept the
    // TXs as recorded in history but skip matching.
    const engine_opt: ?*matching_mod.MatchingEngine = self.exchange_engine;

    // PHASE 2D — record the engine.fill_count BEFORE this block's order
    // TXs run, so we can slice the new fills generated for this block.
    const fills_before: u32 = if (engine_opt) |e| e.fill_count else 0;

    // ── Step 1: cancels first (frees collateral before matching) ──
    for (block.transactions.items) |tx| {
        if (tx.tx_type != .order_cancel) continue;
        const payload = tx_payload_mod.OrderCancelPayload.decode(tx.data) catch |err| {
            std.debug.print("[ORDER-CANCEL] decode {s} failed: {}\n",
                .{ tx.hash[0..@min(16, tx.hash.len)], err });
            continue;
        };
        if (engine_opt) |eng| {
            eng.cancelOrder(payload.order_id) catch |err| switch (err) {
                error.OrderNotFound => {}, // already cancelled / filled
                else => std.debug.print("[ORDER-CANCEL] {d}: {}\n", .{ payload.order_id, err }),
            };
        }
    }

    // ── Step 2: collect + canonical sort of order_place TXs ───────
    var place_txs = std.ArrayList(usize){};
    defer place_txs.deinit(self.allocator);
    for (block.transactions.items, 0..) |tx, idx| {
        if (tx.tx_type != .order_place) continue;
        place_txs.append(self.allocator, idx) catch continue;
    }
    if (place_txs.items.len == 0) return; // nothing to match

    // Canonical sort: pair_id ASC, price ASC, tx_hash ASC.
    // No timestamps (clock-attackable), no mempool order
    // (non-deterministic). Tx hash is the unfakeable post-image.
    const SortCtx = struct {
        txs: []const transaction_mod.Transaction,
        fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
            const a_tx = ctx.txs[a_idx];
            const b_tx = ctx.txs[b_idx];
            const ap = tx_payload_mod.OrderPlacePayload.decode(a_tx.data) catch
                return false;
            const bp = tx_payload_mod.OrderPlacePayload.decode(b_tx.data) catch
                return false;
            if (ap.pair_id != bp.pair_id) return ap.pair_id < bp.pair_id;
            if (ap.price_micro_usd != bp.price_micro_usd)
                return ap.price_micro_usd < bp.price_micro_usd;
            return std.mem.lessThan(u8, a_tx.hash, b_tx.hash);
        }
    };
    std.mem.sort(usize, place_txs.items, SortCtx{ .txs = block.transactions.items },
        SortCtx.lessThan);

    // ── Step 3: push each order through the matching engine ───────
    for (place_txs.items) |idx| {
        const tx = block.transactions.items[idx];
        const payload = tx_payload_mod.OrderPlacePayload.decode(tx.data) catch continue;

        // Check for optional cross-chain trailer. When present + chain != 0,
        // we register a SwapBinding before (or in parallel with) placing
        // the order. The Omnibus side still goes through the matching
        // engine so a local taker can match it; the binding tracks the
        // remote-chain HTLC counterpart.
        const trailer_opt: ?tx_payload_mod.OrderCrossChainTrailer = blk: {
            const got = tx_payload_mod.decodeOrderPlaceWithTrailer(tx.data) catch break :blk null;
            break :blk got.trailer;
        };

        var assigned_order_id: u64 = 0;
        if (engine_opt) |eng| {
            var order = matching_mod.Order.empty();
            order.side = switch (payload.side) {
                .buy => .buy,
                .sell => .sell,
            };
            order.pair_id = payload.pair_id;
            order.price_micro_usd = payload.price_micro_usd;
            order.amount_sat = payload.amount_sat;
            order.timestamp_ms = block.timestamp;
            const tn = @min(tx.from_address.len, order.trader_address.len);
            @memcpy(order.trader_address[0..tn], tx.from_address[0..tn]);
            order.trader_addr_len = @intCast(tn);
            order.status = .active;

            // Capture the order_id assigned by the matching engine
            // before placing (eng.next_order_id is the next id it will
            // hand out — it bumps on success, so this is correct).
            assigned_order_id = eng.next_order_id;
            eng.placeOrder(order) catch |err| {
                std.debug.print("[ORDER-PLACE] {s} pair={d}: {}\n",
                    .{ tx.from_address[0..@min(16, tx.from_address.len)],
                       payload.pair_id, err });
                assigned_order_id = 0; // signal failure
            };
        }

        // ─ cross-chain binding ─────────────────────────────────────
        if (trailer_opt) |t| {
            if (assigned_order_id == 0) continue; // engine rejected
            const taker_chain = swap_link_mod.Chain.fromU8(t.cross_chain_chain) orelse continue;
            if (taker_chain == .omnibus) continue; // not actually cross-chain
            // Build references. Maker side = Omnibus (the order TX itself is
            // the on-chain commitment; we use the tx hash as a synthetic
            // htlc id until htlc_init lands). Taker side = remote chain;
            // we copy the first 32 bytes of the htlc_ref blob as a
            // chain-agnostic anchor.
            var maker_anchor: [32]u8 = undefined;
            {
                const hn = @min(tx.hash.len, 32);
                @memset(&maker_anchor, 0);
                @memcpy(maker_anchor[0..hn], tx.hash[0..hn]);
            }
            const maker_ref = swap_link_mod.HtlcRef{ .omnibus = maker_anchor };
            const taker_ref: swap_link_mod.HtlcRef = switch (taker_chain) {
                .btc => blk: {
                    var txid: [32]u8 = undefined;
                    @memcpy(&txid, t.cross_chain_htlc_ref[0..32]);
                    const vout = std.mem.readInt(u32, t.cross_chain_htlc_ref[32..36], .little);
                    break :blk swap_link_mod.HtlcRef{ .btc = .{ .txid = txid, .vout = vout } };
                },
                .eth, .base, .liberty => blk: {
                    const chain_id = std.mem.readInt(u64, t.cross_chain_htlc_ref[0..8], .little);
                    var contract: [20]u8 = undefined;
                    @memcpy(&contract, t.cross_chain_htlc_ref[8..28]);
                    var hid: [32]u8 = std.mem.zeroes([32]u8);
                    @memcpy(hid[0..12], t.cross_chain_htlc_ref[28..40]);
                    break :blk swap_link_mod.HtlcRef{ .eth = .{
                        .chain_id = chain_id,
                        .contract = contract,
                        .id = hid,
                    } };
                },
                .omnibus => unreachable,
            };
            self.swap_registry.open(
                assigned_order_id,
                t.cross_chain_hash_lock,
                .omnibus, // maker side is Omnibus (this chain)
                taker_chain,
                maker_ref,
                taker_ref,
                t.cross_chain_timeout_block,
                block.index,
            ) catch |err| {
                std.debug.print("[SWAP-BIND] open failed order_id={d}: {}\n",
                    .{ assigned_order_id, err });
            };
        }
    }

    // ─── PHASE 2D: capture fills generated by this block ────────────
    // Slice engine.fills[fills_before .. engine.fill_count] is the set
    // of fills produced by this block's order TXs. Copy into a
    // heap-owned slice keyed by block height in self.fills_history
    // so RPC endpoints (Ledgers, TradesHistory, OHLC, Spread) can
    // derive responses from chain state.
    if (engine_opt) |eng| {
        const fills_after = eng.fill_count;
        if (fills_after > fills_before) {
            const new_count = fills_after - fills_before;
            const heap_fills = self.allocator.alloc(matching_mod.Fill, new_count) catch {
                std.debug.print("[ORDER-FILLS] alloc failed for {d} fills\n", .{new_count});
                return;
            };
            var i: u32 = 0;
            while (i < new_count) : (i += 1) {
                heap_fills[i] = eng.fills[fills_before + i];
            }
            self.fills_history.put(@intCast(block.index), heap_fills) catch {
                self.allocator.free(heap_fills);
            };
        }
    }
}
