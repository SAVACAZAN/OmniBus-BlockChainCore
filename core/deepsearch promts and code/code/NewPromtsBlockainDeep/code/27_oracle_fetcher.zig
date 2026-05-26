// ============================================
// Fix pentru core/oracle_fetcher.zig
// ============================================
// Problema: const vs var pentru state mutabil
// Soluția: Schimbă declarațiile const în var pentru câmpurile care se modifică

// În struct OracleFetcher, schimbă:
// const cache: Cache -> var cache: Cache
// const price_history: []PricePoint -> var price_history: []PricePoint

// Exemplu de fix:

pub const OracleFetcher = struct {
    allocator: std.mem.Allocator,
    var cache: std.AutoHashMap(u64, u64), // Make this var instead of const
    var price_history: std.ArrayList(PricePoint), // Make this var instead of const
    
    pub fn init(allocator: std.mem.Allocator) !OracleFetcher {
        var cache = std.AutoHashMap(u64, u64).init(allocator);
        var price_history = std.ArrayList(PricePoint).init(allocator);
        return OracleFetcher{
            .allocator = allocator,
            .cache = cache,
            .price_history = price_history,
        };
    }
    
    pub fn updateCache(self: *OracleFetcher, key: u64, value: u64) !void {
        try self.cache.put(key, value); // Now mutable
    }
    
    pub fn addPricePoint(self: *OracleFetcher, point: PricePoint) !void {
        try self.price_history.append(point); // Now mutable
    }
};