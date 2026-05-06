/// notarize.zig — on-chain document notarization protocol.
///
/// Oricine poate ancora hash-ul unui document pe chain.
/// Dovada de existență: documentul exista la block_height H cu hash SHA-256 H.
/// Verificarea: ia documentul original, hash-uieste-l, compara cu ce e pe chain.
///
/// op_return format:
///   notarize:  "notarize:<sha256_hex>:<doc_type>:<expiry_blocks>[:<note>]"
///   revoke:    "notarize_revoke:<notarize_id>"
///
/// Fee: 0.5 OMNI per notarizare (valoare mare = dovada serioasa).
/// Revoke fee: 0.1 OMNI (optional — marcheaza ca expirat/revocat).
///
/// doc_type catalog:
///   contract, diploma, audit, deed, invoice, kyc, code, media, other

const std = @import("std");
const array_list = std.array_list;

// ── Constants ─────────────────────────────────────────────────────────────────

/// 0.5 OMNI — fee notarizare (1 OMNI = 1_000_000_000 SAT)
pub const NOTARIZE_FEE_SAT: u64 = 500_000_000;
/// 0.1 OMNI — fee revocare
pub const NOTARIZE_REVOKE_FEE_SAT: u64 = 100_000_000;
/// SHA-256 hex = 64 chars
pub const HASH_LEN: usize = 64;
/// Max doc_type length
pub const DOCTYPE_MAX: usize = 32;
/// Max note length
pub const NOTE_MAX: usize = 128;
/// Max owner address length
pub const ADDR_MAX: usize = 128;

// ── DocType catalog ───────────────────────────────────────────────────────────

pub const DocType = enum(u8) {
    contract  = 0,
    diploma   = 1,
    audit     = 2,
    deed      = 3,
    invoice   = 4,
    kyc       = 5,
    code      = 6,
    media     = 7,
    other     = 255,

    _,

    pub fn fromStr(s: []const u8) DocType {
        if (std.mem.eql(u8, s, "contract"))  return .contract;
        if (std.mem.eql(u8, s, "diploma"))   return .diploma;
        if (std.mem.eql(u8, s, "audit"))     return .audit;
        if (std.mem.eql(u8, s, "deed"))      return .deed;
        if (std.mem.eql(u8, s, "invoice"))   return .invoice;
        if (std.mem.eql(u8, s, "kyc"))       return .kyc;
        if (std.mem.eql(u8, s, "code"))      return .code;
        if (std.mem.eql(u8, s, "media"))     return .media;
        return .other;
    }

    pub fn toStr(self: DocType) []const u8 {
        return switch (self) {
            .contract  => "contract",
            .diploma   => "diploma",
            .audit     => "audit",
            .deed      => "deed",
            .invoice   => "invoice",
            .kyc       => "kyc",
            .code      => "code",
            .media     => "media",
            .other     => "other",
            _          => "other",
        };
    }
};

// ── NotarizeEntry ─────────────────────────────────────────────────────────────

pub const NotarizeEntry = struct {
    id:           u64,
    /// SHA-256 hex of the notarized document (64 chars)
    doc_hash:     [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    doc_hash_len: u8 = 0,
    doc_type:     DocType = .other,
    owner:        [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    owner_len:    u8 = 0,
    note:         [NOTE_MAX]u8 = [_]u8{0} ** NOTE_MAX,
    note_len:     u8 = 0,
    block_height: u64,
    tx_hash:      [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    tx_hash_len:  u8 = 0,
    /// 0 = nu expira niciodata
    expiry_block: u64 = 0,
    revoked:      bool = false,

    pub fn docHashSlice(self: *const NotarizeEntry) []const u8 { return self.doc_hash[0..self.doc_hash_len]; }
    pub fn ownerSlice(self: *const NotarizeEntry) []const u8 { return self.owner[0..self.owner_len]; }
    pub fn noteSlice(self: *const NotarizeEntry) []const u8 { return self.note[0..self.note_len]; }
    pub fn txHashSlice(self: *const NotarizeEntry) []const u8 { return self.tx_hash[0..self.tx_hash_len]; }

    pub fn isValid(self: *const NotarizeEntry, current_block: u64) bool {
        if (self.revoked) return false;
        if (self.expiry_block > 0 and current_block > self.expiry_block) return false;
        return true;
    }
};

// ── VerifyResult ──────────────────────────────────────────────────────────────

pub const VerifyStatus = enum { valid, expired, revoked, not_found };

pub const VerifyResult = struct {
    status:       VerifyStatus,
    entry:        ?NotarizeEntry = null,

    pub fn statusStr(self: VerifyResult) []const u8 {
        return switch (self.status) {
            .valid     => "VALID",
            .expired   => "EXPIRED",
            .revoked   => "REVOKED",
            .not_found => "NOT_FOUND",
        };
    }
};

// ── ParsedNotarize ────────────────────────────────────────────────────────────

pub const ParsedNotarize = struct {
    doc_hash:     []const u8,
    doc_type:     DocType,
    expiry_blocks: u64,   // 0 = no expiry
    note:         []const u8,
};

/// Parse "notarize:<sha256>:<doc_type>:<expiry>[:<note>]"
pub fn parsNotarize(op_return: []const u8) ?ParsedNotarize {
    const PREFIX = "notarize:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const rest = op_return[PREFIX.len..];
    var it = std.mem.splitScalar(u8, rest, ':');
    const doc_hash    = it.next() orelse return null;
    const type_str    = it.next() orelse return null;
    const expiry_str  = it.next() orelse "0";
    const note        = it.next() orelse "";
    if (doc_hash.len != HASH_LEN) return null; // must be valid SHA-256 hex
    const expiry = std.fmt.parseInt(u64, expiry_str, 10) catch 0;
    return .{
        .doc_hash      = doc_hash,
        .doc_type      = DocType.fromStr(type_str),
        .expiry_blocks = expiry,
        .note          = note,
    };
}

/// Parse "notarize_revoke:<id>"
pub fn parseRevoke(op_return: []const u8) ?u64 {
    const PREFIX = "notarize_revoke:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    return std.fmt.parseInt(u64, op_return[PREFIX.len..], 10) catch null;
}

// ── NotarizeRegistry ──────────────────────────────────────────────────────────

pub const NotarizeRegistry = struct {
    allocator: std.mem.Allocator,
    /// id → NotarizeEntry
    by_id:     std.AutoHashMap(u64, NotarizeEntry),
    /// doc_hash (hex string) → list of entry ids (same doc can be notarized multiple times)
    by_hash:   std.StringHashMap(array_list.Managed(u64)),
    /// owner address → list of entry ids
    by_owner:  std.StringHashMap(array_list.Managed(u64)),
    mutex:     std.Thread.Mutex,
    next_id:   u64,

    pub fn init(allocator: std.mem.Allocator) NotarizeRegistry {
        return .{
            .allocator = allocator,
            .by_id     = std.AutoHashMap(u64, NotarizeEntry).init(allocator),
            .by_hash   = std.StringHashMap(array_list.Managed(u64)).init(allocator),
            .by_owner  = std.StringHashMap(array_list.Managed(u64)).init(allocator),
            .mutex     = .{},
            .next_id   = 1,
        };
    }

    pub fn deinit(self: *NotarizeRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        {
            var it = self.by_hash.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit();
                self.allocator.free(e.key_ptr.*);
            }
            self.by_hash.deinit();
        }
        {
            var it = self.by_owner.iterator();
            while (it.next()) |e| {
                e.value_ptr.deinit();
                self.allocator.free(e.key_ptr.*);
            }
            self.by_owner.deinit();
        }
        self.by_id.deinit();
    }

    /// Notarizează un document. Returnează ID-ul nou creat.
    pub fn notarize(
        self:         *NotarizeRegistry,
        owner:        []const u8,
        parsed:       ParsedNotarize,
        block_height: u64,
        tx_hash:      []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var entry = NotarizeEntry{
            .id           = id,
            .doc_type     = parsed.doc_type,
            .block_height = block_height,
            .expiry_block = if (parsed.expiry_blocks > 0)
                block_height + parsed.expiry_blocks else 0,
        };

        // Copy doc_hash
        const hc = @min(parsed.doc_hash.len, HASH_LEN);
        @memcpy(entry.doc_hash[0..hc], parsed.doc_hash[0..hc]);
        entry.doc_hash_len = @intCast(hc);

        // Copy owner
        const oc = @min(owner.len, ADDR_MAX - 1);
        @memcpy(entry.owner[0..oc], owner[0..oc]);
        entry.owner_len = @intCast(oc);

        // Copy note
        const nc = @min(parsed.note.len, NOTE_MAX - 1);
        @memcpy(entry.note[0..nc], parsed.note[0..nc]);
        entry.note_len = @intCast(nc);

        // Copy tx_hash
        const tc = @min(tx_hash.len, HASH_LEN);
        @memcpy(entry.tx_hash[0..tc], tx_hash[0..tc]);
        entry.tx_hash_len = @intCast(tc);

        try self.by_id.put(id, entry);

        // Index by hash
        const hash_gop = try self.by_hash.getOrPut(parsed.doc_hash);
        if (!hash_gop.found_existing) {
            hash_gop.key_ptr.* = try self.allocator.dupe(u8, parsed.doc_hash);
            hash_gop.value_ptr.* = array_list.Managed(u64).init(self.allocator);
        }
        try hash_gop.value_ptr.append(id);

        // Index by owner
        const owner_gop = try self.by_owner.getOrPut(owner);
        if (!owner_gop.found_existing) {
            owner_gop.key_ptr.* = try self.allocator.dupe(u8, owner);
            owner_gop.value_ptr.* = array_list.Managed(u64).init(self.allocator);
        }
        try owner_gop.value_ptr.append(id);

        return id;
    }

    /// Revocă o notarizare (doar owner-ul poate).
    pub fn revoke(self: *NotarizeRegistry, id: u64, requester: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry_ptr = self.by_id.getPtr(id) orelse return false;
        if (!std.mem.eql(u8, entry_ptr.ownerSlice(), requester)) return false;
        entry_ptr.revoked = true;
        return true;
    }

    /// Verifică un hash — returnează cel mai recent VerifyResult.
    pub fn verify(self: *NotarizeRegistry, doc_hash: []const u8, current_block: u64) VerifyResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = self.by_hash.get(doc_hash) orelse
            return .{ .status = .not_found };
        // Return most recent (last in list)
        var i = ids.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.by_id.get(ids.items[i]) orelse continue;
            if (entry.revoked) return .{ .status = .revoked, .entry = entry };
            if (entry.expiry_block > 0 and current_block > entry.expiry_block)
                return .{ .status = .expired, .entry = entry };
            return .{ .status = .valid, .entry = entry };
        }
        return .{ .status = .not_found };
    }

    /// Returnează o copie a unui entry după ID.
    pub fn getById(self: *NotarizeRegistry, id: u64) ?NotarizeEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.by_id.get(id);
    }

    /// Lista notarizărilor unui owner (max out.len).
    pub fn listByOwner(
        self:  *NotarizeRegistry,
        owner: []const u8,
        out:   []NotarizeEntry,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = self.by_owner.get(owner) orelse return 0;
        var n: usize = 0;
        var i = ids.items.len;
        // Return newest first
        while (i > 0 and n < out.len) {
            i -= 1;
            const entry = self.by_id.get(ids.items[i]) orelse continue;
            out[n] = entry;
            n += 1;
        }
        return n;
    }
};
