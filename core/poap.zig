/// poap.zig — Proof of Attendance Protocol for OmniBus blockchain.
///
/// POAPs are soulbound tokens — non-transferable badges proving that a wallet
/// attended (or participated in) a specific event. Once minted to a holder
/// address, the badge cannot be transferred.
///
/// op_return formats:
///   create:  "poap_event:<event_id>:<name>:<max_claims>[:<note>]"
///            — organizer creates event (fee: 1 OMNI)
///   claim:   "poap_claim:<event_id>"
///            — attendee claims POAP (fee: 0.01 OMNI, within claim window)
///   close:   "poap_close:<event_id>"
///            — organizer closes event early

const std = @import("std");
const array_list = std.array_list;

// ── Constants ─────────────────────────────────────────────────────────────────

pub const POAP_EVENT_FEE_SAT: u64 = 1_000_000_000; // 1 OMNI
pub const POAP_CLAIM_FEE_SAT: u64 = 10_000_000;    // 0.01 OMNI

pub const EVENT_ID_MAX: usize = 32;
pub const NAME_MAX: usize     = 64;
pub const NOTE_MAX: usize     = 128;
pub const ADDR_MAX: usize     = 128;

// ── PoapEvent ─────────────────────────────────────────────────────────────────

pub const PoapEvent = struct {
    id:            u64,

    event_id:      [EVENT_ID_MAX]u8 = [_]u8{0} ** EVENT_ID_MAX,
    event_id_len:  u8 = 0,

    name:          [NAME_MAX]u8 = [_]u8{0} ** NAME_MAX,
    name_len:      u8 = 0,

    organizer:     [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    organizer_len: u8 = 0,

    /// 0 = unlimited
    max_claims:    u64,
    claims_count:  u64 = 0,
    create_block:  u64,
    closed:        bool = false,

    note:          [NOTE_MAX]u8 = [_]u8{0} ** NOTE_MAX,
    note_len:      u8 = 0,

    pub fn eventIdSlice(self: *const PoapEvent) []const u8 {
        return self.event_id[0..self.event_id_len];
    }
    pub fn nameSlice(self: *const PoapEvent) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn organizerSlice(self: *const PoapEvent) []const u8 {
        return self.organizer[0..self.organizer_len];
    }
    pub fn noteSlice(self: *const PoapEvent) []const u8 {
        return self.note[0..self.note_len];
    }

    pub fn isOpen(self: *const PoapEvent) bool {
        if (self.closed) return false;
        if (self.max_claims == 0) return true;
        return self.claims_count < self.max_claims;
    }
};

// ── PoapClaim ─────────────────────────────────────────────────────────────────

pub const PoapClaim = struct {
    holder:        [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    holder_len:    u8 = 0,

    event_id:      [EVENT_ID_MAX]u8 = [_]u8{0} ** EVENT_ID_MAX,
    event_id_len:  u8 = 0,

    claim_block:   u64,

    tx_hash:       [64]u8 = [_]u8{0} ** 64,
    tx_hash_len:   u8 = 0,

    pub fn holderSlice(self: *const PoapClaim) []const u8 {
        return self.holder[0..self.holder_len];
    }
    pub fn eventIdSlice(self: *const PoapClaim) []const u8 {
        return self.event_id[0..self.event_id_len];
    }
    pub fn txHashSlice(self: *const PoapClaim) []const u8 {
        return self.tx_hash[0..self.tx_hash_len];
    }
};

// ── Parsed structs ────────────────────────────────────────────────────────────

pub const ParsedEvent = struct {
    event_id:   []const u8,
    name:       []const u8,
    max_claims: u64,
    note:       []const u8,
};

// ── PoapRegistry ──────────────────────────────────────────────────────────────

pub const PoapRegistry = struct {
    allocator:    std.mem.Allocator,
    /// event_id → PoapEvent
    events:       std.StringHashMap(PoapEvent),
    /// holder_address → list of PoapClaim (all POAPs for that wallet)
    claims:       std.StringHashMap(array_list.Managed(PoapClaim)),
    /// "event_id:holder" → 1  (dedup guard — prevents double-claiming)
    event_claims: std.StringHashMap(u64),
    mutex:        std.Thread.Mutex,
    next_id:      u64,

    pub fn init(allocator: std.mem.Allocator) PoapRegistry {
        return .{
            .allocator    = allocator,
            .events       = std.StringHashMap(PoapEvent).init(allocator),
            .claims       = std.StringHashMap(array_list.Managed(PoapClaim)).init(allocator),
            .event_claims = std.StringHashMap(u64).init(allocator),
            .mutex        = .{},
            .next_id      = 1,
        };
    }

    pub fn deinit(self: *PoapRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free event map (keys are owned dupes)
        {
            var it = self.events.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            self.events.deinit();
        }

        // Free claims map (keys owned, values are Managed lists)
        {
            var it = self.claims.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit();
                self.allocator.free(e.key_ptr.*);
            }
            self.claims.deinit();
        }

        // Free event_claims map (keys owned)
        {
            var it = self.event_claims.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            self.event_claims.deinit();
        }
    }

    /// Create a new POAP event. Called when the chain processes a
    /// "poap_event:…" op_return with the required fee.
    pub fn createEvent(
        self:         *PoapRegistry,
        organizer:    []const u8,
        parsed:       ParsedEvent,
        block_height: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var ev = PoapEvent{
            .id           = id,
            .max_claims   = parsed.max_claims,
            .create_block = block_height,
        };

        // event_id
        const eid_c = @min(parsed.event_id.len, EVENT_ID_MAX - 1);
        @memcpy(ev.event_id[0..eid_c], parsed.event_id[0..eid_c]);
        ev.event_id_len = @intCast(eid_c);

        // name
        const nc = @min(parsed.name.len, NAME_MAX - 1);
        @memcpy(ev.name[0..nc], parsed.name[0..nc]);
        ev.name_len = @intCast(nc);

        // organizer
        const oc = @min(organizer.len, ADDR_MAX - 1);
        @memcpy(ev.organizer[0..oc], organizer[0..oc]);
        ev.organizer_len = @intCast(oc);

        // note
        const notec = @min(parsed.note.len, NOTE_MAX - 1);
        @memcpy(ev.note[0..notec], parsed.note[0..notec]);
        ev.note_len = @intCast(notec);

        // Insert — key is an owned dupe of event_id
        const gop = try self.events.getOrPut(parsed.event_id);
        if (gop.found_existing) {
            // Event ID already registered — silently ignore (caller should check first)
            return;
        }
        gop.key_ptr.* = try self.allocator.dupe(u8, parsed.event_id);
        gop.value_ptr.* = ev;
    }

    /// Claim a POAP badge for `holder` on `event_id`.
    /// Errors:
    ///   error.EventNotFound       — event_id unknown
    ///   error.EventClosed         — organizer closed it or max_claims reached
    ///   error.AlreadyClaimed      — holder already has this POAP
    pub fn claimPoap(
        self:         *PoapRegistry,
        holder:       []const u8,
        event_id:     []const u8,
        block_height: u64,
        tx_hash:      []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Verify event exists
        const ev_ptr = self.events.getPtr(event_id) orelse return error.EventNotFound;

        // Verify event is open
        if (!ev_ptr.isOpen()) return error.EventClosed;

        // Build dedup key "event_id:holder"
        var dedup_buf: [EVENT_ID_MAX + 1 + ADDR_MAX]u8 = undefined;
        const dedup_key = try std.fmt.bufPrint(&dedup_buf, "{s}:{s}", .{ event_id, holder });

        // Check not already claimed
        if (self.event_claims.contains(dedup_key)) return error.AlreadyClaimed;

        // Build claim struct
        var claim = PoapClaim{
            .claim_block = block_height,
        };

        const hc = @min(holder.len, ADDR_MAX - 1);
        @memcpy(claim.holder[0..hc], holder[0..hc]);
        claim.holder_len = @intCast(hc);

        const eidc = @min(event_id.len, EVENT_ID_MAX - 1);
        @memcpy(claim.event_id[0..eidc], event_id[0..eidc]);
        claim.event_id_len = @intCast(eidc);

        const thc = @min(tx_hash.len, 63);
        @memcpy(claim.tx_hash[0..thc], tx_hash[0..thc]);
        claim.tx_hash_len = @intCast(thc);

        // Insert into holder's claim list
        const cgop = try self.claims.getOrPut(holder);
        if (!cgop.found_existing) {
            cgop.key_ptr.* = try self.allocator.dupe(u8, holder);
            cgop.value_ptr.* = array_list.Managed(PoapClaim).init(self.allocator);
        }
        try cgop.value_ptr.append(claim);

        // Register dedup key (value = 1, unused sentinel)
        const owned_dedup = try self.allocator.dupe(u8, dedup_key);
        errdefer self.allocator.free(owned_dedup);
        try self.event_claims.put(owned_dedup, 1);

        // Increment event counter
        ev_ptr.claims_count += 1;
    }

    /// Return a copy of the event, or null if not found.
    pub fn getEvent(self: *PoapRegistry, event_id: []const u8) ?PoapEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.get(event_id);
    }

    /// Fill `out` with all POAP claims for `holder`. Returns count written.
    pub fn listClaims(
        self:   *PoapRegistry,
        holder: []const u8,
        out:    []PoapClaim,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.claims.get(holder) orelse return 0;
        var n: usize = 0;
        for (list.items) |c| {
            if (n >= out.len) break;
            out[n] = c;
            n += 1;
        }
        return n;
    }

    /// Returns true if `holder` has already claimed `event_id`.
    pub fn hasClaimed(self: *PoapRegistry, holder: []const u8, event_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var buf: [EVENT_ID_MAX + 1 + ADDR_MAX]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ event_id, holder }) catch return false;
        return self.event_claims.contains(key);
    }

    /// Returns the number of claims on an event (0 if event unknown).
    pub fn claimCount(self: *PoapRegistry, event_id: []const u8) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ev = self.events.get(event_id) orelse return 0;
        return ev.claims_count;
    }

    /// Returns the number of POAPs claimed by a holder across all events.
    pub fn claimCountByHolder(self: *PoapRegistry, holder: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.event_claims.keyIterator();
        while (it.next()) |key| {
            // Keys are stored as "event_id:holder"
            if (std.mem.endsWith(u8, key.*, holder)) {
                // Confirm it's exactly ":holder" suffix, not a partial match
                const suffix_start = key.len - holder.len;
                if (suffix_start > 0 and key.*[suffix_start - 1] == ':') n += 1;
            }
        }
        return n;
    }

    /// Close an event early. Only the organizer can do this.
    /// Returns true on success, false if not found or wrong organizer.
    pub fn closeEvent(self: *PoapRegistry, event_id: []const u8, organizer: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.events.getPtr(event_id) orelse return false;
        if (!std.mem.eql(u8, ptr.organizerSlice(), organizer)) return false;
        ptr.closed = true;
        return true;
    }
};

// ── op_return parsing ─────────────────────────────────────────────────────────

/// Parse "poap_event:<event_id>:<name>:<max_claims>[:<note>]"
/// Returns ParsedEvent with slices into `op_return`. Caller must not
/// free op_return while the result is in use.
pub fn parseEvent(op_return: []const u8) ?ParsedEvent {
    const PREFIX = "poap_event:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    var it = std.mem.splitScalar(u8, op_return[PREFIX.len..], ':');

    const event_id = it.next() orelse return null;
    if (event_id.len == 0 or event_id.len > EVENT_ID_MAX) return null;

    const name = it.next() orelse return null;
    if (name.len == 0 or name.len > NAME_MAX) return null;

    const max_str = it.next() orelse return null;
    const max_claims = std.fmt.parseInt(u64, max_str, 10) catch return null;

    const note = it.next() orelse "";

    return .{
        .event_id   = event_id,
        .name       = name,
        .max_claims = max_claims,
        .note       = note,
    };
}

/// Parse "poap_claim:<event_id>"
/// Returns a slice into `op_return` for the event_id portion.
pub fn parseClaim(op_return: []const u8) ?[]const u8 {
    const PREFIX = "poap_claim:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const event_id = op_return[PREFIX.len..];
    if (event_id.len == 0 or event_id.len > EVENT_ID_MAX) return null;
    return event_id;
}

/// Parse "poap_close:<event_id>"
/// Returns a slice into `op_return` for the event_id portion.
pub fn parseClose(op_return: []const u8) ?[]const u8 {
    const PREFIX = "poap_close:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const event_id = op_return[PREFIX.len..];
    if (event_id.len == 0 or event_id.len > EVENT_ID_MAX) return null;
    return event_id;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parseEvent basic" {
    const parsed = parseEvent("poap_event:summit2026:OmniBus Summit:100:Annual gathering").?;
    try std.testing.expectEqualStrings("summit2026", parsed.event_id);
    try std.testing.expectEqualStrings("OmniBus Summit", parsed.name);
    try std.testing.expectEqual(@as(u64, 100), parsed.max_claims);
    try std.testing.expectEqualStrings("Annual gathering", parsed.note);
}

test "parseEvent no note" {
    const parsed = parseEvent("poap_event:demo:Demo Event:0").?;
    try std.testing.expectEqualStrings("demo", parsed.event_id);
    try std.testing.expectEqual(@as(u64, 0), parsed.max_claims);
    try std.testing.expectEqualStrings("", parsed.note);
}

test "parseEvent invalid" {
    try std.testing.expect(parseEvent("poap_claim:foo") == null);
    try std.testing.expect(parseEvent("poap_event:") == null);
    try std.testing.expect(parseEvent("poap_event:id:name:notanumber") == null);
}

test "parseClaim" {
    const eid = parseClaim("poap_claim:summit2026").?;
    try std.testing.expectEqualStrings("summit2026", eid);
    try std.testing.expect(parseClaim("poap_event:x") == null);
    try std.testing.expect(parseClaim("poap_claim:") == null);
}

test "parseClose" {
    const eid = parseClose("poap_close:summit2026").?;
    try std.testing.expectEqualStrings("summit2026", eid);
    try std.testing.expect(parseClose("poap_claim:x") == null);
}

test "PoapRegistry create and claim" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = PoapRegistry.init(alloc);
    defer reg.deinit();

    const parsed = ParsedEvent{
        .event_id   = "hack2026",
        .name       = "Hackathon 2026",
        .max_claims = 3,
        .note       = "First OmniBus hackathon",
    };

    try reg.createEvent("ob1organizer", parsed, 1000);

    const ev = reg.getEvent("hack2026").?;
    try std.testing.expectEqualStrings("Hackathon 2026", ev.nameSlice());
    try std.testing.expectEqual(@as(u64, 3), ev.max_claims);
    try std.testing.expect(ev.isOpen());

    try reg.claimPoap("ob1alice", "hack2026", 1001, "aaaa");
    try reg.claimPoap("ob1bob",   "hack2026", 1002, "bbbb");
    try reg.claimPoap("ob1carol", "hack2026", 1003, "cccc");

    try std.testing.expectEqual(@as(u64, 3), reg.claimCount("hack2026"));
    try std.testing.expect(reg.hasClaimed("ob1alice", "hack2026"));
    try std.testing.expect(!reg.hasClaimed("ob1dave", "hack2026"));

    // Fourth claim should fail — max reached
    try std.testing.expectError(error.EventClosed, reg.claimPoap("ob1dave", "hack2026", 1004, "dddd"));

    // Double-claim by alice should fail
    try std.testing.expectError(error.AlreadyClaimed, reg.claimPoap("ob1alice", "hack2026", 1005, "eeee"));
}

test "PoapRegistry listClaims" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = PoapRegistry.init(alloc);
    defer reg.deinit();

    const ev1 = ParsedEvent{ .event_id = "evt1", .name = "Event 1", .max_claims = 0, .note = "" };
    const ev2 = ParsedEvent{ .event_id = "evt2", .name = "Event 2", .max_claims = 0, .note = "" };
    try reg.createEvent("ob1org", ev1, 1);
    try reg.createEvent("ob1org", ev2, 2);

    try reg.claimPoap("ob1user", "evt1", 10, "tx1");
    try reg.claimPoap("ob1user", "evt2", 11, "tx2");

    var buf: [8]PoapClaim = undefined;
    const n = reg.listClaims("ob1user", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "PoapRegistry closeEvent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var reg = PoapRegistry.init(alloc);
    defer reg.deinit();

    const parsed = ParsedEvent{ .event_id = "closeme", .name = "Close Me", .max_claims = 100, .note = "" };
    try reg.createEvent("ob1organizer", parsed, 500);

    // Wrong organizer cannot close
    try std.testing.expect(!reg.closeEvent("closeme", "ob1stranger"));

    // Right organizer can close
    try std.testing.expect(reg.closeEvent("closeme", "ob1organizer"));

    // After close, claims fail
    try std.testing.expectError(error.EventClosed, reg.claimPoap("ob1user", "closeme", 501, "tx"));
}

test "PoapRegistry unknown event" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var reg = PoapRegistry.init(gpa.allocator());
    defer reg.deinit();

    try std.testing.expectError(error.EventNotFound, reg.claimPoap("ob1user", "noexist", 1, "tx"));
    try std.testing.expect(reg.getEvent("noexist") == null);
    try std.testing.expectEqual(@as(u64, 0), reg.claimCount("noexist"));
    try std.testing.expect(!reg.hasClaimed("ob1user", "noexist"));
}
