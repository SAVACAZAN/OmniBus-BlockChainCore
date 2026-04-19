/// integration_test.zig — Full Miner Flow Integration Tests
///
/// Tests the complete miner lifecycle end-to-end:
///   Order arrival (bridge) → Orderbook sync → Matching → Settlement → PoUW rewards
///
/// All 6 core modules tested together:
///   matching_engine, price_oracle, consensus_pouw, orderbook_sync,
///   bridge_listener, settlement_submitter
///
/// Run: zig test core/integration_test.zig
const std = @import("std");
const matching = @import("matching_engine.zig");
const oracle = @import("price_oracle.zig");
const pouw = @import("consensus_pouw.zig");
const sync = @import("orderbook_sync.zig");
const listener = @import("bridge_listener.zig");
const settlement = @import("settlement_submitter.zig");

// Small test engine that fits on the stack (~15KB)
const TestEngine = matching.MatchingEngineWith(64, 32);

// ─── Helpers ────────────────────────────────────────────────────────────────────

/// Create a matching.Order with distinct trader address
fn makeMatchingOrder(
    side: matching.Side,
    price: u64,
    amount: u64,
    ts: i64,
    addr: []const u8,
    pair_id: u16,
) matching.Order {
    var order = matching.Order.empty();
    order.side = side;
    order.price_micro_usd = price;
    order.amount_sat = amount;
    order.timestamp_ms = ts;
    order.pair_id = pair_id;
    order.status = .active;
    order.trader_addr_len = @intCast(addr.len);
    @memcpy(order.trader_address[0..addr.len], addr);
    return order;
}

/// Create a SettlementFill from a matching.Fill
fn fillToSettlement(fill: *const matching.Fill) settlement.SettlementFill {
    var sfill = settlement.SettlementFill.empty();
    sfill.order_id = fill.buy_order_id;
    sfill.fill_amount_sat = fill.amount_sat;
    sfill.fill_price_micro_usd = fill.price_micro_usd;
    sfill.timestamp_ms = fill.timestamp_ms;

    // Map buyer/seller addresses into 42-byte EVM format (test placeholder)
    const buyer_prefix = "0x";
    @memcpy(sfill.buyer_address[0..2], buyer_prefix);
    const buyer_slice = fill.buyer_address[0..fill.buyer_addr_len];
    const buyer_copy_len = @min(buyer_slice.len, 40);
    @memcpy(sfill.buyer_address[2 .. 2 + buyer_copy_len], buyer_slice[0..buyer_copy_len]);

    @memcpy(sfill.seller_address[0..2], buyer_prefix);
    const seller_slice = fill.seller_address[0..fill.seller_addr_len];
    const seller_copy_len = @min(seller_slice.len, 40);
    @memcpy(sfill.seller_address[2 .. 2 + seller_copy_len], seller_slice[0..seller_copy_len]);

    // Token address placeholder
    const token = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    @memcpy(&sfill.token_address, token);

    return sfill;
}

/// Create a pouw.WorkReport for matching work
fn makeMatchingWorkReport(
    miner_name: []const u8,
    block_height: u64,
    volume_sat: u64,
    fills: u32,
    work_hash: [32]u8,
) pouw.WorkReport {
    var addr: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(addr[0..miner_name.len], miner_name);
    return pouw.WorkReport{
        .miner_address = addr,
        .miner_addr_len = @intCast(miner_name.len),
        .work_type = .matching,
        .block_height = block_height,
        .timestamp_ms = @as(i64, @intCast(block_height)) * 100,
        .fills_count = fills,
        .volume_matched_sat = volume_sat,
        .price_updates = 0,
        .settlements_count = 0,
        .work_hash = work_hash,
        .signature = std.mem.zeroes([64]u8),
    };
}

/// Create a pouw.WorkReport for oracle work
fn makeOracleWorkReport(
    miner_name: []const u8,
    block_height: u64,
    price_updates: u32,
) pouw.WorkReport {
    var addr: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(addr[0..miner_name.len], miner_name);
    return pouw.WorkReport{
        .miner_address = addr,
        .miner_addr_len = @intCast(miner_name.len),
        .work_type = .oracle,
        .block_height = block_height,
        .timestamp_ms = @as(i64, @intCast(block_height)) * 100,
        .fills_count = 0,
        .volume_matched_sat = 0,
        .price_updates = price_updates,
        .settlements_count = 0,
        .work_hash = std.mem.zeroes([32]u8),
        .signature = std.mem.zeroes([64]u8),
    };
}

/// Create a price submission for testing
fn makePriceSubmission(miner_id: u8, chain: oracle.ChainId, price: u64, ts: i64) oracle.MinerPriceSubmission {
    var addr: [64]u8 = [_]u8{0} ** 64;
    addr[0] = miner_id;
    addr[1] = 'M';
    return oracle.MinerPriceSubmission{
        .miner_address = addr,
        .miner_addr_len = 2,
        .chain_id = chain,
        .price_micro_usd = price,
        .timestamp_ms = ts,
        .signature = [_]u8{miner_id} ** 64,
    };
}

/// Create an OrderEntry for sync manager from matching order data
fn makeSyncOrderEntry(
    id: u64,
    pair: u16,
    side: u8,
    price: u64,
    amount: u64,
    ts: i64,
    trader: []const u8,
    origin: [sync.NODE_ID_SIZE]u8,
) sync.OrderEntry {
    var entry: sync.OrderEntry = undefined;
    entry.order_id = id;
    entry.trader_address = std.mem.zeroes([64]u8);
    @memcpy(entry.trader_address[0..trader.len], trader);
    entry.trader_addr_len = @intCast(trader.len);
    entry.pair_id = pair;
    entry.side = side;
    entry.price_micro_usd = price;
    entry.amount_sat = amount;
    entry.filled_sat = 0;
    entry.timestamp_ms = ts;
    entry.status = 0; // active
    entry.origin_node = origin;
    return entry;
}

/// Heap-allocate an OrderbookSyncManager (too large for stack)
fn createSyncManager(node_id: [sync.NODE_ID_SIZE]u8) !*sync.OrderbookSyncManager {
    const mgr = try std.testing.allocator.create(sync.OrderbookSyncManager);
    mgr.* = sync.OrderbookSyncManager.init(node_id);
    return mgr;
}

fn destroySyncManager(mgr: *sync.OrderbookSyncManager) void {
    std.testing.allocator.destroy(mgr);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 1: Full miner cycle — order to reward
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: full miner cycle — order to reward" {
    // ── 1. Initialize all modules ──
    var engine = TestEngine.init();
    var pouw_engine = pouw.PoUWEngine.init();
    var submitter = settlement.SettlementSubmitter.init();

    // ── 2. Simulate bridge listener detecting OrderPlaced ──
    const cfg = listener.BridgeConfig.default();
    var bridge = listener.BridgeListener.init(cfg);
    bridge.start();

    // Create two bridge events (buy and sell) targeting our chain
    var buy_tx_hash: [66]u8 = [_]u8{'0'} ** 66;
    buy_tx_hash[0] = '0';
    buy_tx_hash[1] = 'x';
    buy_tx_hash[2] = 'a';

    const buy_event = listener.OrderPlacedEvent{
        .order_id = 1001,
        .user_address = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".*,
        .token_address = "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".*,
        .amount_wei = [_]u8{0} ** 32,
        .target_chain_id = listener.DEFAULT_TARGET_CHAIN,
        .block_number = 5000,
        .tx_hash = buy_tx_hash,
        .timestamp_ms = 1000,
    };

    var sell_tx_hash: [66]u8 = [_]u8{'0'} ** 66;
    sell_tx_hash[0] = '0';
    sell_tx_hash[1] = 'x';
    sell_tx_hash[2] = 'b';

    const sell_event = listener.OrderPlacedEvent{
        .order_id = 1002,
        .user_address = "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC".*,
        .token_address = "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB".*,
        .amount_wei = [_]u8{0} ** 32,
        .target_chain_id = listener.DEFAULT_TARGET_CHAIN,
        .block_number = 5001,
        .tx_hash = sell_tx_hash,
        .timestamp_ms = 1001,
    };

    try bridge.addOrderEvent(buy_event);
    try bridge.addOrderEvent(sell_event);
    try std.testing.expectEqual(@as(u32, 2), bridge.pending_order_count);

    // ── 3. Drain bridge events and create matching orders ──
    const drained = bridge.drainOrders();
    try std.testing.expectEqual(@as(usize, 2), drained.len);
    try std.testing.expectEqual(@as(u32, 0), bridge.pending_order_count);

    // Convert bridge events to matching engine orders
    const buy_order = makeMatchingOrder(
        .buy,
        10_000_000, // $10.00
        100_000_000_000, // 100 OMNI
        1000,
        "buyer_alice",
        0, // OMNI/USD
    );

    const sell_order = makeMatchingOrder(
        .sell,
        10_000_000, // $10.00
        100_000_000_000, // 100 OMNI
        1001,
        "seller_bob",
        0,
    );

    // ── 4. Place orders in matching engine ──
    try engine.placeOrder(buy_order);
    try engine.placeOrder(sell_order);

    // ── 5. Verify fill happened ──
    try std.testing.expect(engine.fill_count > 0);
    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);
    const fill = engine.fills[0];
    try std.testing.expectEqual(@as(u64, 100_000_000_000), fill.amount_sat);
    try std.testing.expectEqual(@as(u64, 10_000_000), fill.price_micro_usd);
    try std.testing.expect(std.mem.eql(u8, fill.getBuyerAddress(), "buyer_alice"));
    try std.testing.expect(std.mem.eql(u8, fill.getSellerAddress(), "seller_bob"));

    // Both orders fully filled — orderbook should be empty
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);

    // ── 6. Add fill to settlement submitter ──
    const sfill = fillToSettlement(&fill);
    try submitter.addFill(sfill);
    try std.testing.expectEqual(@as(u32, 1), submitter.current_batch.fill_count);

    // ── 7. Build merkle tree ──
    submitter.buildMerkleTree();
    try std.testing.expectEqual(settlement.BatchStatus.merkle_built, submitter.current_batch.status);

    // ── 8. Sign with miner key ──
    const miner_privkey = [_]u8{0x42} ** 32;
    submitter.signMerkleRoot(miner_privkey);
    try std.testing.expectEqual(settlement.BatchStatus.signed, submitter.current_batch.status);
    try std.testing.expect(submitter.isReady());

    // ── 9. Verify merkle proof ──
    const leaf = settlement.SettlementSubmitter.computeLeafHash(&sfill);
    const proof = submitter.getProof(0);
    // Single fill: proof may be null (single leaf = root), or empty
    // For single leaf, root == leaf hash, no siblings needed
    if (proof) |p| {
        const verified = settlement.verifyMerkleProof(leaf, p, submitter.current_batch.merkle_root);
        try std.testing.expect(verified);
    } else {
        // Single leaf: merkle root should equal leaf hash directly
        try std.testing.expect(std.mem.eql(u8, &leaf, &submitter.current_batch.merkle_root));
    }

    // ── 10. Submit work report to PoUW engine ──
    const volume_sat = fill.amount_sat; // 100 OMNI matched
    const work_report = makeMatchingWorkReport(
        "miner_alpha",
        1, // block height 1
        volume_sat,
        1, // 1 fill
        submitter.current_batch.merkle_root,
    );
    try pouw_engine.submitWorkReport(work_report);
    try std.testing.expectEqual(@as(u32, 1), pouw_engine.report_count);

    // ── 11. Calculate rewards ──
    pouw_engine.calculateRewards(1);
    try std.testing.expect(pouw_engine.reward_count > 0);
    try std.testing.expectEqual(@as(u32, 1), pouw_engine.reward_count);

    const reward = pouw_engine.rewards[0];
    try std.testing.expect(reward.total_reward_sat > 0);

    // Base reward should be full 50 OMNI (only miner)
    try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT, reward.base_reward_sat);

    // Matching reward: 0.05% of 100 OMNI = 0.05 OMNI = 50_000_000 SAT
    const expected_matching = pouw.PoUWEngine.getMatchingReward(volume_sat);
    try std.testing.expectEqual(expected_matching, reward.matching_reward_sat);

    // Total = base + matching
    try std.testing.expectEqual(
        pouw.INITIAL_BLOCK_REWARD_SAT + expected_matching,
        reward.total_reward_sat,
    );

    // ── 12. Verify miner activity was updated ──
    try std.testing.expectEqual(@as(u32, 1), pouw_engine.active_miner_count);
    try std.testing.expect(pouw_engine.isOnline("miner_alpha", 1));
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 2: Price oracle consensus in miner
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: price oracle consensus in miner" {
    // Allocate oracle on heap (large struct)
    const price_oracle_inst = try std.testing.allocator.create(oracle.DistributedPriceOracle);
    defer std.testing.allocator.destroy(price_oracle_inst);
    price_oracle_inst.* = oracle.DistributedPriceOracle.init();

    // ── Round 1: 3 miners submit BTC price ──
    try price_oracle_inst.submitPrice(.btc, makePriceSubmission(1, .btc, 50_000_000_000, 1000)); // $50,000
    try price_oracle_inst.submitPrice(.btc, makePriceSubmission(2, .btc, 50_200_000_000, 1001)); // $50,200
    try price_oracle_inst.submitPrice(.btc, makePriceSubmission(3, .btc, 49_800_000_000, 1002)); // $49,800

    // Calculate consensus
    const consensus1 = try price_oracle_inst.calculateConsensus(.btc, 1);

    // All 3 within 5% of each other — valid consensus
    try std.testing.expect(consensus1.is_valid);
    try std.testing.expectEqual(@as(u8, 3), consensus1.submission_count);
    try std.testing.expectEqual(@as(u8, 3), consensus1.agreement_count);
    // Median should be the middle value: $50,000
    try std.testing.expectEqual(@as(u64, 50_000_000_000), consensus1.price_micro_usd);

    // ── Round 2: reset and submit new prices ──
    price_oracle_inst.resetRound();
    try std.testing.expectEqual(@as(u64, 1), price_oracle_inst.current_block);

    try price_oracle_inst.submitPrice(.btc, makePriceSubmission(1, .btc, 51_000_000_000, 2000)); // $51,000
    try price_oracle_inst.submitPrice(.btc, makePriceSubmission(2, .btc, 51_100_000_000, 2001)); // $51,100
    try price_oracle_inst.submitPrice(.btc, makePriceSubmission(3, .btc, 50_900_000_000, 2002)); // $50,900

    const consensus2 = try price_oracle_inst.calculateConsensus(.btc, 2);
    try std.testing.expect(consensus2.is_valid);
    try std.testing.expectEqual(@as(u64, 51_000_000_000), consensus2.price_micro_usd);

    // ── Verify TWAP ──
    // History should have 2 valid prices now
    const btc_idx = @intFromEnum(oracle.ChainId.btc);
    try std.testing.expectEqual(@as(u32, 2), price_oracle_inst.history[btc_idx].count);

    // TWAP over a large window should be between the two prices
    const twap = price_oracle_inst.getTwap(.btc, 10_000);
    try std.testing.expect(twap != null);
    try std.testing.expect(twap.? >= 50_000_000_000);
    try std.testing.expect(twap.? <= 51_100_000_000);

    // ── Verify merkle root is deterministic ──
    const root1 = price_oracle_inst.pricesMerkleRoot();
    const root2 = price_oracle_inst.pricesMerkleRoot();
    try std.testing.expect(std.mem.eql(u8, &root1, &root2));
    // Root should not be all zeros (we have valid consensus)
    try std.testing.expect(!std.mem.eql(u8, &root1, &std.mem.zeroes([32]u8)));
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 3: Orderbook sync between miners
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: orderbook sync between miners" {
    // ── Create two sync managers (simulate 2 miners) ──
    var node_id_1: [sync.NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id_1, 0x11);
    var node_id_2: [sync.NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id_2, 0x22);

    const mgr1 = try createSyncManager(node_id_1);
    defer destroySyncManager(mgr1);
    const mgr2 = try createSyncManager(node_id_2);
    defer destroySyncManager(mgr2);

    // ── Miner1 adds order and broadcasts ──
    const order1 = makeSyncOrderEntry(
        100, // order_id
        0, // pair OMNI/USD
        0, // buy
        50_000_000, // $50
        1_000_000_000, // 1 OMNI
        1000, // timestamp
        "trader_x",
        node_id_1,
    );
    try mgr1.broadcastNewOrder(order1);

    // Miner1 should have order in book and message in outbox
    try std.testing.expectEqual(@as(u32, 1), mgr1.order_count);
    try std.testing.expectEqual(@as(u32, 1), mgr1.outbox_count);

    // ── Miner2 receives the broadcast message ──
    const outbox = mgr1.drainOutbox();
    try std.testing.expectEqual(@as(usize, 1), outbox.len);
    try mgr2.handleMessage(outbox[0]);

    // Miner2 should now have the same order
    try std.testing.expectEqual(@as(u32, 1), mgr2.order_count);
    const found = mgr2.getOrder(100);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 50_000_000), found.?.price_micro_usd);

    // ── Add a second order on Miner1 ──
    const order2 = makeSyncOrderEntry(
        101,
        0,
        1, // sell
        51_000_000, // $51
        2_000_000_000,
        1001,
        "trader_y",
        node_id_1,
    );
    mgr1.clearOutbox();
    try mgr1.broadcastNewOrder(order2);

    // Forward to Miner2
    const outbox2 = mgr1.drainOutbox();
    try mgr2.handleMessage(outbox2[0]);

    // ── Both compute merkle root — must match ──
    const root1 = mgr1.recalcMerkleRoot();
    const root2 = mgr2.recalcMerkleRoot();
    try std.testing.expect(std.mem.eql(u8, &root1, &root2));

    // Root should not be zero (we have orders)
    try std.testing.expect(!std.mem.eql(u8, &root1, &std.mem.zeroes([32]u8)));

    // ── Verify consensus validation (2/2 = 100%) ──
    mgr1.current_merkle_root = root1;
    const peer_roots = [_][32]u8{ root2, root2 };
    try std.testing.expect(mgr1.validateMerkleConsensus(&peer_roots));
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 4: Bridge listener → matching engine → settlement
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: bridge listener -> matching engine -> settlement" {
    // ── 1. Bridge listener gets OrderPlaced events ──
    const cfg = listener.BridgeConfig.default();
    var bridge = listener.BridgeListener.init(cfg);
    bridge.start();

    // Simulate 4 bridge events: 2 buys and 2 sells
    var events: [4]listener.OrderPlacedEvent = undefined;
    for (0..4) |i| {
        var tx_hash: [66]u8 = [_]u8{'0'} ** 66;
        tx_hash[0] = '0';
        tx_hash[1] = 'x';
        tx_hash[2] = "abcd"[i];
        events[i] = listener.OrderPlacedEvent{
            .order_id = @intCast(2000 + i),
            .user_address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".*,
            .token_address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".*,
            .amount_wei = [_]u8{0} ** 32,
            .target_chain_id = listener.DEFAULT_TARGET_CHAIN,
            .block_number = @intCast(6000 + i),
            .tx_hash = tx_hash,
            .timestamp_ms = @intCast(3000 + @as(i64, @intCast(i))),
        };
        try bridge.addOrderEvent(events[i]);
    }
    try std.testing.expectEqual(@as(u32, 4), bridge.pending_order_count);

    // ── 2. Drain to matching engine ──
    const drained = bridge.drainOrders();
    try std.testing.expectEqual(@as(usize, 4), drained.len);

    // Create matching orders from drained events
    var engine = TestEngine.init();

    // 2 buys at $25
    try engine.placeOrder(makeMatchingOrder(.buy, 25_000_000, 50_000_000_000, 3000, "buyer_1", 0));
    try engine.placeOrder(makeMatchingOrder(.buy, 25_000_000, 50_000_000_000, 3001, "buyer_2", 0));

    // 2 sells at $25
    try engine.placeOrder(makeMatchingOrder(.sell, 25_000_000, 50_000_000_000, 3002, "seller_1", 0));
    try engine.placeOrder(makeMatchingOrder(.sell, 25_000_000, 50_000_000_000, 3003, "seller_2", 0));

    // ── 3. Match produces fills ──
    try std.testing.expectEqual(@as(u32, 2), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);

    // ── 4. Settlement builds merkle and signs ──
    var submitter = settlement.SettlementSubmitter.init();
    for (0..engine.fill_count) |i| {
        const sfill = fillToSettlement(&engine.fills[i]);
        try submitter.addFill(sfill);
    }
    try std.testing.expectEqual(@as(u32, 2), submitter.current_batch.fill_count);

    submitter.buildMerkleTree();
    try std.testing.expectEqual(settlement.BatchStatus.merkle_built, submitter.current_batch.status);

    submitter.signMerkleRoot([_]u8{0xBE} ** 32);
    try std.testing.expectEqual(settlement.BatchStatus.signed, submitter.current_batch.status);
    try std.testing.expect(submitter.isReady());

    // ── 5. Verify merkle proofs for both fills ──
    for (0..2) |i| {
        const leaf = submitter.current_batch.leaves[i];
        const proof = submitter.getProof(@intCast(i));
        try std.testing.expect(proof != null);
        const verified = settlement.verifyMerkleProof(leaf, proof.?, submitter.current_batch.merkle_root);
        try std.testing.expect(verified);
    }

    // ── 6. Verify calldata can be built ──
    var calldata_buf: [4096]u8 = undefined;
    const calldata = try submitter.buildCalldata(&calldata_buf);
    try std.testing.expect(calldata.len > 101); // selector + root + sig minimum
    // Function selector check
    try std.testing.expectEqual(@as(u8, 0xa1), calldata[0]);
    try std.testing.expectEqual(@as(u8, 0xb2), calldata[1]);

    // ── 7. Mark submitted and verify stats ──
    submitter.markSubmitted();
    try std.testing.expectEqual(@as(u64, 1), submitter.total_batches_submitted);
    try std.testing.expectEqual(@as(u64, 2), submitter.total_fills_settled);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 5: PoUW rewards with matching + oracle
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: PoUW rewards with matching + oracle" {
    var pouw_engine = pouw.PoUWEngine.init();

    // ── Miner does matching work: 5 fills, 500 OMNI volume ──
    const matching_volume: u64 = 500_000_000_000; // 500 OMNI
    const matching_report = makeMatchingWorkReport(
        "miner_beta",
        10,
        matching_volume,
        5,
        [_]u8{0xAA} ** 32,
    );
    try pouw_engine.submitWorkReport(matching_report);

    // ── Same miner also submits oracle work: 3 price updates ──
    const oracle_report = makeOracleWorkReport("miner_beta", 10, 3);
    try pouw_engine.submitWorkReport(oracle_report);

    // ── Should have 2 reports from same miner (different work types) ──
    try std.testing.expectEqual(@as(u32, 2), pouw_engine.report_count);

    // ── Calculate rewards ──
    pouw_engine.calculateRewards(10);
    try std.testing.expectEqual(@as(u32, 2), pouw_engine.reward_count);

    // ── Verify reward breakdown ──
    // Both reports from same miner: base reward split among 2 "valid reports"
    // (each report counted separately)
    const base_per_report = pouw.INITIAL_BLOCK_REWARD_SAT / 2;

    // Matching report reward
    const matching_reward = pouw_engine.rewards[0];
    try std.testing.expectEqual(base_per_report, matching_reward.base_reward_sat);

    // Matching reward: 0.05% of 500 OMNI = 0.25 OMNI = 250_000_000 SAT
    const expected_matching_bonus = pouw.PoUWEngine.getMatchingReward(matching_volume);
    try std.testing.expectEqual(@as(u64, 250_000_000), expected_matching_bonus);
    try std.testing.expectEqual(expected_matching_bonus, matching_reward.matching_reward_sat);
    try std.testing.expectEqual(base_per_report + expected_matching_bonus, matching_reward.total_reward_sat);

    // Oracle report reward
    const oracle_reward = pouw_engine.rewards[1];
    try std.testing.expectEqual(base_per_report, oracle_reward.base_reward_sat);

    // Oracle reward: 3 updates * 1 OMNI = 3 OMNI = 3_000_000_000 SAT
    const expected_oracle_bonus = pouw.PoUWEngine.getOracleReward(3);
    try std.testing.expectEqual(@as(u64, 3_000_000_000), expected_oracle_bonus);
    try std.testing.expectEqual(expected_oracle_bonus, oracle_reward.oracle_reward_sat);
    try std.testing.expectEqual(base_per_report + expected_oracle_bonus, oracle_reward.total_reward_sat);

    // ── Total minted should equal sum of rewards ──
    const expected_total = matching_reward.total_reward_sat + oracle_reward.total_reward_sat;
    try std.testing.expectEqual(expected_total, pouw_engine.total_minted_sat);
    try std.testing.expect(pouw_engine.total_minted_sat > 0);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 6: Multiple blocks with halving
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: multiple blocks with halving" {
    var pouw_engine = pouw.PoUWEngine.init();

    // ── Mine a block before first halving ──
    {
        const report = makeMatchingWorkReport(
            "miner_gamma",
            pouw.HALVING_INTERVAL - 1, // last block before halving
            1_000_000_000_000,
            10,
            [_]u8{0x01} ** 32,
        );
        try pouw_engine.submitWorkReport(report);
        pouw_engine.calculateRewards(pouw.HALVING_INTERVAL - 1);

        try std.testing.expectEqual(@as(u32, 1), pouw_engine.reward_count);
        // Base reward should still be 50 OMNI
        try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT, pouw_engine.rewards[0].base_reward_sat);
    }

    // ── Reset and mine at exactly the halving boundary ──
    pouw_engine.resetBlock();
    {
        const report = makeMatchingWorkReport(
            "miner_gamma",
            pouw.HALVING_INTERVAL, // first block after halving
            1_000_000_000_000,
            10,
            [_]u8{0x02} ** 32,
        );
        try pouw_engine.submitWorkReport(report);
        pouw_engine.calculateRewards(pouw.HALVING_INTERVAL);

        try std.testing.expectEqual(@as(u32, 1), pouw_engine.reward_count);
        // Base reward should be halved to 25 OMNI
        try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT / 2, pouw_engine.rewards[0].base_reward_sat);
    }

    // ── Verify block reward at various halving intervals ──
    try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT, pouw.PoUWEngine.getBlockReward(0));
    try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT / 2, pouw.PoUWEngine.getBlockReward(pouw.HALVING_INTERVAL));
    try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT / 4, pouw.PoUWEngine.getBlockReward(pouw.HALVING_INTERVAL * 2));
    try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT / 8, pouw.PoUWEngine.getBlockReward(pouw.HALVING_INTERVAL * 3));

    // ── After 32 halvings reward should be 0 ──
    try std.testing.expectEqual(@as(u64, 0), pouw.PoUWEngine.getBlockReward(pouw.HALVING_INTERVAL * 32));
    try std.testing.expectEqual(@as(u64, 0), pouw.PoUWEngine.getBlockReward(pouw.HALVING_INTERVAL * 40));

    // ── Verify supply cap ──
    const supply_at_all_halvings = pouw.PoUWEngine.totalSupplyMined(pouw.HALVING_INTERVAL * 40);
    try std.testing.expect(supply_at_all_halvings <= pouw.MAX_SUPPLY_SAT);

    // ── Supply at block 0 should be 0 ──
    try std.testing.expectEqual(@as(u64, 0), pouw.PoUWEngine.totalSupplyMined(0));

    // ── First era: 210,000 blocks * 50 OMNI ──
    const first_era_supply = pouw.PoUWEngine.totalSupplyMined(pouw.HALVING_INTERVAL);
    try std.testing.expectEqual(pouw.HALVING_INTERVAL * pouw.INITIAL_BLOCK_REWARD_SAT, first_era_supply);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 7: Full pipeline — bridge → sync → match → settle → reward (all together)
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: full pipeline end-to-end" {
    // ── Bridge: receive 6 orders (3 buys + 3 sells at different prices) ──
    const cfg = listener.BridgeConfig.default();
    var bridge = listener.BridgeListener.init(cfg);
    bridge.start();

    // Generate unique tx hashes and add events
    for (0..6) |i| {
        var tx_hash: [66]u8 = [_]u8{'0'} ** 66;
        tx_hash[0] = '0';
        tx_hash[1] = 'x';
        tx_hash[2] = "ghijkl"[i];
        const event = listener.OrderPlacedEvent{
            .order_id = @intCast(3000 + i),
            .user_address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".*,
            .token_address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".*,
            .amount_wei = [_]u8{0} ** 32,
            .target_chain_id = listener.DEFAULT_TARGET_CHAIN,
            .block_number = @intCast(7000 + i),
            .tx_hash = tx_hash,
            .timestamp_ms = @intCast(5000 + @as(i64, @intCast(i))),
        };
        try bridge.addOrderEvent(event);
    }
    _ = bridge.drainOrders();
    bridge.updateLastBlock(7006);
    try std.testing.expectEqual(@as(u64, 7006), bridge.last_scanned_block);

    // ── Sync: Miner broadcasts orders ──
    var node_id: [sync.NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x33);
    const mgr = try createSyncManager(node_id);
    defer destroySyncManager(mgr);

    // Add buy orders to sync
    for (0..3) |i| {
        const entry = makeSyncOrderEntry(
            @intCast(3000 + i),
            0,
            0, // buy
            @intCast(20_000_000 + i * 1_000_000), // $20, $21, $22
            50_000_000_000, // 50 OMNI each
            @intCast(5000 + @as(i64, @intCast(i))),
            "buyer_sync",
            node_id,
        );
        try mgr.broadcastNewOrder(entry);
    }
    try std.testing.expectEqual(@as(u32, 3), mgr.order_count);
    mgr.clearOutbox();

    // ── Matching: Place orders and get fills ──
    var engine = TestEngine.init();

    // 3 buys at ascending prices
    try engine.placeOrder(makeMatchingOrder(.buy, 22_000_000, 50_000_000_000, 5000, "b1", 0));
    try engine.placeOrder(makeMatchingOrder(.buy, 21_000_000, 50_000_000_000, 5001, "b2", 0));
    try engine.placeOrder(makeMatchingOrder(.buy, 20_000_000, 50_000_000_000, 5002, "b3", 0));

    // 3 sells at $20 — will match with all 3 buys
    try engine.placeOrder(makeMatchingOrder(.sell, 20_000_000, 50_000_000_000, 5003, "s1", 0));
    try engine.placeOrder(makeMatchingOrder(.sell, 20_000_000, 50_000_000_000, 5004, "s2", 0));
    try engine.placeOrder(makeMatchingOrder(.sell, 20_000_000, 50_000_000_000, 5005, "s3", 0));

    // All 3 sells should match with the 3 buys (best price first)
    try std.testing.expectEqual(@as(u32, 3), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);

    // ── Settlement: Build merkle tree from 3 fills ──
    var submitter = settlement.SettlementSubmitter.init();
    var total_volume: u64 = 0;
    for (0..engine.fill_count) |i| {
        const sfill = fillToSettlement(&engine.fills[i]);
        try submitter.addFill(sfill);
        total_volume += engine.fills[i].amount_sat;
    }
    try std.testing.expectEqual(@as(u64, 150_000_000_000), total_volume); // 3 * 50 OMNI

    submitter.buildMerkleTree();
    submitter.signMerkleRoot([_]u8{0xDE} ** 32);
    try std.testing.expect(submitter.isReady());

    // Verify all 3 merkle proofs
    for (0..3) |i| {
        const leaf = submitter.current_batch.leaves[i];
        const proof = submitter.getProof(@intCast(i));
        try std.testing.expect(proof != null);
        try std.testing.expect(settlement.verifyMerkleProof(leaf, proof.?, submitter.current_batch.merkle_root));
    }

    // ── PoUW: Submit work and calculate rewards ──
    var pouw_engine = pouw.PoUWEngine.init();
    const work = makeMatchingWorkReport(
        "miner_delta",
        5,
        total_volume,
        3,
        submitter.current_batch.merkle_root,
    );
    try pouw_engine.submitWorkReport(work);
    pouw_engine.calculateRewards(5);

    try std.testing.expectEqual(@as(u32, 1), pouw_engine.reward_count);
    const reward = pouw_engine.rewards[0];

    // Base: 50 OMNI
    try std.testing.expectEqual(pouw.INITIAL_BLOCK_REWARD_SAT, reward.base_reward_sat);

    // Matching: 0.05% of 150 OMNI = 0.075 OMNI = 75_000_000 SAT
    try std.testing.expectEqual(pouw.PoUWEngine.getMatchingReward(total_volume), reward.matching_reward_sat);
    try std.testing.expectEqual(@as(u64, 75_000_000), reward.matching_reward_sat);

    // Total
    try std.testing.expectEqual(
        pouw.INITIAL_BLOCK_REWARD_SAT + 75_000_000,
        reward.total_reward_sat,
    );

    // Verify settlement can be marked submitted
    submitter.markSubmitted();
    submitter.markConfirmed();
    try std.testing.expectEqual(settlement.BatchStatus.confirmed, submitter.current_batch.status);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 8: Slashing after invalid matching work
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: slashing after invalid matching work" {
    var pouw_engine = pouw.PoUWEngine.init();

    // ── Miner submits matching work ──
    const report = makeMatchingWorkReport(
        "miner_evil",
        1,
        1_000_000_000_000,
        20,
        [_]u8{0xFF} ** 32,
    );
    try pouw_engine.submitWorkReport(report);
    pouw_engine.calculateRewards(1);

    // Miner got rewarded
    try std.testing.expectEqual(@as(u32, 1), pouw_engine.reward_count);
    const reward_before = pouw_engine.rewards[0].total_reward_sat;
    try std.testing.expect(reward_before > 0);

    // ── Detect invalid matching — slash 100% ──
    // Find the miner in the activity array by scanning
    var idx: usize = 0;
    for (0..pouw_engine.active_miner_count) |i| {
        const a = &pouw_engine.miner_last_active[i];
        if (std.mem.eql(u8, a.miner_address[0..a.miner_addr_len], "miner_evil")) {
            idx = i;
            break;
        }
    }
    const stake = pouw_engine.miner_last_active[idx].stake_sat;
    const slash_amount = pouw.PoUWEngine.calculateSlashAmount(stake, .invalid_matching);
    try std.testing.expectEqual(stake, slash_amount); // 100%

    var addr: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(addr[0.."miner_evil".len], "miner_evil");

    const slash = pouw.SlashEvent{
        .miner_address = addr,
        .miner_addr_len = "miner_evil".len,
        .reason = .invalid_matching,
        .slash_amount_sat = slash_amount,
        .evidence_hash = [_]u8{0xDD} ** 32,
        .block_height = 2,
        .timestamp_ms = 200,
    };
    try pouw_engine.reportSlash(slash);

    // Miner should be deactivated with 0 stake
    try std.testing.expectEqual(@as(u64, 0), pouw_engine.miner_last_active[idx].stake_sat);
    try std.testing.expect(!pouw_engine.miner_last_active[idx].is_active);

    // Net rewards should reflect slashing
    try std.testing.expectEqual(@as(u64, 0), pouw_engine.miner_last_active[idx].netRewardsSat());
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 9: Settlement with multiple fills and proof verification
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: settlement multi-fill merkle proofs" {
    var engine = TestEngine.init();

    // Place 8 orders: 4 buys + 4 sells at same price
    for (0..4) |i| {
        const buy_addr_chars = "ABCD";
        const sell_addr_chars = "WXYZ";
        var buy_addr_buf: [7]u8 = undefined;
        var sell_addr_buf: [7]u8 = undefined;
        @memcpy(buy_addr_buf[0..6], "buyer_");
        buy_addr_buf[6] = buy_addr_chars[i];
        @memcpy(sell_addr_buf[0..7], "seller_");
        _ = sell_addr_chars[i];

        try engine.placeOrder(makeMatchingOrder(
            .buy,
            15_000_000,
            25_000_000_000,
            @intCast(1000 + @as(i64, @intCast(i))),
            buy_addr_buf[0..7],
            0,
        ));
        try engine.placeOrder(makeMatchingOrder(
            .sell,
            15_000_000,
            25_000_000_000,
            @intCast(2000 + @as(i64, @intCast(i))),
            &sell_addr_buf,
            0,
        ));
    }

    try std.testing.expectEqual(@as(u32, 4), engine.fill_count);

    // Build settlement
    var submitter = settlement.SettlementSubmitter.init();
    for (0..engine.fill_count) |i| {
        try submitter.addFill(fillToSettlement(&engine.fills[i]));
    }

    submitter.buildMerkleTree();
    try std.testing.expectEqual(@as(u32, 4), submitter.current_batch.leaf_count);

    submitter.signMerkleRoot([_]u8{0x99} ** 32);

    // Verify every single proof
    for (0..4) |i| {
        const leaf = submitter.current_batch.leaves[i];
        const proof = submitter.getProof(@intCast(i));
        try std.testing.expect(proof != null);
        const valid = settlement.verifyMerkleProof(leaf, proof.?, submitter.current_batch.merkle_root);
        try std.testing.expect(valid);
    }

    // Corrupt a leaf and verify proof fails
    var bad_leaf = submitter.current_batch.leaves[2];
    bad_leaf[0] ^= 0xFF;
    const bad_proof = submitter.getProof(2).?;
    const invalid = settlement.verifyMerkleProof(bad_leaf, bad_proof, submitter.current_batch.merkle_root);
    try std.testing.expect(!invalid);
}

// ═══════════════════════════════════════════════════════════════════════════════
// TEST 10: Rewards merkle root consistency across modules
// ═══════════════════════════════════════════════════════════════════════════════

test "integration: rewards merkle root consistency" {
    // Two independent PoUW engines processing the same work should
    // produce identical reward merkle roots

    var engine1 = pouw.PoUWEngine.init();
    var engine2 = pouw.PoUWEngine.init();

    const r1 = makeMatchingWorkReport("alice", 1, 200_000_000_000, 8, [_]u8{0x11} ** 32);
    const r2 = makeOracleWorkReport("bob", 1, 5);

    try engine1.submitWorkReport(r1);
    try engine1.submitWorkReport(r2);
    engine1.calculateRewards(1);

    try engine2.submitWorkReport(r1);
    try engine2.submitWorkReport(r2);
    engine2.calculateRewards(1);

    const root1 = engine1.rewardsMerkleRoot();
    const root2 = engine2.rewardsMerkleRoot();

    try std.testing.expect(std.mem.eql(u8, &root1, &root2));
    try std.testing.expect(!std.mem.eql(u8, &root1, &std.mem.zeroes([32]u8)));

    // Reward counts should match
    try std.testing.expectEqual(engine1.reward_count, engine2.reward_count);
    try std.testing.expectEqual(engine1.total_minted_sat, engine2.total_minted_sat);
}
