/// subscription.zig — on-chain recurring payment protocol.
///
/// Un utilizator semnează o singură dată. Chain-ul auto-execută
/// plata la fiecare `interval_blocks` blocuri, până la `max_payments`
/// sau până la `sub_cancel`.
///
/// op_return format:
///   sub_create:  "sub_create:<to>:<amount_sat>:<interval>:<max>[:<note>]"
///   sub_cancel:  "sub_cancel:<sub_id>"
///
/// Fee la creare: SUB_CREATE_FEE_SAT (0.01 OMNI) — anti-spam.
/// Fiecare payment auto-execut: SUB_EXEC_FEE_SAT (100 SAT) trimis la treasury.
///
/// Design:
///   - Subscriber trebuie să aibă fonduri în wallet la momentul execuției.
///   - Dacă nu are fonduri, plata e sărită (NU anulată); se reîncearcă la
///     urm. interval.
///   - max_payments = 0 → infinit.

const std = @import("std");
const array_list = std.array_list;

// ── Constants ─────────────────────────────────────────────────────────────────

/// 0.01 OMNI în SAT — fee creare subscripție
pub const SUB_CREATE_FEE_SAT: u64 = 10_000_000;
/// 100 SAT — fee execuție automată (merge la treasury)
pub const SUB_EXEC_FEE_SAT: u64 = 100;
/// Max note length
pub const NOTE_MAX: usize = 128;
/// Max subscripții per adresă (memory bound)
pub const MAX_SUBS_PER_ADDRESS: usize = 32;

// ── Subscription status ───────────────────────────────────────────────────────

pub const SubStatus = enum(u8) {
    active    = 0,
    cancelled = 1,
    completed = 2, // max_payments atins
};

// ── Subscription struct ───────────────────────────────────────────────────────

pub const Subscription = struct {
    id:              u64,
    from:            [128]u8 = [_]u8{0} ** 128,
    from_len:        u8 = 0,
    to:              [128]u8 = [_]u8{0} ** 128,
    to_len:          u8 = 0,
    amount_sat:      u64,       // SAT per plată
    interval_blocks: u64,       // blocuri între plăți
    max_payments:    u64,       // 0 = infinit
    payments_done:   u64 = 0,
    next_block:      u64,       // block la care se face urm. plată
    status:          SubStatus = .active,
    create_block:    u64 = 0,
    note:            [NOTE_MAX]u8 = [_]u8{0} ** NOTE_MAX,
    note_len:        u8 = 0,

    pub fn fromSlice(self: *const Subscription) []const u8 { return self.from[0..self.from_len]; }
    pub fn toSlice(self: *const Subscription) []const u8 { return self.to[0..self.to_len]; }
    pub fn noteSlice(self: *const Subscription) []const u8 { return self.note[0..self.note_len]; }

    pub fn isActive(self: *const Subscription) bool {
        return self.status == .active;
    }

    pub fn isDue(self: *const Subscription, block_height: u64) bool {
        if (self.status != .active) return false;
        return block_height >= self.next_block;
    }
};

// ── ExecutionResult ───────────────────────────────────────────────────────────

pub const ExecResult = struct {
    sub_id:      u64,
    from:        []const u8,
    to:          []const u8,
    amount_sat:  u64,
    block_height: u64,
    skipped:     bool, // true dacă sender n-a avut fonduri
};

// ── ParsedSubCreate ───────────────────────────────────────────────────────────

pub const ParsedSubCreate = struct {
    to:              []const u8,
    amount_sat:      u64,
    interval_blocks: u64,
    max_payments:    u64,
    note:            []const u8,
};

/// Parse "sub_create:<to>:<amount>:<interval>:<max>[:<note>]"
pub fn parseCreate(op_return: []const u8) ?ParsedSubCreate {
    const PREFIX = "sub_create:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const rest = op_return[PREFIX.len..];
    var it = std.mem.splitScalar(u8, rest, ':');
    const to       = it.next() orelse return null;
    const amt_str  = it.next() orelse return null;
    const ivl_str  = it.next() orelse return null;
    const max_str  = it.next() orelse return null;
    const note     = it.next() orelse "";
    const amount   = std.fmt.parseInt(u64, amt_str, 10) catch return null;
    const interval = std.fmt.parseInt(u64, ivl_str, 10) catch return null;
    const max      = std.fmt.parseInt(u64, max_str, 10) catch return null;
    if (to.len == 0 or amount == 0 or interval == 0) return null;
    return .{ .to = to, .amount_sat = amount, .interval_blocks = interval,
               .max_payments = max, .note = note };
}

/// Parse "sub_cancel:<id>"
pub fn parseCancel(op_return: []const u8) ?u64 {
    const PREFIX = "sub_cancel:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    return std.fmt.parseInt(u64, op_return[PREFIX.len..], 10) catch null;
}

// ── SubscriptionRegistry ──────────────────────────────────────────────────────

pub const SubscriptionRegistry = struct {
    allocator: std.mem.Allocator,
    /// All subscriptions, keyed by id
    subs:      std.AutoHashMap(u64, Subscription),
    /// from_address → list of sub ids (for listing)
    by_from:   std.StringHashMap(array_list.Managed(u64)),
    mutex:     std.Thread.Mutex,
    next_id:   u64,

    pub fn init(allocator: std.mem.Allocator) SubscriptionRegistry {
        return .{
            .allocator = allocator,
            .subs      = std.AutoHashMap(u64, Subscription).init(allocator),
            .by_from   = std.StringHashMap(array_list.Managed(u64)).init(allocator),
            .mutex     = .{},
            .next_id   = 1,
        };
    }

    pub fn deinit(self: *SubscriptionRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.by_from.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.by_from.deinit();
        self.subs.deinit();
    }

    /// Creează o subscripție nouă. Returnează ID-ul.
    pub fn create(
        self:         *SubscriptionRegistry,
        from:         []const u8,
        parsed:       ParsedSubCreate,
        block_height: u64,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var sub = Subscription{
            .id              = id,
            .amount_sat      = parsed.amount_sat,
            .interval_blocks = parsed.interval_blocks,
            .max_payments    = parsed.max_payments,
            .next_block      = block_height + parsed.interval_blocks,
            .create_block    = block_height,
        };

        // Copy from
        const fc = @min(from.len, 127);
        @memcpy(sub.from[0..fc], from[0..fc]);
        sub.from_len = @intCast(fc);

        // Copy to
        const tc = @min(parsed.to.len, 127);
        @memcpy(sub.to[0..tc], parsed.to[0..tc]);
        sub.to_len = @intCast(tc);

        // Copy note
        const nc = @min(parsed.note.len, NOTE_MAX - 1);
        @memcpy(sub.note[0..nc], parsed.note[0..nc]);
        sub.note_len = @intCast(nc);

        try self.subs.put(id, sub);

        // Index by from
        const gop = try self.by_from.getOrPut(from);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, from);
            gop.value_ptr.* = array_list.Managed(u64).init(self.allocator);
        }
        try gop.value_ptr.append(id);

        return id;
    }

    /// Anulează o subscripție (doar owner-ul poate).
    pub fn cancel(self: *SubscriptionRegistry, id: u64, requester: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sub_ptr = self.subs.getPtr(id) orelse return false;
        if (!std.mem.eql(u8, sub_ptr.fromSlice(), requester)) return false;
        if (sub_ptr.status != .active) return false;
        sub_ptr.status = .cancelled;
        return true;
    }

    /// Returnează toate subscripțiile active cu next_block <= block_height.
    /// Caller primeste o slice de IDs — nu tine lock-ul.
    pub fn collectDue(
        self:         *SubscriptionRegistry,
        block_height: u64,
        out:          []u64,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.subs.iterator();
        while (it.next()) |entry| {
            if (n >= out.len) break;
            const sub = entry.value_ptr;
            if (sub.isDue(block_height)) {
                out[n] = sub.id;
                n += 1;
            }
        }
        return n;
    }

    /// Marchează o subscripție ca executată (avansează next_block, incrementează payments_done).
    pub fn markExecuted(self: *SubscriptionRegistry, id: u64, block_height: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sub_ptr = self.subs.getPtr(id) orelse return;
        sub_ptr.payments_done += 1;
        sub_ptr.next_block = block_height + sub_ptr.interval_blocks;
        if (sub_ptr.max_payments > 0 and sub_ptr.payments_done >= sub_ptr.max_payments) {
            sub_ptr.status = .completed;
        }
    }

    /// Returnează o copie a subscripției după ID.
    pub fn get(self: *SubscriptionRegistry, id: u64) ?Subscription {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.subs.get(id);
    }

    /// Listează subscripțiile unui address (active + completed + cancelled).
    pub fn listByFrom(
        self: *SubscriptionRegistry,
        from: []const u8,
        out:  []Subscription,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = self.by_from.get(from) orelse return 0;
        var n: usize = 0;
        for (ids.items) |id| {
            if (n >= out.len) break;
            const sub = self.subs.get(id) orelse continue;
            out[n] = sub;
            n += 1;
        }
        return n;
    }
};
