const std = @import("std");
const array_list = std.array_list;

// ── Constants ─────────────────────────────────────────────────────────────────

pub const FOLLOW_FEE_SAT: u64 = 1000;
pub const ADDR_MAX: usize     = 128;
pub const MAX_LIST: usize     = 512;

// ── FollowEntry ───────────────────────────────────────────────────────────────

pub const FollowEntry = struct {
    follower:      [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    follower_len:  usize = 0,
    following:     [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    following_len: usize = 0,
    block_height:  u64,
    removed:       bool = false,

    pub fn followerSlice(self: *const FollowEntry) []const u8 {
        return self.follower[0..self.follower_len];
    }

    pub fn followingSlice(self: *const FollowEntry) []const u8 {
        return self.following[0..self.following_len];
    }
};

// ── Named types for HashMap values ───────────────────────────────────────────
// Using named structs avoids anonymous-struct uniqueness issues in HashMaps.

const AddrList = array_list.Managed([]const u8);

// ── SocialGraph ───────────────────────────────────────────────────────────────

pub const SocialGraph = struct {
    allocator: std.mem.Allocator,
    /// address → list of addresses that follow it (heap-duped strings)
    followers: std.StringHashMap(AddrList),
    /// address → list of addresses it follows (heap-duped strings)
    following: std.StringHashMap(AddrList),
    mutex:     std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) SocialGraph {
        return .{
            .allocator = allocator,
            .followers = std.StringHashMap(AddrList).init(allocator),
            .following = std.StringHashMap(AddrList).init(allocator),
            .mutex     = .{},
        };
    }

    pub fn deinit(self: *SocialGraph) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free followers map: each key is heap-duped; each value list holds
        // heap-duped address slices.
        var fit = self.followers.iterator();
        while (fit.next()) |entry| {
            for (entry.value_ptr.items) |addr| {
                self.allocator.free(addr);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.followers.deinit();

        // Free following map similarly.
        var fwit = self.following.iterator();
        while (fwit.next()) |entry| {
            for (entry.value_ptr.items) |addr| {
                self.allocator.free(addr);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.following.deinit();
    }

    /// Record that `follower` follows `target` at `block_height`.
    /// No-op (returns without error) if already following.
    pub fn follow(
        self:         *SocialGraph,
        follower:     []const u8,
        target:       []const u8,
        block_height: u64,
    ) !void {
        _ = block_height;
        self.mutex.lock();
        defer self.mutex.unlock();

        // Deduplicate: bail if already following.
        if (self.isFollowingLocked(follower, target)) return;

        // Enforce MAX_LIST cap.
        const fw_count = if (self.following.get(follower)) |l| l.items.len else 0;
        if (fw_count >= MAX_LIST) return;

        // ── followers[target] += follower ──────────────────────────────────────
        const ft_gop = try self.followers.getOrPut(target);
        if (!ft_gop.found_existing) {
            ft_gop.key_ptr.* = try self.allocator.dupe(u8, target);
            ft_gop.value_ptr.* = AddrList.init(self.allocator);
        }
        const follower_dup = try self.allocator.dupe(u8, follower);
        errdefer self.allocator.free(follower_dup);
        try ft_gop.value_ptr.append(follower_dup);

        // ── following[follower] += target ──────────────────────────────────────
        const fw_gop = try self.following.getOrPut(follower);
        if (!fw_gop.found_existing) {
            fw_gop.key_ptr.* = try self.allocator.dupe(u8, follower);
            fw_gop.value_ptr.* = AddrList.init(self.allocator);
        }
        const target_dup = try self.allocator.dupe(u8, target);
        errdefer self.allocator.free(target_dup);
        try fw_gop.value_ptr.append(target_dup);
    }

    /// Remove the follow relationship between `follower` and `target`.
    /// Silent no-op if it does not exist.
    pub fn unfollow(self: *SocialGraph, follower: []const u8, target: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        removeFromList(self.allocator, &self.followers, target, follower);
        removeFromList(self.allocator, &self.following, follower, target);
    }

    /// Copy follower addresses for `address` into `out`. Returns count written.
    pub fn getFollowers(self: *SocialGraph, address: []const u8, out: [][]const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.followers.get(address) orelse return 0;
        const n = @min(list.items.len, out.len);
        for (list.items[0..n], 0..) |addr, i| out[i] = addr;
        return n;
    }

    /// Copy following addresses for `address` into `out`. Returns count written.
    pub fn getFollowing(self: *SocialGraph, address: []const u8, out: [][]const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.following.get(address) orelse return 0;
        const n = @min(list.items.len, out.len);
        for (list.items[0..n], 0..) |addr, i| out[i] = addr;
        return n;
    }

    pub fn followerCount(self: *SocialGraph, address: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.followers.get(address) orelse return 0;
        return list.items.len;
    }

    pub fn followingCount(self: *SocialGraph, address: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.following.get(address) orelse return 0;
        return list.items.len;
    }

    pub fn isFollowing(self: *SocialGraph, follower: []const u8, target: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.isFollowingLocked(follower, target);
    }

    // ── Internal helpers (called with mutex already held) ─────────────────────

    fn isFollowingLocked(self: *SocialGraph, follower: []const u8, target: []const u8) bool {
        const list = self.following.get(follower) orelse return false;
        for (list.items) |addr| {
            if (std.mem.eql(u8, addr, target)) return true;
        }
        return false;
    }
};

// ── removeFromList — removes the first occurrence of `value` from map[key] ───
// Frees the heap-duped string that was stored. Swap-removes for O(1).

fn removeFromList(
    allocator: std.mem.Allocator,
    map:       *std.StringHashMap(AddrList),
    key:       []const u8,
    value:     []const u8,
) void {
    const list_ptr = map.getPtr(key) orelse return;
    const items = list_ptr.items;
    for (items, 0..) |addr, i| {
        if (std.mem.eql(u8, addr, value)) {
            allocator.free(addr);
            // Swap-remove: move last element into this slot.
            if (i + 1 < items.len) {
                items[i] = items[items.len - 1];
            }
            list_ptr.items.len -= 1;
            return;
        }
    }
}

// ── op_return parsers ─────────────────────────────────────────────────────────

/// Parse "follow:<addr>" — returns the address slice (points into `op_return`).
pub fn parseFollow(op_return: []const u8) ?[]const u8 {
    const PREFIX = "follow:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const addr = op_return[PREFIX.len..];
    if (addr.len == 0 or addr.len > ADDR_MAX) return null;
    return addr;
}

/// Parse "unfollow:<addr>" — returns the address slice (points into `op_return`).
pub fn parseUnfollow(op_return: []const u8) ?[]const u8 {
    const PREFIX = "unfollow:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const addr = op_return[PREFIX.len..];
    if (addr.len == 0 or addr.len > ADDR_MAX) return null;
    return addr;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseFollow / parseUnfollow" {
    const t = std.testing;
    try t.expectEqualStrings("ob1abc", parseFollow("follow:ob1abc").?);
    try t.expectEqual(@as(?[]const u8, null), parseFollow("unfollow:ob1abc"));
    try t.expectEqualStrings("ob1xyz", parseUnfollow("unfollow:ob1xyz").?);
    try t.expectEqual(@as(?[]const u8, null), parseUnfollow("follow:ob1xyz"));
    try t.expectEqual(@as(?[]const u8, null), parseFollow("follow:"));
}

test "SocialGraph follow / unfollow / counts" {
    const t = std.testing;
    var sg = SocialGraph.init(std.testing.allocator);
    defer sg.deinit();

    try sg.follow("alice", "bob", 1);
    try sg.follow("alice", "carol", 2);
    try sg.follow("dave", "bob", 3);

    try t.expectEqual(@as(usize, 2), sg.followingCount("alice"));
    try t.expectEqual(@as(usize, 2), sg.followerCount("bob"));
    try t.expectEqual(@as(usize, 1), sg.followerCount("carol"));
    try t.expect(sg.isFollowing("alice", "bob"));
    try t.expect(!sg.isFollowing("bob", "alice"));

    // Double-follow is a no-op.
    try sg.follow("alice", "bob", 4);
    try t.expectEqual(@as(usize, 2), sg.followingCount("alice"));

    sg.unfollow("alice", "bob");
    try t.expectEqual(@as(usize, 1), sg.followingCount("alice"));
    try t.expectEqual(@as(usize, 1), sg.followerCount("bob"));
    try t.expect(!sg.isFollowing("alice", "bob"));
}

test "SocialGraph getFollowers / getFollowing" {
    const t = std.testing;
    var sg = SocialGraph.init(std.testing.allocator);
    defer sg.deinit();

    try sg.follow("alice", "bob", 1);
    try sg.follow("carol", "bob", 2);

    var buf: [8][]const u8 = undefined;
    const n = sg.getFollowers("bob", &buf);
    try t.expectEqual(@as(usize, 2), n);

    var fw_buf: [8][]const u8 = undefined;
    const m = sg.getFollowing("alice", &fw_buf);
    try t.expectEqual(@as(usize, 1), m);
    try t.expectEqualStrings("bob", fw_buf[0]);
}
