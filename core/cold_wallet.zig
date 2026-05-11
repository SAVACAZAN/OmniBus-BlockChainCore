/// cold_wallet.zig — Watch-only (cold) wallet registry.
///
/// A cold wallet is an address tracked by the node for balance/history queries
/// but whose private key is never held on the node. Useful for auditing a
/// hardware-wallet or paper-wallet address without exposing the key.
///
/// Persistence: data/cold_wallets.jsonl (append-only, one JSON object per line).

const std = @import("std");
const array_list = std.array_list;

pub const ADDR_MAX:  usize = 128;
pub const LABEL_MAX: usize = 128;
pub const MAX_ENTRIES: usize = 10_000;

pub const ColdWallet = struct {
    address:             [ADDR_MAX]u8  = [_]u8{0} ** ADDR_MAX,
    address_len:         u8            = 0,
    label:               [LABEL_MAX]u8 = [_]u8{0} ** LABEL_MAX,
    label_len:           u8            = 0,
    created_unix_s:      u64           = 0,
    total_received_sat:  u64           = 0,   // updated on each incoming TX apply
    is_watch_only:       bool          = true,

    pub fn addressSlice(self: *const ColdWallet) []const u8 { return self.address[0..self.address_len]; }
    pub fn labelSlice(self: *const ColdWallet) []const u8  { return self.label[0..self.label_len]; }
};

pub const ColdWalletStore = struct {
    entries:   array_list.Managed(ColdWallet),
    mutex:     std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ColdWalletStore {
        return .{
            .entries   = array_list.Managed(ColdWallet).init(allocator),
            .mutex     = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ColdWalletStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.deinit();
    }

    /// Add a watch-only entry. Returns false if already present or store full.
    pub fn add(self: *ColdWalletStore, address: []const u8, label: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.items.len >= MAX_ENTRIES) return false;
        // Reject duplicate address
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.addressSlice(), address)) return false;
        }
        var entry = ColdWallet{
            .created_unix_s = @intCast(std.time.timestamp()),
        };
        const ac = @min(address.len, ADDR_MAX - 1);
        @memcpy(entry.address[0..ac], address[0..ac]);
        entry.address_len = @intCast(ac);
        const lc = @min(label.len, LABEL_MAX - 1);
        @memcpy(entry.label[0..lc], label[0..lc]);
        entry.label_len = @intCast(lc);
        self.entries.append(entry) catch return false;
        return true;
    }

    /// Remove by address. Returns true if found and removed.
    pub fn remove(self: *ColdWalletStore, address: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.addressSlice(), address)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Find by address (returns a copy).
    pub fn find(self: *ColdWalletStore, address: []const u8) ?ColdWallet {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.addressSlice(), address)) return e;
        }
        return null;
    }

    /// Copy all entries into out[]. Returns count written.
    pub fn listAll(self: *ColdWalletStore, out: []ColdWallet) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(self.entries.items.len, out.len);
        @memcpy(out[0..n], self.entries.items[0..n]);
        return n;
    }

    /// Called by applyBlock when a TX arrives whose to_address matches a cold wallet.
    pub fn onReceive(self: *ColdWalletStore, to_address: []const u8, amount_sat: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.addressSlice(), to_address)) {
                e.total_received_sat +|= amount_sat;
                return;
            }
        }
    }

    /// Persist to JSONL file (append-only safe, rewrites on call).
    pub fn saveToFile(self: *ColdWalletStore, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var file = std.fs.cwd().createFile(path, .{}) catch return;
        defer file.close();
        var buf: [512]u8 = undefined;
        for (self.entries.items) |e| {
            const line = std.fmt.bufPrint(&buf,
                "{{\"address\":\"{s}\",\"label\":\"{s}\",\"created\":{d},\"received\":{d}}}\n",
                .{ e.addressSlice(), e.labelSlice(), e.created_unix_s, e.total_received_sat },
            ) catch continue;
            _ = file.write(line) catch {};
        }
    }
};
