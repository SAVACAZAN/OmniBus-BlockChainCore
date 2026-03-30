/// sharding_test.zig - Teste pentru sharding și sub-block-uri
const std = @import("std");
const testing = std.testing;

const sub_block_mod = @import("../core/sub_block.zig");
const shard_config_mod = @import("../core/shard_config.zig");
const shard_coord_mod = @import("../core/shard_coordinator.zig");
const transaction_mod = @import("../core/transaction.zig");

const SubBlock = sub_block_mod.SubBlock;
const KeyBlock = sub_block_mod.KeyBlock;
const ShardConfig = shard_config_mod.ShardConfig;
const Transaction = transaction_mod.Transaction;

// =============================================================================
// SUB-BLOCK TESTS
// =============================================================================

test "SubBlock: initialization" {
    var sb = SubBlock.init(
        testing.allocator,
        0, // sub_id
        100, // block_number
        2, // shard_id
        "miner_123"
    );
    defer sb.deinit();
    
    try testing.expectEqual(sb.sub_id, 0);
    try testing.expectEqual(sb.block_number, 100);
    try testing.expectEqual(sb.shard_id, 2);
    try testing.expectEqual(sb.tx_count, 0);
    try testing.expect(sb.transactions.items.len == 0);
    
    std.debug.print("[SubBlock] Init OK (id={d}, block={d}, shard={d})\n", .{
        sb.sub_id, sb.block_number, sb.shard_id,
    });
}

test "SubBlock: add transactions" {
    var sb = SubBlock.init(testing.allocator, 1, 200, 0, "miner");
    defer sb.deinit();
    
    const tx = Transaction{
        .from = "sender",
        .to = "receiver",
        .amount = 100,
        .fee = 1,
        .timestamp = 1234567890,
        .hash = "tx_hash_123",
    };
    
    try sb.addTransaction(tx);
    try testing.expectEqual(sb.tx_count, 1);
    try testing.expectEqual(sb.transactions.items.len, 1);
    
    try sb.addTransaction(tx);
    try testing.expectEqual(sb.tx_count, 2);
    
    std.debug.print("[SubBlock] Add TX OK (count={d})\n", .{sb.tx_count});
}

test "SubBlock: finalize and hash" {
    var sb = SubBlock.init(testing.allocator, 2, 300, 1, "miner_test");
    defer sb.deinit();
    
    // Adaugă TX-uri
    const tx = Transaction{
        .from = "alice",
        .to = "bob",
        .amount = 500,
        .fee = 5,
        .timestamp = 1234567890,
        .hash = "hash123",
    };
    
    try sb.addTransaction(tx);
    try sb.addTransaction(tx);
    
    // Finalizează
    sb.finalize();
    
    // Verifică că hash-ul și merkle_root sunt calculate
    var all_zero_hash = true;
    for (sb.hash) |b| {
        if (b != 0) {
            all_zero_hash = false;
            break;
        }
    }
    try testing.expect(!all_zero_hash);
    
    std.debug.print("[SubBlock] Finalize OK (merkle_root={any}..)\n", .{sb.merkle_root[0..4]});
}

test "SubBlock: validation" {
    var sb = SubBlock.init(testing.allocator, 3, 400, 0, "miner");
    defer sb.deinit();
    
    // SubBlock valid (sub_id < SUB_BLOCKS_PER_BLOCK)
    try testing.expect(sb.isValid());
    
    // SubBlock invalid (sub_id prea mare)
    var sb_invalid = SubBlock.init(testing.allocator, 99, 400, 0, "miner");
    defer sb_invalid.deinit();
    try testing.expect(!sb_invalid.isValid());
    
    std.debug.print("[SubBlock] Validation OK\n", .{});
}

test "SubBlock: boundary conditions" {
    // SubBlock cu sub_id maxim valid
    var sb_max = SubBlock.init(
        testing.allocator,
        sub_block_mod.SUB_BLOCKS_PER_BLOCK - 1,
        1,
        0,
        "miner"
    );
    defer sb_max.deinit();
    try testing.expect(sb_max.isValid());
    
    // SubBlock cu sub_id la limită
    var sb_boundary = SubBlock.init(
        testing.allocator,
        sub_block_mod.SUB_BLOCKS_PER_BLOCK,
        1,
        0,
        "miner"
    );
    defer sb_boundary.deinit();
    try testing.expect(!sb_boundary.isValid());
    
    std.debug.print("[SubBlock] Boundary OK (max_sub_id={d})\n", .{sub_block_mod.SUB_BLOCKS_PER_BLOCK - 1});
}

// =============================================================================
// KEYBLOCK TESTS
// =============================================================================

test "KeyBlock: initialization" {
    var kb = KeyBlock.init(testing.allocator, 1000, "validator_001");
    defer kb.deinit();
    
    try testing.expectEqual(kb.block_number, 1000);
    try testing.expectEqual(kb.sub_blocks.items.len, 0);
    try testing.expectEqual(kb.state, .Building);
    
    std.debug.print("[KeyBlock] Init OK (number={d})\n", .{kb.block_number});
}

test "KeyBlock: add sub-blocks" {
    var kb = KeyBlock.init(testing.allocator, 2000, "validator");
    defer kb.deinit();
    
    // Creează și adaugă sub-blocks
    for (0..3) |i| {
        var sb = SubBlock.init(
            testing.allocator,
            @as(u8, @intCast(i)),
            2000,
            @as(u8, @intCast(i % 7)),
            "miner"
        );
        
        // Adaugă TX
        const tx = Transaction{
            .from = "sender",
            .to = "receiver",
            .amount = 100,
            .fee = 1,
            .timestamp = 0,
            .hash = "txhash",
        };
        try sb.addTransaction(tx);
        sb.finalize();
        
        try kb.addSubBlock(sb);
    }
    
    try testing.expectEqual(kb.sub_blocks.items.len, 3);
    
    std.debug.print("[KeyBlock] Add sub-blocks OK (count={d})\n", .{kb.sub_blocks.items.len});
}

test "KeyBlock: finalize" {
    var kb = KeyBlock.init(testing.allocator, 3000, "validator");
    defer kb.deinit();
    
    // Adaugă sub-blocks complete (10)
    for (0..sub_block_mod.SUB_BLOCKS_PER_BLOCK) |i| {
        var sb = SubBlock.init(
            testing.allocator,
            @as(u8, @intCast(i)),
            3000,
            0,
            "miner"
        );
        sb.finalize();
        try kb.addSubBlock(sb);
    }
    
    // Finalizează KeyBlock
    kb.finalize();
    
    try testing.expectEqual(kb.state, .Complete);
    
    // Verifică aggregated_hash
    var all_zero = true;
    for (kb.aggregated_hash) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
    
    std.debug.print("[KeyBlock] Finalize OK (state=Complete)\n", .{});
}

// =============================================================================
// SHARD CONFIG TESTS
// =============================================================================

test "ShardConfig: default configuration" {
    const config = ShardConfig.default();
    
    try testing.expect(config.shard_count > 0);
    try testing.expect(config.shard_count <= 128); // limit rezonabil
    try testing.expect(config.block_time_ms > 0);
    try testing.expect(config.sub_block_interval_ms > 0);
    
    std.debug.print("[ShardConfig] Default OK (shards={d}, block_time={d}ms)\n", .{
        config.shard_count, config.block_time_ms,
    });
}

test "ShardConfig: parameter validation" {
    // Config validă
    const valid_config = ShardConfig{
        .shard_count = 7,
        .block_time_ms = 1000,
        .sub_block_interval_ms = 100,
    };
    try testing.expect(valid_config.isValid());
    
    // Prea multe shards
    const invalid_shards = ShardConfig{
        .shard_count = 1000,
        .block_time_ms = 1000,
        .sub_block_interval_ms = 100,
    };
    try testing.expect(!invalid_shards.isValid());
    
    // Block time prea mic
    const invalid_time = ShardConfig{
        .shard_count = 7,
        .block_time_ms = 10,
        .sub_block_interval_ms = 100,
    };
    try testing.expect(!invalid_time.isValid());
    
    std.debug.print("[ShardConfig] Validation OK\n", .{});
}

test "ShardConfig: production preset" {
    const prod = ShardConfig.production();
    
    try testing.expect(prod.shard_count >= 7);
    try testing.expect(prod.block_time_ms >= 1000);
    try testing.expect(prod.isValid());
    
    std.debug.print("[ShardConfig] Production OK (shards={d})\n", .{prod.shard_count});
}

test "ShardConfig: test preset" {
    const test_cfg = ShardConfig.testConfig();
    
    try testing.expect(test_cfg.shard_count >= 1);
    try testing.expect(test_cfg.shard_count <= prod.shard_count);
    try testing.expect(test_cfg.isValid());
    
    std.debug.print("[ShardConfig] Test OK (shards={d})\n", .{test_cfg.shard_count});
}

// =============================================================================
// SHARD ASSIGNMENT TESTS
// =============================================================================

test "ShardConfig: validator assignment" {
    const config = ShardConfig.default();
    
    // Simulează assignment pentru câțiva validatori
    const validators = [_][]const u8{
        "val_001", "val_002", "val_003", "val_004",
        "val_005", "val_006", "val_007", "val_008",
    };
    
    for (validators) |val| {
        const shard = config.getShardForValidator(val);
        try testing.expect(shard < config.shard_count);
    }
    
    std.debug.print("[ShardConfig] Validator assignment OK\n", .{});
}

test "ShardConfig: account assignment" {
    const config = ShardConfig.default();
    
    const accounts = [_][]const u8{
        "ob_omni_alice", "ob_omni_bob", "ob_omni_charlie",
        "ob_k1_dave", "ob_d5_eve", "ob_f5_frank",
    };
    
    for (accounts) |acc| {
        const shard = config.getShardForAccount(acc);
        try testing.expect(shard < config.shard_count);
    }
    
    std.debug.print("[ShardConfig] Account assignment OK\n", .{});
}

test "ShardConfig: deterministic assignment" {
    const config = ShardConfig.default();
    
    // Același validator => același shard (determinist)
    const validator = "val_deterministic_test";
    const shard1 = config.getShardForValidator(validator);
    const shard2 = config.getShardForValidator(validator);
    
    try testing.expectEqual(shard1, shard2);
    
    std.debug.print("[ShardConfig] Deterministic OK (shard={d})\n", .{shard1});
}

// =============================================================================
// SHARD COORDINATOR TESTS
// =============================================================================

test "ShardCoordinator: initialization" {
    var coord = try shard_coord_mod.ShardCoordinator.init(
        testing.allocator,
        ShardConfig.default()
    );
    defer coord.deinit();
    
    try testing.expectEqual(coord.config.shard_count, ShardConfig.default().shard_count);
    
    std.debug.print("[ShardCoordinator] Init OK\n", .{});
}

test "ShardCoordinator: cross-shard transaction routing" {
    var coord = try shard_coord_mod.ShardCoordinator.init(
        testing.allocator,
        ShardConfig.default()
    );
    defer coord.deinit();
    
    // Creează TX cross-shard
    const tx = Transaction{
        .from = "ob_omni_sender_shard0",
        .to = "ob_omni_receiver_shard1",
        .amount = 1000,
        .fee = 10,
        .timestamp = 1234567890,
        .hash = "cross_shard_tx",
    };
    
    const route = coord.routeTransaction(tx);
    
    // Ar trebui să fie cross-shard
    try testing.expect(route.is_cross_shard);
    try testing.expect(route.source_shard != route.target_shard);
    
    std.debug.print("[ShardCoordinator] Cross-shard routing OK (src={d}, dst={d})\n", .{
        route.source_shard, route.target_shard,
    });
}

test "ShardCoordinator: same-shard transaction" {
    var coord = try shard_coord_mod.ShardCoordinator.init(
        testing.allocator,
        ShardConfig.default()
    );
    defer coord.deinit();
    
    // Același prefix ar trebui să fie același shard
    const tx = Transaction{
        .from = "ob_omni_alice",
        .to = "ob_omni_bob",
        .amount = 500,
        .fee = 5,
        .timestamp = 0,
        .hash = "same_shard_tx",
    };
    
    const route = coord.routeTransaction(tx);
    
    // Același shard
    try testing.expectEqual(route.source_shard, route.target_shard);
    try testing.expect(!route.is_cross_shard);
    
    std.debug.print("[ShardCoordinator] Same-shard routing OK (shard={d})\n", .{route.source_shard});
}

// =============================================================================
// MERKLE ROOT TESTS
// =============================================================================

test "SubBlock: merkle root calculation" {
    var sb = SubBlock.init(testing.allocator, 0, 1, 0, "miner");
    defer sb.deinit();
    
    // SubBlock fără TX => merkle_root = hash empty
    const empty_root = sb.calcMerkleRoot();
    
    // Adaugă TX-uri
    const tx1 = Transaction{
        .from = "a", .to = "b", .amount = 1, .fee = 1,
        .timestamp = 0, .hash = "hash1",
    };
    const tx2 = Transaction{
        .from = "c", .to = "d", .amount = 2, .fee = 1,
        .timestamp = 0, .hash = "hash2",
    };
    
    try sb.addTransaction(tx1);
    try sb.addTransaction(tx2);
    
    const with_tx_root = sb.calcMerkleRoot();
    
    // Root-urile ar trebui să fie diferite
    var same = true;
    for (0..32) |i| {
        if (empty_root[i] != with_tx_root[i]) {
            same = false;
            break;
        }
    }
    try testing.expect(!same);
    
    std.debug.print("[SubBlock] Merkle root OK\n", .{});
}

// =============================================================================
// EDGE CASES
// =============================================================================

test "Edge: empty KeyBlock finalize" {
    var kb = KeyBlock.init(testing.allocator, 1, "validator");
    defer kb.deinit();
    
    // Finalize fără sub-blocks
    kb.finalize();
    
    // Ar trebui să fie încă valid
    try testing.expectEqual(kb.state, .Complete);
    
    std.debug.print("[Edge] Empty KeyBlock finalize OK\n", .{});
}

test "Edge: SubBlock with many transactions" {
    var sb = SubBlock.init(testing.allocator, 0, 1, 0, "miner");
    defer sb.deinit();
    
    const tx = Transaction{
        .from = "s", .to = "r", .amount = 1, .fee = 1,
        .timestamp = 0, .hash = "h",
    };
    
    // Adaugă multe TX-uri
    for (0..100) |_| {
        try sb.addTransaction(tx);
    }
    
    try testing.expectEqual(sb.tx_count, 100);
    
    sb.finalize();
    
    std.debug.print("[Edge] Many TX OK (count={d})\n", .{sb.tx_count});
}

pub fn main() void {
    std.debug.print("\n=== Sharding & Sub-Block Tests ===\n\n", .{});
}
