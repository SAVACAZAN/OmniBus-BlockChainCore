//! Tests for Coin Control functionality

const std = @import("std");
const testing = std.testing;
const coin_control = @import("../../core/coin_control.zig");

test "CoinControl: Basic operations" {
    var cc = coin_control.CoinControl.init(testing.allocator);
    defer cc.deinit();
    
    const txid = [_]u8{0x11} ** 32;
    try cc.addUtxo(txid, 0, 100000, "test_addr", "test_script");
    
    try testing.expectEqual(cc.getBalance(), 100000);
}

test "CoinControl: Freeze and unfreeze" {
    var cc = coin_control.CoinControl.init(testing.allocator);
    defer cc.deinit();
    
    const txid = [_]u8{0x22} ** 32;
    try cc.addUtxo(txid, 0, 50000, "test_addr", "test_script");
    
    try testing.expectEqual(cc.getBalance(), 50000);
    
    try cc.freezeUtxo(txid, 0);
    try testing.expectEqual(cc.getBalance(), 0);
    
    try cc.unfreezeUtxo(txid, 0);
    try testing.expectEqual(cc.getBalance(), 50000);
}

test "CoinControl: Manual UTXO selection" {
    var cc = coin_control.CoinControl.init(testing.allocator);
    defer cc.deinit();
    
    const txid1 = [_]u8{0x11} ** 32;
    const txid2 = [_]u8{0x22} ** 32;
    
    try cc.addUtxo(txid1, 0, 100000, "addr1", "script1");
    try cc.addUtxo(txid2, 0, 200000, "addr2", "script2");
    
    const key1 = try cc.makeKeyForTest(txid1, 0);
    defer testing.allocator.free(key1);
    const key2 = try cc.makeKeyForTest(txid2, 0);
    defer testing.allocator.free(key2);
    
    const keys = [_][]u8{key1, key2};
    var utxo_keys: [2][36]u8 = undefined;
    for (keys, 0..) |k, i| {
        @memcpy(&utxo_keys[i], k);
    }
    
    const selected = try cc.selectUtxos(&utxo_keys);
    defer testing.allocator.free(selected);
    
    try testing.expect(selected.len == 2);
    try testing.expect(selected[0].amount == 100000);
    try testing.expect(selected[1].amount == 200000);
}

test "CoinControl: Auto selection" {
    var cc = coin_control.CoinControl.init(testing.allocator);
    defer cc.deinit();
    
    const txid1 = [_]u8{0x11} ** 32;
    const txid2 = [_]u8{0x22} ** 32;
    const txid3 = [_]u8{0x33} ** 32;
    
    try cc.addUtxo(txid1, 0, 10000, "addr1", "script1");
    try cc.addUtxo(txid2, 0, 50000, "addr2", "script2");
    try cc.addUtxo(txid3, 0, 25000, "addr3", "script3");
    
    const result = try cc.selectUtxosAuto(60000);
    defer testing.allocator.free(result.utxos);
    
    try testing.expect(result.total >= 60000);
}

test "CoinControl: Insufficient funds" {
    var cc = coin_control.CoinControl.init(testing.allocator);
    defer cc.deinit();
    
    const txid = [_]u8{0x11} ** 32;
    try cc.addUtxo(txid, 0, 100, "addr", "script");
    
    const result = cc.selectUtxosAuto(1000);
    try testing.expectError(error.InsufficientFunds, result);
}

test "CoinControl: UTXO reservation" {
    var cc = coin_control.CoinControl.init(testing.allocator);
    defer cc.deinit();
    
    const txid = [_]u8{0x11} ** 32;
    try cc.addUtxo(txid, 0, 100000, "addr", "script");
    
    const key = try cc.makeKeyForTest(txid, 0);
    defer testing.allocator.free(key);
    var key_bytes: [36]u8 = undefined;
    @memcpy(&key_bytes, key);
    
    try cc.reserveUtxos(&[_][36]u8{key_bytes}, "tx123");
    
    const frozen = try cc.getFrozenUtxos();
    defer testing.allocator.free(frozen);
    
    // Reserved UTXOs are not available for selection
    try testing.expectEqual(cc.getBalance(), 0);
}