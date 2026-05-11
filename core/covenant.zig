/// covenant.zig — Destination whitelist covenants.
///
/// An address with an active covenant can ONLY send to addresses in its
/// whitelist. Optional per-TX amount cap and expiry block.
///
/// Enforcement is in blockchain.zig validateTransaction (called before mempool
/// accept and before block apply).
///
/// Persistence: data/covenants.jsonl

const std = @import("std");
const array_list = std.array_list;

pub const ADDR_MAX:        usize = 128;
pub const LABEL_MAX:       usize = 128;
pub const MAX_WHITELIST:   usize = 64;
pub const MAX_COVENANTS:   usize = 10_000;

pub const Covenant = struct {
    /// The restricted sender address.
    address:             [ADDR_MAX]u8    = [_]u8{0} ** ADDR_MAX,
    address_len:         u8             = 0,
    /// Allowed destination addresses (allocator-owned slice of fixed arrays).
    whitelist:           [MAX_WHITELIST][ADDR_MAX]u8 = [_][ADDR_MAX]u8{[_]u8{0} ** ADDR_MAX} ** MAX_WHITELIST,
    whitelist_lens:      [MAX_WHITELIST]u8           = [_]u8{0} ** MAX_WHITELIST,
    whitelist_count:     u8             = 0,
    /// 0 = unlimited.
    max_amount_per_tx_sat: u64          = 0,
    /// 0 = never expires.
    expires_block:       u64            = 0,
    created_unix_s:      u64            = 0,
    label:               [LABEL_MAX]u8  = [_]u8{0} ** LABEL_MAX,
    label_len:           u8             = 0,
    active:              bool           = true,

    pub fn addressSlice(self: *const Covenant) []const u8 { return self.address[0..self.address_len]; }
    pub fn labelSlice(self: *const Covenant) []const u8   { return self.label[0..self.label_len]; }
    pub fn whitelistEntry(self: *const Covenant, i: usize) []const u8 {
        return self.whitelist[i][0..self.whitelist_lens[i]];
    }

    /// Returns true if to_address is in the whitelist.
    pub fn isAllowed(self: *const Covenant, to_address: []const u8) bool {
        var i: usize = 0;
        while (i < self.whitelist_count) : (i += 1) {
            if (std.mem.eql(u8, self.whitelistEntry(i), to_address)) return true;
        }
        return false;
    }

    /// Returns true if this covenant is currently active at current_block.
    pub fn isActive(self: *const Covenant, current_block: u64) bool {
        if (!self.active) return false;
        if (self.expires_block > 0 and current_block >= self.expires_block) return false;
        return true;
    }
};

pub const CovenantStore = struct {
    covenants: array_list.Managed(Covenant),
    mutex:     std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CovenantStore {
        return .{
            .covenants = array_list.Managed(Covenant).init(allocator),
            .mutex     = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CovenantStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.covenants.deinit();
    }

    /// Create covenant for address. Replaces any previous active covenant.
    pub fn create(
        self:                *CovenantStore,
        address:             []const u8,
        whitelist_addrs:     []const []const u8,
        max_amount_per_tx:   u64,
        expires_block:       u64,
        label:               []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.covenants.items.len >= MAX_COVENANTS) return error.StoreFull;
        if (whitelist_addrs.len > MAX_WHITELIST) return error.TooManyWhitelistEntries;

        // Deactivate existing covenant for this address
        for (self.covenants.items) |*c| {
            if (std.mem.eql(u8, c.addressSlice(), address)) {
                c.active = false;
            }
        }

        var cov = Covenant{
            .max_amount_per_tx_sat = max_amount_per_tx,
            .expires_block         = expires_block,
            .created_unix_s        = @intCast(std.time.timestamp()),
            .whitelist_count       = @intCast(whitelist_addrs.len),
        };

        const ac = @min(address.len, ADDR_MAX - 1);
        @memcpy(cov.address[0..ac], address[0..ac]);
        cov.address_len = @intCast(ac);

        const lc = @min(label.len, LABEL_MAX - 1);
        @memcpy(cov.label[0..lc], label[0..lc]);
        cov.label_len = @intCast(lc);

        for (whitelist_addrs, 0..) |waddr, i| {
            const wc = @min(waddr.len, ADDR_MAX - 1);
            @memcpy(cov.whitelist[i][0..wc], waddr[0..wc]);
            cov.whitelist_lens[i] = @intCast(wc);
        }

        try self.covenants.append(cov);
    }

    /// Remove (deactivate) covenant for address. Returns true if found.
    pub fn remove(self: *CovenantStore, address: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var found = false;
        for (self.covenants.items) |*c| {
            if (std.mem.eql(u8, c.addressSlice(), address) and c.active) {
                c.active = false;
                found = true;
            }
        }
        return found;
    }

    /// Get the active covenant for address (returns a copy). Null if none.
    pub fn getActive(self: *CovenantStore, address: []const u8, current_block: u64) ?Covenant {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Scan in reverse — last created takes precedence
        var i = self.covenants.items.len;
        while (i > 0) {
            i -= 1;
            const c = &self.covenants.items[i];
            if (!std.mem.eql(u8, c.addressSlice(), address)) continue;
            if (!c.isActive(current_block)) continue;
            return c.*;
        }
        return null;
    }

    /// Validate: returns true if TX from `from_address` to `to_address` of
    /// `amount_sat` is allowed by covenant rules at `current_block`.
    /// Returns true also when no active covenant exists (unrestricted address).
    pub fn checkTx(
        self:          *CovenantStore,
        from_address:  []const u8,
        to_address:    []const u8,
        amount_sat:    u64,
        current_block: u64,
    ) bool {
        const cov_opt = self.getActive(from_address, current_block);
        const cov = cov_opt orelse return true; // no covenant → unrestricted
        if (!cov.isAllowed(to_address)) return false;
        if (cov.max_amount_per_tx_sat > 0 and amount_sat > cov.max_amount_per_tx_sat) return false;
        return true;
    }

    /// List all active covenants (max out.len).
    pub fn listAll(self: *CovenantStore, current_block: u64, out: []Covenant) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.covenants.items) |c| {
            if (!c.isActive(current_block)) continue;
            if (n >= out.len) break;
            out[n] = c;
            n += 1;
        }
        return n;
    }
};
