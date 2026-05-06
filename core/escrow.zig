/// escrow.zig — on-chain programmable escrow protocol.
///
/// Client depune fonduri blocate. Freelancer/furnizor livreaza dovada.
/// Chain elibereaza automat cand proof_hash == condition_hash.
/// Daca timeout_blocks trece fara livrare, fondurile se returneaza la client.
///
/// op_return format:
///   create:  "escrow_create:<to>:<amount_sat>:<condition_hash>:<timeout_blocks>[:<note>]"
///   release: "escrow_release:<escrow_id>:<proof_hash>"
///   refund:  "escrow_refund:<escrow_id>"   (doar dupa timeout, doar client)
///   dispute: "escrow_dispute:<escrow_id>"  (0.5 OMNI fee, deschide arbitraj)
///
/// Fee creare: 0.01 OMNI (anti-spam).
/// Arbitraj: 0.5 OMNI — returnat castigatorului dupa decizie.

const std = @import("std");
const array_list = std.array_list;

// ── Constants ─────────────────────────────────────────────────────────────────

pub const ESCROW_CREATE_FEE_SAT: u64  = 10_000_000;   // 0.01 OMNI
pub const ESCROW_DISPUTE_FEE_SAT: u64 = 500_000_000;  // 0.5 OMNI
pub const HASH_LEN: usize = 64;   // SHA-256 hex
pub const NOTE_MAX: usize  = 128;
pub const ADDR_MAX: usize  = 128;

// ── EscrowStatus ──────────────────────────────────────────────────────────────

pub const EscrowStatus = enum(u8) {
    pending   = 0,  // fonduri blocate, asteapta livrare
    released  = 1,  // proof_hash matched, fonduri la to
    refunded  = 2,  // timeout expirat, fonduri inapoi la from
    disputed  = 3,  // in arbitraj
    resolved  = 4,  // arbitraj rezolvat
};

// ── EscrowEntry ───────────────────────────────────────────────────────────────

pub const EscrowEntry = struct {
    id:               u64,
    from:             [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    from_len:         u8 = 0,
    to:               [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    to_len:           u8 = 0,
    amount_sat:       u64,
    /// SHA-256 hex hash of the expected delivery proof
    condition_hash:   [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    condition_len:    u8 = 0,
    timeout_block:    u64,    // block dupa care refund-ul devine disponibil
    create_block:     u64,
    status:           EscrowStatus = .pending,
    /// proof_hash trimis de to la release
    proof_hash:       [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    proof_len:        u8 = 0,
    release_block:    u64 = 0,
    note:             [NOTE_MAX]u8 = [_]u8{0} ** NOTE_MAX,
    note_len:         u8 = 0,
    tx_hash:          [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    tx_hash_len:      u8 = 0,

    pub fn fromSlice(self: *const EscrowEntry) []const u8 { return self.from[0..self.from_len]; }
    pub fn toSlice(self: *const EscrowEntry) []const u8 { return self.to[0..self.to_len]; }
    pub fn conditionSlice(self: *const EscrowEntry) []const u8 { return self.condition_hash[0..self.condition_len]; }
    pub fn proofSlice(self: *const EscrowEntry) []const u8 { return self.proof_hash[0..self.proof_len]; }
    pub fn noteSlice(self: *const EscrowEntry) []const u8 { return self.note[0..self.note_len]; }
    pub fn txHashSlice(self: *const EscrowEntry) []const u8 { return self.tx_hash[0..self.tx_hash_len]; }

    pub fn statusStr(self: *const EscrowEntry) []const u8 {
        return switch (self.status) {
            .pending  => "pending",
            .released => "released",
            .refunded => "refunded",
            .disputed => "disputed",
            .resolved => "resolved",
        };
    }

    pub fn isTimedOut(self: *const EscrowEntry, current_block: u64) bool {
        return self.status == .pending and current_block >= self.timeout_block;
    }
};

// ── Parsed structs ────────────────────────────────────────────────────────────

pub const ParsedCreate = struct {
    to:             []const u8,
    amount_sat:     u64,
    condition_hash: []const u8,
    timeout_blocks: u64,
    note:           []const u8,
};

pub const ParsedRelease = struct {
    escrow_id:  u64,
    proof_hash: []const u8,
};

/// Parse "escrow_create:<to>:<amount>:<condition_hash>:<timeout>[:<note>]"
pub fn parseCreate(op_return: []const u8) ?ParsedCreate {
    const PREFIX = "escrow_create:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    var it = std.mem.splitScalar(u8, op_return[PREFIX.len..], ':');
    const to        = it.next() orelse return null;
    const amt_str   = it.next() orelse return null;
    const cond_hash = it.next() orelse return null;
    const tmt_str   = it.next() orelse return null;
    const note      = it.next() orelse "";
    const amount    = std.fmt.parseInt(u64, amt_str, 10) catch return null;
    const timeout   = std.fmt.parseInt(u64, tmt_str, 10) catch return null;
    if (to.len == 0 or amount == 0 or timeout == 0) return null;
    if (cond_hash.len != HASH_LEN) return null;
    return .{ .to = to, .amount_sat = amount, .condition_hash = cond_hash,
               .timeout_blocks = timeout, .note = note };
}

/// Parse "escrow_release:<id>:<proof_hash>"
pub fn parseRelease(op_return: []const u8) ?ParsedRelease {
    const PREFIX = "escrow_release:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    var it = std.mem.splitScalar(u8, op_return[PREFIX.len..], ':');
    const id_str    = it.next() orelse return null;
    const proof     = it.next() orelse return null;
    const escrow_id = std.fmt.parseInt(u64, id_str, 10) catch return null;
    if (proof.len != HASH_LEN) return null;
    return .{ .escrow_id = escrow_id, .proof_hash = proof };
}

/// Parse "escrow_refund:<id>"
pub fn parseRefund(op_return: []const u8) ?u64 {
    const PREFIX = "escrow_refund:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    return std.fmt.parseInt(u64, op_return[PREFIX.len..], 10) catch null;
}

/// Parse "escrow_dispute:<id>"
pub fn parseDispute(op_return: []const u8) ?u64 {
    const PREFIX = "escrow_dispute:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    return std.fmt.parseInt(u64, op_return[PREFIX.len..], 10) catch null;
}

// ── EscrowRegistry ────────────────────────────────────────────────────────────

pub const EscrowRegistry = struct {
    allocator: std.mem.Allocator,
    by_id:     std.AutoHashMap(u64, EscrowEntry),
    /// from_address → ids
    by_from:   std.StringHashMap(array_list.Managed(u64)),
    /// to_address → ids
    by_to:     std.StringHashMap(array_list.Managed(u64)),
    mutex:     std.Thread.Mutex,
    next_id:   u64,

    pub fn init(allocator: std.mem.Allocator) EscrowRegistry {
        return .{
            .allocator = allocator,
            .by_id     = std.AutoHashMap(u64, EscrowEntry).init(allocator),
            .by_from   = std.StringHashMap(array_list.Managed(u64)).init(allocator),
            .by_to     = std.StringHashMap(array_list.Managed(u64)).init(allocator),
            .mutex     = .{},
            .next_id   = 1,
        };
    }

    pub fn deinit(self: *EscrowRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        inline for (.{ &self.by_from, &self.by_to }) |map| {
            var it = map.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit();
                self.allocator.free(e.key_ptr.*);
            }
            map.deinit();
        }
        self.by_id.deinit();
    }

    /// Creeaza un escrow nou. Fondurile sunt deja debitate de blockchain.zig.
    pub fn create(
        self:         *EscrowRegistry,
        from:         []const u8,
        parsed:       ParsedCreate,
        block_height: u64,
        tx_hash:      []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var entry = EscrowEntry{
            .id           = id,
            .amount_sat   = parsed.amount_sat,
            .timeout_block = block_height + parsed.timeout_blocks,
            .create_block = block_height,
        };

        const fc = @min(from.len, ADDR_MAX - 1);
        @memcpy(entry.from[0..fc], from[0..fc]);
        entry.from_len = @intCast(fc);

        const tc = @min(parsed.to.len, ADDR_MAX - 1);
        @memcpy(entry.to[0..tc], parsed.to[0..tc]);
        entry.to_len = @intCast(tc);

        const cc = @min(parsed.condition_hash.len, HASH_LEN);
        @memcpy(entry.condition_hash[0..cc], parsed.condition_hash[0..cc]);
        entry.condition_len = @intCast(cc);

        const nc = @min(parsed.note.len, NOTE_MAX - 1);
        @memcpy(entry.note[0..nc], parsed.note[0..nc]);
        entry.note_len = @intCast(nc);

        const thc = @min(tx_hash.len, HASH_LEN);
        @memcpy(entry.tx_hash[0..thc], tx_hash[0..thc]);
        entry.tx_hash_len = @intCast(thc);

        try self.by_id.put(id, entry);

        const from_gop = try self.by_from.getOrPut(from);
        if (!from_gop.found_existing) {
            from_gop.key_ptr.* = try self.allocator.dupe(u8, from);
            from_gop.value_ptr.* = array_list.Managed(u64).init(self.allocator);
        }
        try from_gop.value_ptr.append(id);

        const to_gop = try self.by_to.getOrPut(parsed.to);
        if (!to_gop.found_existing) {
            to_gop.key_ptr.* = try self.allocator.dupe(u8, parsed.to);
            to_gop.value_ptr.* = array_list.Managed(u64).init(self.allocator);
        }
        try to_gop.value_ptr.append(id);

        return id;
    }

    /// Incearca sa elibereze un escrow — proof_hash trebuie sa matching condition_hash.
    /// Returneaza amount_sat daca succes (caller crediteaza to_address), 0 daca fail.
    pub fn tryRelease(
        self:         *EscrowRegistry,
        escrow_id:    u64,
        proof_hash:   []const u8,
        requester:    []const u8,
        block_height: u64,
    ) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.by_id.getPtr(escrow_id) orelse return 0;
        if (ptr.status != .pending) return 0;
        // Doar to_address poate face release
        if (!std.mem.eql(u8, ptr.toSlice(), requester)) return 0;
        // Proof trebuie sa matching condition
        if (!std.mem.eql(u8, ptr.conditionSlice(), proof_hash)) return 0;
        ptr.status = .released;
        ptr.release_block = block_height;
        const pc = @min(proof_hash.len, HASH_LEN);
        @memcpy(ptr.proof_hash[0..pc], proof_hash[0..pc]);
        ptr.proof_len = @intCast(pc);
        return ptr.amount_sat;
    }

    /// Incearca refund dupa timeout — returneaza amount_sat daca succes, 0 daca nu.
    pub fn tryRefund(
        self:         *EscrowRegistry,
        escrow_id:    u64,
        requester:    []const u8,
        block_height: u64,
    ) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.by_id.getPtr(escrow_id) orelse return 0;
        if (ptr.status != .pending) return 0;
        // Doar from_address poate cere refund
        if (!std.mem.eql(u8, ptr.fromSlice(), requester)) return 0;
        // Trebuie sa fi trecut timeout-ul
        if (block_height < ptr.timeout_block) return 0;
        ptr.status = .refunded;
        ptr.release_block = block_height;
        return ptr.amount_sat;
    }

    /// Deschide un dispute pe un escrow pending.
    pub fn openDispute(self: *EscrowRegistry, escrow_id: u64, requester: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.by_id.getPtr(escrow_id) orelse return false;
        if (ptr.status != .pending) return false;
        // Oricare din parti poate deschide dispute
        if (!std.mem.eql(u8, ptr.fromSlice(), requester) and
            !std.mem.eql(u8, ptr.toSlice(), requester)) return false;
        ptr.status = .disputed;
        return true;
    }

    pub fn get(self: *EscrowRegistry, id: u64) ?EscrowEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.by_id.get(id);
    }

    pub fn listByFrom(self: *EscrowRegistry, from: []const u8, out: []EscrowEntry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = self.by_from.get(from) orelse return 0;
        var n: usize = 0;
        var i = ids.items.len;
        while (i > 0 and n < out.len) {
            i -= 1;
            out[n] = self.by_id.get(ids.items[i]) orelse continue;
            n += 1;
        }
        return n;
    }

    pub fn listByTo(self: *EscrowRegistry, to: []const u8, out: []EscrowEntry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = self.by_to.get(to) orelse return 0;
        var n: usize = 0;
        var i = ids.items.len;
        while (i > 0 and n < out.len) {
            i -= 1;
            out[n] = self.by_id.get(ids.items[i]) orelse continue;
            n += 1;
        }
        return n;
    }

    /// Colecteaza escrow-uri care au depasit timeout-ul si sunt inca pending.
    pub fn collectTimedOut(self: *EscrowRegistry, block_height: u64, out: []u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.by_id.iterator();
        while (it.next()) |e| {
            if (n >= out.len) break;
            if (e.value_ptr.isTimedOut(block_height)) {
                out[n] = e.key_ptr.*;
                n += 1;
            }
        }
        return n;
    }
};
