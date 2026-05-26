// ============================================
// tests/test_coin_control.zig
// ============================================
const std = @import("std");
const CoinControl = @import("../core/coin_control.zig").CoinControl;
const OutPoint = @import("../core/utxo.zig").OutPoint;

test "CoinControl freeze and unfreeze" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();
    
    const op = OutPoint{ .txid = [_]u8{1} ** 32, .index = 0 };
    try cc.freeze(op);
    try std.testing.expect(cc.isFrozen(op));
    try std.testing.expect(!cc.shouldInclude(op));
    
    cc.unfreeze(op);
    try std.testing.expect(!cc.isFrozen(op));
    try std.testing.expect(cc.shouldInclude(op));
}

test "CoinControl manual selection overrides freeze" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();
    
    const op1 = OutPoint{ .txid = [_]u8{1} ** 32, .index = 0 };
    const op2 = OutPoint{ .txid = [_]u8{2} ** 32, .index = 1 };
    
    try cc.freeze(op1);
    try cc.selectManual(&[_]OutPoint{op1, op2});
    defer cc.clearManual();
    
    // Manual selection overrides freeze
    try std.testing.expect(cc.shouldInclude(op1));
    try std.testing.expect(cc.shouldInclude(op2));
}

test "CoinControl manual selection insufficient" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();
    
    const op = OutPoint{ .txid = [_]u8{1} ** 32, .index = 0 };
    try cc.selectManual(&[_]OutPoint{op});
    defer cc.clearManual();
    
    const selected = cc.getManualSelection();
    try std.testing.expect(selected != null);
    try std.testing.expect(selected.?.len == 1);
}