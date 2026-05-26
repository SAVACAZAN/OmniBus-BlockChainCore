// ============================================
// 8. core/package_relay.zig
// ============================================
const std = @import("std");
const Allocator = std.mem.Allocator;
const HashMap = std.AutoHashMap;

pub const Transaction = struct {
    txid: [32]u8,
    fee: u64,
    size: u64,
    parents: []const [32]u8,
    children: []const [32]u8,
    
    pub fn feeRate(self: *const Transaction) u64 {
        if (self.size == 0) return 0;
        return self.fee / self.size;
    }
};

pub const PackageRelayError = error{
    PackageTooLarge,
    CycleDetected,
};

pub const PackageRelay = struct {
    allocator: Allocator,
    transactions: HashMap([32]u8, Transaction),
    
    pub fn init(allocator: Allocator) PackageRelay {
        return PackageRelay{
            .allocator = allocator,
            .transactions = HashMap([32]u8, Transaction).init(allocator),
        };
    }
    
    pub fn deinit(self: *PackageRelay) void {
        self.transactions.deinit();
    }
    
    pub fn addTransaction(self: *PackageRelay, tx: Transaction) !void {
        try self.transactions.put(tx.txid, tx);
    }
    
    pub fn computeAncestorFeeRate(self: *PackageRelay, txid: [32]u8) !u64 {
        const tx = self.transactions.get(txid) orelse return 0;
        
        var total_fee = tx.fee;
        var total_size = tx.size;
        var visited = std.AutoHashMap([32]u8, void).init(self.allocator);
        defer visited.deinit();
        
        var queue = std.ArrayList([32]u8).init(self.allocator);
        defer queue.deinit();
        try queue.append(txid);
        
        var count: usize = 0;
        while (queue.items.len > 0) {
            if (count >= 25) return error.PackageTooLarge;
            
            const current = queue.orderedRemove(0);
            if (visited.contains(current)) continue;
            try visited.put(current, {});
            
            const current_tx = self.transactions.get(current) orelse continue;
            
            for (current_tx.parents) |parent_id| {
                if (self.transactions.get(parent_id)) |parent| {
                    total_fee += parent.fee;
                    total_size += parent.size;
                    try queue.append(parent_id);
                }
            }
            count += 1;
        }
        
        if (total_size == 0) return 0;
        return total_fee / total_size;
    }
    
    pub fn canAcceptPackage(self: *PackageRelay, txid: [32]u8, min_fee_rate: u64) !bool {
        const ancestor_rate = try self.computeAncestorFeeRate(txid);
        return ancestor_rate >= min_fee_rate;
    }
    
    pub fn detectCycles(self: *PackageRelay) !bool {
        var visited = std.AutoHashMap([32]u8, enum { Visiting, Visited }).init(self.allocator);
        defer visited.deinit();
        
        var it = self.transactions.iterator();
        while (it.next()) |entry| {
            if (!visited.contains(entry.key_ptr.*)) {
                if (try self.hasCycle(entry.key_ptr.*, &visited)) {
                    return true;
                }
            }
        }
        return false;
    }
    
    fn hasCycle(
        self: *PackageRelay,
        txid: [32]u8,
        visited: *std.AutoHashMap([32]u8, enum { Visiting, Visited }),
    ) !bool {
        const status = visited.get(txid);
        if (status == .Visiting) return true;
        if (status == .Visited) return false;
        
        try visited.put(txid, .Visiting);
        
        if (self.transactions.get(txid)) |tx| {
            for (tx.children) |child_id| {
                if (try self.hasCycle(child_id, visited)) return true;
            }
        }
        
        try visited.put(txid, .Visited);
        return false;
    }
};

test "PackageRelay ancestor fee rate" {
    var allocator = std.testing.allocator;
    var pr = PackageRelay.init(allocator);
    defer pr.deinit();
    
    const parent_tx = Transaction{
        .txid = [_]u8{1} ** 32,
        .fee = 100,
        .size = 100,
        .parents = &[_][32]u8{},
        .children = &[_][32]u8{},
    };
    const child_tx = Transaction{
        .txid = [_]u8{2} ** 32,
        .fee = 1000,
        .size = 100,
        .parents = &[_][32]u8{parent_tx.txid},
        .children = &[_][32]u8{},
    };
    
    try pr.addTransaction(parent_tx);
    try pr.addTransaction(child_tx);
    
    const ancestor_rate = try pr.computeAncestorFeeRate(child_tx.txid);
    // (100 + 1000) / (100 + 100) = 1100 / 200 = 5.5
    try std.testing.expect(ancestor_rate == 5);
}