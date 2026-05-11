/// treasury_multi.zig — Treasury auto-distribution engine.
///
/// A treasury address auto-splits incoming funds to multiple destinations by
/// percentage (basis points). Distribution is triggered:
///   (a) manually via `treasury_distribute` RPC, or
///   (b) automatically after each block when balance >= trigger_amount_sat.
///
/// NOTE: file is named treasury_multi.zig to avoid collision with the existing
/// `treasury_agent.zig` which handles the AI-autonomous treasury agent logic.
///
/// Persistence: data/treasury_multi.jsonl

const std = @import("std");
const array_list = std.array_list;

pub const ADDR_MAX:     usize = 128;
pub const LABEL_MAX:    usize = 128;
pub const MAX_DESTS:    usize = 32;
pub const MAX_TREASURY: usize = 1_000;
pub const ID_HEX_LEN:   usize = 64;

pub const TreasuryDest = struct {
    address:   [ADDR_MAX]u8  = [_]u8{0} ** ADDR_MAX,
    addr_len:  u8            = 0,
    share_bps: u16           = 0,   // basis points; all shares must sum to 10000
    label:     [LABEL_MAX]u8 = [_]u8{0} ** LABEL_MAX,
    label_len: u8            = 0,

    pub fn addressSlice(self: *const TreasuryDest) []const u8 { return self.address[0..self.addr_len]; }
    pub fn labelSlice(self: *const TreasuryDest) []const u8   { return self.label[0..self.label_len]; }
};

pub const Treasury = struct {
    id:                    [ID_HEX_LEN]u8   = [_]u8{0} ** ID_HEX_LEN,
    treasury_address:      [ADDR_MAX]u8     = [_]u8{0} ** ADDR_MAX,
    treasury_addr_len:     u8               = 0,
    destinations:          [MAX_DESTS]TreasuryDest = [_]TreasuryDest{.{}} ** MAX_DESTS,
    dest_count:            u8               = 0,
    /// Minimum balance before auto-distribution triggers (SAT). 0 = never auto.
    trigger_amount_sat:    u64              = 0,
    last_distribute_block: u64              = 0,
    total_distributed_sat: u64              = 0,
    label:                 [LABEL_MAX]u8    = [_]u8{0} ** LABEL_MAX,
    label_len:             u8               = 0,
    active:                bool             = true,

    pub fn treasurySlice(self: *const Treasury) []const u8 { return self.treasury_address[0..self.treasury_addr_len]; }
    pub fn labelSlice(self: *const Treasury) []const u8    { return self.label[0..self.label_len]; }
    pub fn idSlice(self: *const Treasury) []const u8       { return self.id[0..ID_HEX_LEN]; }

    /// Validate that all share_bps sum to exactly 10000.
    pub fn sharesValid(self: *const Treasury) bool {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < self.dest_count) : (i += 1) {
            total += self.destinations[i].share_bps;
        }
        return total == 10_000;
    }

    /// Compute amount for destination i given total_sat.
    pub fn destAmount(self: *const Treasury, i: usize, total_sat: u64) u64 {
        return (total_sat * self.destinations[i].share_bps) / 10_000;
    }
};

fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    var idx: usize = 0;
    for (bytes) |b| {
        out[idx]   = hex_chars[b >> 4];
        out[idx+1] = hex_chars[b & 0xf];
        idx += 2;
    }
}

fn computeTreasuryId(treasury_address: []const u8, created_unix_s: u64, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(treasury_address);
    var ts: [8]u8 = undefined;
    std.mem.writeInt(u64, &ts, created_unix_s, .little);
    h.update(&ts);
    h.final(out);
}

pub const TreasuryStore = struct {
    items:     array_list.Managed(Treasury),
    mutex:     std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TreasuryStore {
        return .{
            .items     = array_list.Managed(Treasury).init(allocator),
            .mutex     = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TreasuryStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.items.deinit();
    }

    /// Create treasury. Returns the hex ID string.
    pub fn create(
        self:               *TreasuryStore,
        treasury_address:   []const u8,
        dests:              []const TreasuryDest,
        trigger_amount_sat: u64,
        label:              []const u8,
    ) ![ID_HEX_LEN]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.items.items.len >= MAX_TREASURY) return error.StoreFull;
        if (dests.len == 0 or dests.len > MAX_DESTS) return error.InvalidDestCount;

        const now: u64 = @intCast(std.time.timestamp());
        var id_bytes: [32]u8 = undefined;
        computeTreasuryId(treasury_address, now, &id_bytes);
        var id_hex: [ID_HEX_LEN]u8 = undefined;
        bytesToHex(&id_bytes, &id_hex);

        var t = Treasury{
            .trigger_amount_sat = trigger_amount_sat,
            .dest_count         = @intCast(dests.len),
        };
        t.id = id_hex;

        const ac = @min(treasury_address.len, ADDR_MAX - 1);
        @memcpy(t.treasury_address[0..ac], treasury_address[0..ac]);
        t.treasury_addr_len = @intCast(ac);

        const lc = @min(label.len, LABEL_MAX - 1);
        @memcpy(t.label[0..lc], label[0..lc]);
        t.label_len = @intCast(lc);

        for (dests, 0..) |d, i| {
            t.destinations[i] = d;
        }

        // Validate bps sum
        var bps_total: u32 = 0;
        for (dests) |d| bps_total += d.share_bps;
        if (bps_total != 10_000) return error.InvalidSharesSum;

        try self.items.append(t);
        return id_hex;
    }

    /// Get treasury by hex id (returns a copy).
    pub fn getById(self: *TreasuryStore, id_hex: []const u8) ?Treasury {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |t| {
            if (std.mem.eql(u8, t.id[0..ID_HEX_LEN], id_hex)) return t;
        }
        return null;
    }

    /// Get treasury by address (returns first active match, copy).
    pub fn getByAddress(self: *TreasuryStore, address: []const u8) ?Treasury {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |t| {
            if (!t.active) continue;
            if (std.mem.eql(u8, t.treasurySlice(), address)) return t;
        }
        return null;
    }

    /// Update distribution stats after a successful distribute call.
    pub fn recordDistribute(self: *TreasuryStore, id_hex: []const u8, amount_sat: u64, block: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items.items) |*t| {
            if (!std.mem.eql(u8, t.id[0..ID_HEX_LEN], id_hex)) continue;
            t.last_distribute_block = block;
            t.total_distributed_sat +|= amount_sat;
            return;
        }
    }

    /// List all active treasuries (max out.len).
    pub fn listAll(self: *TreasuryStore, out: []Treasury) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.items.items) |t| {
            if (!t.active) continue;
            if (n >= out.len) break;
            out[n] = t;
            n += 1;
        }
        return n;
    }

    /// List all treasury addresses for auto-trigger check.
    pub fn listAllAddresses(self: *TreasuryStore, out: []Treasury) usize {
        return self.listAll(out);
    }
};
