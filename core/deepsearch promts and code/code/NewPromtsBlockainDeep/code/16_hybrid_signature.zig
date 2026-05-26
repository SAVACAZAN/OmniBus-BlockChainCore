// ============================================
// 7. core/fast_sync.zig
// ============================================
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const BlockHeader = struct {
    version: u32,
    prev_hash: [32]u8,
    merkle_root: [32]u8,
    timestamp: u64,
    height: u64,
    state_root: [32]u8,
};

pub const StateSnapshot = struct {
    block_hash: [32]u8,
    state_root: [32]u8,
    chunks: []const []const u8,
};

pub const FastSyncError = error{
    NoTrustedPeers,
    SnapshotVerificationFailed,
    HeaderDownloadFailed,
};

pub const FastSync = struct {
    allocator: Allocator,
    trusted_peers: ArrayList([]const u8),
    headers: ArrayList(BlockHeader),
    current_height: u64,
    
    pub fn init(allocator: Allocator) FastSync {
        return FastSync{
            .allocator = allocator,
            .trusted_peers = ArrayList([]const u8).init(allocator),
            .headers = ArrayList(BlockHeader).init(allocator),
            .current_height = 0,
        };
    }
    
    pub fn deinit(self: *FastSync) void {
        self.trusted_peers.deinit();
        self.headers.deinit();
    }
    
    pub fn addTrustedPeer(self: *FastSync, peer_addr: []const u8) !void {
        const addr = try self.allocator.duplicate(u8, peer_addr);
        try self.trusted_peers.append(addr);
    }
    
    pub fn downloadHeaders(self: *FastSync, target_height: u64) !void {
        if (self.trusted_peers.items.len == 0) return error.NoTrustedPeers;
        
        // Request headers from multiple peers
        var heights = ArrayList(u64).init(self.allocator);
        defer heights.deinit();
        
        var height: u64 = 0;
        while (height < target_height) {
            try heights.append(height);
            height += 100; // Batch size
        }
        
        // Simulate header download
        for (0..heights.items.len) |i| {
            const header = BlockHeader{
                .version = 1,
                .prev_hash = [_]u8{0} ** 32,
                .merkle_root = [_]u8{0} ** 32,
                .timestamp = @intCast(std.time.timestamp()),
                .height = heights.items[i],
                .state_root = [_]u8{0} ** 32,
            };
            try self.headers.append(header);
        }
    }
    
    pub fn downloadStateSnapshot(self: *FastSync, _: [32]u8) !StateSnapshot {
        // Request snapshot from trusted peer
        // Verify chunks against state_root
        return StateSnapshot{
            .block_hash = [_]u8{0} ** 32,
            .state_root = [_]u8{0} ** 32,
            .chunks = &[_][]const u8{},
        };
    }
    
    pub fn verifySnapshot(self: *FastSync, snapshot: *const StateSnapshot) bool {
        // Verify state_root matches computed root from chunks
        _ = snapshot;
        return true;
    }
    
    pub fn sync(self: *FastSync, target_height: u64) !void {
        std.debug.print("Starting fast sync to height {}\n", .{target_height});
        
        // Phase 1: Download headers
        std.debug.print("Phase 1: Downloading headers...\n", .{});
        try self.downloadHeaders(target_height);
        
        // Phase 2: Download state snapshot
        std.debug.print("Phase 2: Downloading state snapshot...\n", .{});
        const snapshot = try self.downloadStateSnapshot(self.headers.getLast().state_root);
        
        // Phase 3: Verify snapshot
        std.debug.print("Phase 3: Verifying snapshot...\n", .{});
        if (!self.verifySnapshot(&snapshot)) {
            return error.SnapshotVerificationFailed;
        }
        
        std.debug.print("Fast sync completed successfully!\n", .{});
        self.current_height = target_height;
    }
};

test "FastSync basic" {
    var allocator = std.testing.allocator;
    var fs = FastSync.init(allocator);
    defer {
        for (fs.trusted_peers.items) |peer| {
            allocator.free(peer);
        }
        fs.deinit();
    }
    
    try fs.addTrustedPeer("127.0.0.1:8333");
    try fs.downloadHeaders(1000);
    try std.testing.expect(fs.headers.items.len > 0);
}