/// storage_test.zig - Teste pentru storage, database și archive
const std = @import("std");
const testing = std.testing;

const storage_mod = @import("../core/storage.zig");
const database_mod = @import("../core/database.zig");
const archive_mod = @import("../core/archive_manager.zig");
const state_trie_mod = @import("../core/state_trie.zig");
const binary_codec_mod = @import("../core/binary_codec.zig");
const prune_mod = @import("../core/prune_config.zig");

// =============================================================================
// STORAGE TESTS
// =============================================================================

test "Storage: initialization" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    try testing.expect(storage.allocator == testing.allocator);
    try testing.expect(storage.path.len > 0);
    
    std.debug.print("[Storage] Init OK (path={s})\n", .{storage.path});
}

test "Storage: put and get" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    const key = "test_key";
    const value = "test_value_12345";
    
    try storage.put(key, value);
    
    const retrieved = try storage.get(key);
    defer testing.allocator.free(retrieved);
    
    try testing.expectEqualStrings(value, retrieved);
    
    std.debug.print("[Storage] Put/Get OK\n", .{});
}

test "Storage: exists and delete" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    const key = "exists_key";
    const value = "exists_value";
    
    try testing.expect(!storage.exists(key));
    
    try storage.put(key, value);
    try testing.expect(storage.exists(key));
    
    try storage.delete(key);
    try testing.expect(!storage.exists(key));
    
    std.debug.print("[Storage] Exists/Delete OK\n", .{});
}

test "Storage: binary data" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    // Date binare cu zero bytes
    var value: [256]u8 = undefined;
    for (0..256) |i| {
        value[i] = @as(u8, @truncate(i));
    }
    
    try storage.putBytes("binary_key", &value);
    
    const retrieved = try storage.getBytes("binary_key");
    defer testing.allocator.free(retrieved);
    
    try testing.expectEqualSlices(u8, &value, retrieved);
    
    std.debug.print("[Storage] Binary data OK ({d} bytes)\n", .{retrieved.len});
}

test "Storage: batch operations" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    var batch = storage_mod.Batch.init(testing.allocator);
    defer batch.deinit();
    
    // Adaugă operații în batch
    for (0..10) |i| {
        var key_buf: [32]u8 = undefined;
        var val_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        const val = try std.fmt.bufPrint(&val_buf, "value{d}", .{i});
        try batch.put(key, val);
    }
    
    // Execută batch
    try storage.applyBatch(&batch);
    
    // Verifică
    for (0..10) |i| {
        var key_buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        try testing.expect(storage.exists(key));
    }
    
    std.debug.print("[Storage] Batch operations OK ({d} items)\n", .{batch.count()});
}

// =============================================================================
// BINARY CODEC TESTS
// =============================================================================

test "BinaryCodec: u64 encoding/decoding" {
    const values = [_]u64{ 0, 1, 255, 256, 65535, 65536, std.math.maxInt(u64) };
    
    for (values) |original| {
        var buf: [16]u8 = undefined;
        const encoded = binary_codec_mod.encodeU64(original, &buf);
        
        var decoded: u64 = undefined;
        const consumed = binary_codec_mod.decodeU64(encoded, &decoded);
        
        try testing.expectEqual(original, decoded);
        try testing.expect(consumed > 0);
    }
    
    std.debug.print("[BinaryCodec] u64 OK ({d} values)\n", .{values.len});
}

test "BinaryCodec: variable length encoding" {
    // Valori mici ar trebui să folosească mai puțini bytes
    var buf1: [16]u8 = undefined;
    var buf2: [16]u8 = undefined;
    
    const small = binary_codec_mod.encodeU64(100, &buf1);
    const large = binary_codec_mod.encodeU64(std.math.maxInt(u64), &buf2);
    
    try testing.expect(small.len <= large.len);
    
    std.debug.print("[BinaryCodec] Varint OK (small={d}B, large={d}B)\n", .{ small.len, large.len });
}

test "BinaryCodec: byte slice encoding" {
    const original = "Hello, Binary World!";
    
    var buf: [256]u8 = undefined;
    const encoded = binary_codec_mod.encodeBytes(original, &buf);
    
    var decoded: []u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    const consumed = try binary_codec_mod.decodeBytes(encoded, &decoded, arena.allocator());
    defer arena.allocator().free(decoded);
    
    try testing.expectEqualStrings(original, decoded);
    try testing.expect(consumed > 0);
    
    std.debug.print("[BinaryCodec] Bytes OK ({d} bytes)\n", .{decoded.len});
}

// =============================================================================
// STATE TRIE TESTS
// =============================================================================

test "StateTrie: initialization" {
    var trie = state_trie_mod.StateTrie.init(testing.allocator);
    defer trie.deinit();
    
    try testing.expect(trie.root != null);
    
    std.debug.print("[StateTrie] Init OK\n", .{});
}

test "StateTrie: put and get" {
    var trie = state_trie_mod.StateTrie.init(testing.allocator);
    defer trie.deinit();
    
    const key = "address_001";
    const value = "balance:1000,nonce:5";
    
    try trie.put(key, value);
    
    const retrieved = try trie.get(key);
    try testing.expectEqualStrings(value, retrieved);
    
    std.debug.print("[StateTrie] Put/Get OK\n", .{});
}

test "StateTrie: multiple keys" {
    var trie = state_trie_mod.StateTrie.init(testing.allocator);
    defer trie.deinit();
    
    const keys = [_][]const u8{ "alice", "bob", "charlie", "dave" };
    const values = [_][]const u8{ "100", "200", "300", "400" };
    
    for (keys, values) |k, v| {
        try trie.put(k, v);
    }
    
    for (keys, values) |k, v| {
        const retrieved = try trie.get(k);
        try testing.expectEqualStrings(v, retrieved);
    }
    
    std.debug.print("[StateTrie] Multiple keys OK ({d} keys)\n", .{keys.len});
}

test "StateTrie: root hash changes" {
    var trie = state_trie_mod.StateTrie.init(testing.allocator);
    defer trie.deinit();
    
    const root1 = trie.getRootHash();
    
    try trie.put("key", "value1");
    const root2 = trie.getRootHash();
    
    try trie.put("key", "value2");
    const root3 = trie.getRootHash();
    
    // Root-urile ar trebui să fie diferite
    var same1 = true;
    for (0..32) |i| {
        if (root1[i] != root2[i]) {
            same1 = false;
            break;
        }
    }
    try testing.expect(!same1);
    
    var same2 = true;
    for (0..32) |i| {
        if (root2[i] != root3[i]) {
            same2 = false;
            break;
        }
    }
    try testing.expect(!same2);
    
    std.debug.print("[StateTrie] Root hash OK\n", .{});
}

test "StateTrie: delete" {
    var trie = state_trie_mod.StateTrie.init(testing.allocator);
    defer trie.deinit();
    
    try trie.put("key_to_delete", "value");
    try testing.expect(try trie.exists("key_to_delete"));
    
    try trie.delete("key_to_delete");
    try testing.expect(!(try trie.exists("key_to_delete")));
    
    std.debug.print("[StateTrie] Delete OK\n", .{});
}

// =============================================================================
// PRUNE CONFIG TESTS
// =============================================================================

test "PruneConfig: default settings" {
    const config = prune_mod.PruneConfig.default();
    
    try testing.expect(config.keep_last_blocks > 0);
    try testing.expect(config.archive_old);
    
    std.debug.print("[PruneConfig] Default OK (keep={d} blocks)\n", .{config.keep_last_blocks});
}

test "PruneConfig: archive mode" {
    const archive_config = prune_mod.PruneConfig.archiveMode();
    
    try testing.expect(archive_config.archive_old);
    try testing.expect(!archive_config.delete_old);
    
    std.debug.print("[PruneConfig] Archive mode OK\n", .{});
}

test "PruneConfig: prune mode" {
    const prune_config = prune_mod.PruneConfig.pruneMode(1000);
    
    try testing.expectEqual(prune_config.keep_last_blocks, 1000);
    try testing.expect(!prune_config.archive_old);
    try testing.expect(prune_config.delete_old);
    
    std.debug.print("[PruneConfig] Prune mode OK\n", .{});
}

test "PruneConfig: should prune check" {
    const config = prune_mod.PruneConfig{
        .keep_last_blocks = 100,
        .archive_old = true,
        .delete_old = false,
    };
    
    // Block 50 cu head la 200 => ar trebui prunat
    try testing.expect(config.shouldPrune(50, 200));
    
    // Block 150 cu head la 200 => nu ar trebui prunat (prea recent)
    try testing.expect(!config.shouldPrune(150, 200));
    
    // Block 200 (head) => nu ar trebui prunat
    try testing.expect(!config.shouldPrune(200, 200));
    
    std.debug.print("[PruneConfig] Should prune OK\n", .{});
}

// =============================================================================
// ARCHIVE MANAGER TESTS
// =============================================================================

test "ArchiveManager: initialization" {
    var am = archive_mod.ArchiveManager.init(
        testing.allocator,
        ".test_archive"
    );
    defer am.deinit();
    
    try testing.expect(am.allocator == testing.allocator);
    
    std.debug.print("[ArchiveManager] Init OK\n", .{});
}

test "ArchiveManager: archive block" {
    var am = archive_mod.ArchiveManager.init(
        testing.allocator,
        ".test_archive"
    );
    defer am.deinit();
    
    const block_data = "serialized_block_data_here";
    
    try am.archiveBlock(100, block_data);
    
    const retrieved = try am.getArchivedBlock(100);
    defer testing.allocator.free(retrieved);
    
    try testing.expectEqualStrings(block_data, retrieved);
    
    std.debug.print("[ArchiveManager] Archive block OK\n", .{});
}

test "ArchiveManager: block range" {
    var am = archive_mod.ArchiveManager.init(
        testing.allocator,
        ".test_archive"
    );
    defer am.deinit();
    
    // Archive blocks 1-10
    for (1..11) |i| {
        var buf: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "block_{d}", .{i});
        try am.archiveBlock(@as(u64, @intCast(i)), data);
    }
    
    const range = try am.getBlockRange(3, 7);
    defer testing.allocator.free(range);
    
    try testing.expectEqual(range.len, 5); // blocks 3,4,5,6,7
    
    std.debug.print("[ArchiveManager] Block range OK ({d} blocks)\n", .{range.len});
}

test "ArchiveManager: oldest and newest" {
    var am = archive_mod.ArchiveManager.init(
        testing.allocator,
        ".test_archive"
    );
    defer am.deinit();
    
    try am.archiveBlock(100, "block_100");
    try am.archiveBlock(200, "block_200");
    try am.archiveBlock(150, "block_150");
    
    const oldest = am.getOldestBlock();
    const newest = am.getNewestBlock();
    
    try testing.expectEqual(oldest, 100);
    try testing.expectEqual(newest, 200);
    
    std.debug.print("[ArchiveManager] Oldest/Newest OK ({d} - {d})\n", .{ oldest, newest });
}

// =============================================================================
// DATABASE TESTS
// =============================================================================

test "Database: initialization" {
    var db = database_mod.Database.init(testing.allocator, ".test_db");
    defer db.deinit();
    
    try testing.expect(db.initialized);
    
    std.debug.print("[Database] Init OK\n", .{});
}

test "Database: key-value operations" {
    var db = database_mod.Database.init(testing.allocator, ".test_db");
    defer db.deinit();
    
    const key = "db_key";
    const value = "db_value";
    
    try db.put(key, value);
    
    const retrieved = try db.get(key);
    defer testing.allocator.free(retrieved);
    
    try testing.expectEqualStrings(value, retrieved);
    
    std.debug.print("[Database] KV operations OK\n", .{});
}

test "Database: batch write" {
    var db = database_mod.Database.init(testing.allocator, ".test_db");
    defer db.deinit();
    
    var batch = database_mod.WriteBatch.init(testing.allocator);
    defer batch.deinit();
    
    for (0..20) |i| {
        var k: [32]u8 = undefined;
        var v: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&k, "batch_key{d}", .{i});
        const val = try std.fmt.bufPrint(&v, "batch_val{d}", .{i});
        try batch.put(key, val);
    }
    
    try db.writeBatch(&batch);
    
    // Verifică un element
    const check = try db.get("batch_key5");
    defer testing.allocator.free(check);
    try testing.expectEqualStrings("batch_val5", check);
    
    std.debug.print("[Database] Batch write OK ({d} items)\n", .{batch.count()});
}

test "Database: iterator" {
    var db = database_mod.Database.init(testing.allocator, ".test_db");
    defer db.deinit();
    
    // Adaugă câteva keys
    try db.put("aaa", "1");
    try db.put("bbb", "2");
    try db.put("ccc", "3");
    
    var iter = db.iterator();
    defer iter.deinit();
    
    var count: usize = 0;
    while (try iter.next()) |entry| {
        count += 1;
        testing.allocator.free(entry.key);
        testing.allocator.free(entry.value);
    }
    
    try testing.expect(count >= 3);
    
    std.debug.print("[Database] Iterator OK ({d} items)\n", .{count});
}

// =============================================================================
// EDGE CASES
// =============================================================================

test "Edge: empty value" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    try storage.put("empty_key", "");
    
    const retrieved = try storage.get("empty_key");
    defer testing.allocator.free(retrieved);
    
    try testing.expectEqualStrings("", retrieved);
    
    std.debug.print("[Edge] Empty value OK\n", .{});
}

test "Edge: large value" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    var large_value: [10000]u8 = undefined;
    for (0..10000) |i| {
        large_value[i] = @as(u8, @truncate(i % 256));
    }
    
    try storage.putBytes("large_key", &large_value);
    
    const retrieved = try storage.getBytes("large_key");
    defer testing.allocator.free(retrieved);
    
    try testing.expectEqualSlices(u8, &large_value, retrieved);
    
    std.debug.print("[Edge] Large value OK ({d} bytes)\n", .{retrieved.len});
}

test "Edge: non-existent key" {
    var storage = storage_mod.Storage.init(testing.allocator, ".test_storage");
    defer storage.deinit();
    
    const result = storage.get("non_existent_key");
    try testing.expectError(error.KeyNotFound, result);
    
    std.debug.print("[Edge] Non-existent key OK\n", .{});
}

test "Edge: trie overwrite" {
    var trie = state_trie_mod.StateTrie.init(testing.allocator);
    defer trie.deinit();
    
    try trie.put("key", "value1");
    const val1 = try trie.get("key");
    try testing.expectEqualStrings("value1", val1);
    
    try trie.put("key", "value2");
    const val2 = try trie.get("key");
    try testing.expectEqualStrings("value2", val2);
    
    std.debug.print("[Edge] Trie overwrite OK\n", .{});
}

pub fn main() void {
    std.debug.print("\n=== Storage & Database Tests ===\n\n", .{});
}
