// core/coin_control.zig - P1.5
const std = @import("std");
const Allocator = std.mem.Allocator;
const HashMap = std.AutoHashMap;
const OutPoint = @import("utxo.zig").OutPoint;

pub const CoinControl = struct {
    allocator: Allocator,
    frozen: HashMap(OutPoint, void),
    manual_selection: ?std.ArrayList(OutPoint),
    
    pub fn init(allocator: Allocator) CoinControl {
        return CoinControl{
            .allocator = allocator,
            .frozen = HashMap(OutPoint, void).init(allocator),
            .manual_selection = null,
        };
    }
    
    pub fn deinit(self: *CoinControl) void {
        self.frozen.deinit();
        if (self.manual_selection) |*list| {
            list.deinit();
        }
    }
    
    pub fn freeze(self: *CoinControl, outpoint: OutPoint) !void {
        try self.frozen.put(outpoint, {});
    }
    
    pub fn unfreeze(self: *CoinControl, outpoint: OutPoint) void {
        _ = self.frozen.remove(outpoint);
    }
    
    pub fn isFrozen(self: *const CoinControl, outpoint: OutPoint) bool {
        return self.frozen.contains(outpoint);
    }
    
    pub fn selectManual(self: *CoinControl, outpoints: []const OutPoint) !void {
        var list = try std.ArrayList(OutPoint).initCapacity(self.allocator, outpoints.len);
        errdefer list.deinit();
        for (outpoints) |op| {
            try list.append(op);
        }
        self.manual_selection = list;
    }
    
    pub fn clearManual(self: *CoinControl) void {
        if (self.manual_selection) |*list| {
            list.deinit();
            self.manual_selection = null;
        }
    }
    
    pub fn getSelectedUTXOs(self: *const CoinControl) ?[]const OutPoint {
        if (self.manual_selection) |list| {
            return list.items;
        }
        return null;
    }
};

test "CoinControl freeze and unfreeze" {
    var allocator = std.testing.allocator;
    var cc = CoinControl.init(allocator);
    defer cc.deinit();
    
    const op = OutPoint{ .txid = [_]u8{0} ** 32, .index = 0 };
    try cc.freeze(op);
    try std.testing.expect(cc.isFrozen(op));
    
    cc.unfreeze(op);
    try std.testing.expect(!cc.isFrozen(op));
}

test "CoinControl manual selection" {
    var allocator = std.testing.allocator;
    var cc = CoinControl.init(allocator);
    defer cc.deinit();
    
    const op1 = OutPoint{ .txid = [_]u8{1} ** 32, .index = 0 };
    const op2 = OutPoint{ .txid = [_]u8{2} ** 32, .index = 1 };
    const ops = [_]OutPoint{op1, op2};
    
    try cc.selectManual(&ops);
    defer cc.clearManual();
    
    const selected = cc.getSelectedUTXOs();
    try std.testing.expect(selected != null);
    try std.testing.expect(selected.?.len == 2);
}