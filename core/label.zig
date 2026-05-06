/// label.zig — on-chain address labeling protocol.
///
/// Oricine poate eticheta orice adresă. Credibilitatea etichetei =
/// reputația celui care o aplică (tier-based weight). Decentralizat,
/// verificabil, permanent pe chain.
///
/// op_return format:
///   label_apply:  "label:<target>:<tag>:<note_optional>"
///   label_remove: "label_remove:<label_id>"
///
/// Fee: 0.1 OMNI per label_apply (anti-spam).
/// Dispute: 0.5 OMNI — dacă câștigi îți returnezi.

const std = @import("std");
const array_list = std.array_list;

// ── Tag catalogue ────────────────────────────────────────────────────────────

pub const Tag = enum(u8) {
    // Pozitive
    verified       = 0,
    exchange       = 1,
    agent          = 2,
    liquidity      = 3,
    miner          = 4,
    validator      = 5,
    kyc_passed     = 6,
    bridge         = 7,
    oracle         = 8,
    // Neutre
    contract       = 20,
    institution    = 21,
    fund           = 22,
    cold_storage   = 23,
    dev            = 24,
    // Negative
    suspicious     = 40,
    scam           = 41,
    rug_pull       = 42,
    hacked         = 43,
    sanctioned     = 44,
    honeypot       = 45,
    blacklist      = 46,

    _,

    pub fn fromStr(s: []const u8) ?Tag {
        const map = .{
            .{ "verified",     Tag.verified },
            .{ "exchange",     Tag.exchange },
            .{ "agent",        Tag.agent },
            .{ "liquidity",    Tag.liquidity },
            .{ "miner",        Tag.miner },
            .{ "validator",    Tag.validator },
            .{ "kyc_passed",   Tag.kyc_passed },
            .{ "bridge",       Tag.bridge },
            .{ "oracle",       Tag.oracle },
            .{ "contract",     Tag.contract },
            .{ "institution",  Tag.institution },
            .{ "fund",         Tag.fund },
            .{ "cold_storage", Tag.cold_storage },
            .{ "dev",          Tag.dev },
            .{ "suspicious",   Tag.suspicious },
            .{ "scam",         Tag.scam },
            .{ "rug_pull",     Tag.rug_pull },
            .{ "hacked",       Tag.hacked },
            .{ "sanctioned",   Tag.sanctioned },
            .{ "honeypot",     Tag.honeypot },
            .{ "blacklist",    Tag.blacklist },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }

    pub fn toStr(self: Tag) []const u8 {
        return switch (self) {
            .verified    => "verified",
            .exchange    => "exchange",
            .agent       => "agent",
            .liquidity   => "liquidity",
            .miner       => "miner",
            .validator   => "validator",
            .kyc_passed  => "kyc_passed",
            .bridge      => "bridge",
            .oracle      => "oracle",
            .contract    => "contract",
            .institution => "institution",
            .fund        => "fund",
            .cold_storage => "cold_storage",
            .dev         => "dev",
            .suspicious  => "suspicious",
            .scam        => "scam",
            .rug_pull    => "rug_pull",
            .hacked      => "hacked",
            .sanctioned  => "sanctioned",
            .honeypot    => "honeypot",
            .blacklist   => "blacklist",
            _            => "unknown",
        };
    }

    pub fn isNegative(self: Tag) bool {
        return @intFromEnum(self) >= 40;
    }

    pub fn isPositive(self: Tag) bool {
        return @intFromEnum(self) < 20;
    }
};

// ── Tier weights ─────────────────────────────────────────────────────────────
// Matching reputation.zig Tier enum order.

pub fn tierWeight(tier_str: []const u8) u32 {
    if (std.mem.eql(u8, tier_str, "ZEN"))      return 1000;
    if (std.mem.eql(u8, tier_str, "VACATION")) return 500;
    if (std.mem.eql(u8, tier_str, "RENT"))     return 200;
    if (std.mem.eql(u8, tier_str, "FOOD"))     return 100;
    if (std.mem.eql(u8, tier_str, "LOVE"))     return 50;
    return 10; // OMNI tier default
}

// ── LabelEntry ───────────────────────────────────────────────────────────────

pub const NOTE_MAX = 128;
pub const ADDR_MAX = 128;
pub const MAX_LABELS_PER_ADDRESS = 64;

pub const LabelEntry = struct {
    id:            u64,                       // unique ID (timestamp_ms + index)
    target:        [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    target_len:    u8 = 0,
    reporter:      [ADDR_MAX]u8 = [_]u8{0} ** ADDR_MAX,
    reporter_len:  u8 = 0,
    tag:           Tag,
    note:          [NOTE_MAX]u8 = [_]u8{0} ** NOTE_MAX,
    note_len:      u8 = 0,
    weight:        u32,                       // tierWeight(reporter_tier) la momentul aplicării
    block_height:  u64,
    tx_hash:       [64]u8 = [_]u8{0} ** 64,
    tx_hash_len:   u8 = 0,
    removed:       bool = false,

    pub fn targetSlice(self: *const LabelEntry) []const u8 { return self.target[0..self.target_len]; }
    pub fn reporterSlice(self: *const LabelEntry) []const u8 { return self.reporter[0..self.reporter_len]; }
    pub fn noteSlice(self: *const LabelEntry) []const u8 { return self.note[0..self.note_len]; }
    pub fn txHashSlice(self: *const LabelEntry) []const u8 { return self.tx_hash[0..self.tx_hash_len]; }
};

// ── AddressVerdict ────────────────────────────────────────────────────────────

pub const Verdict = enum { safe, caution, danger, unknown };

pub const AddressReport = struct {
    positive_score: u32 = 0,
    negative_score: u32 = 0,
    top_tag:        ?Tag = null,
    top_weight:     u32 = 0,
    label_count:    u32 = 0,

    pub fn verdict(self: AddressReport) Verdict {
        if (self.label_count == 0) return .unknown;
        if (self.negative_score >= 500) return .danger;
        if (self.negative_score >= 100) return .caution;
        if (self.negative_score > 0 and self.negative_score >= self.positive_score) return .caution;
        if (self.positive_score >= 200) return .safe;
        return .unknown;
    }

    pub fn verdictStr(self: AddressReport) []const u8 {
        return switch (self.verdict()) {
            .safe    => "SAFE",
            .caution => "CAUTION",
            .danger  => "DANGER",
            .unknown => "UNKNOWN",
        };
    }
};

// ── ById entry (named type avoids anonymous-struct uniqueness issues) ─────────

const ByIdEntry = struct { addr: []const u8, idx: usize };

// ── LabelRegistry ─────────────────────────────────────────────────────────────

pub const LabelRegistry = struct {
    allocator: std.mem.Allocator,
    /// address → list of LabelEntry
    labels:    std.StringHashMap(array_list.Managed(LabelEntry)),
    /// id → ByIdEntry pentru lookup rapid la remove
    by_id:     std.AutoHashMap(u64, ByIdEntry),
    mutex:     std.Thread.Mutex,
    next_id:   u64,

    pub fn init(allocator: std.mem.Allocator) LabelRegistry {
        return .{
            .allocator = allocator,
            .labels    = std.StringHashMap(array_list.Managed(LabelEntry)).init(allocator),
            .by_id     = std.AutoHashMap(u64, ByIdEntry).init(allocator),
            .mutex     = .{},
            .next_id   = 1,
        };
    }

    pub fn deinit(self: *LabelRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.labels.deinit();
        self.by_id.deinit();
    }

    /// Aplică o etichetă. Returnează ID-ul nou creat sau eroare.
    pub fn apply(
        self:         *LabelRegistry,
        target:       []const u8,
        reporter:     []const u8,
        tag:          Tag,
        note:         []const u8,
        reporter_tier: []const u8,
        block_height: u64,
        tx_hash:      []const u8,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id += 1;

        var entry = LabelEntry{
            .id           = id,
            .tag          = tag,
            .weight       = tierWeight(reporter_tier),
            .block_height = block_height,
            .removed      = false,
        };

        // Copy target
        const tc = @min(target.len, ADDR_MAX - 1);
        @memcpy(entry.target[0..tc], target[0..tc]);
        entry.target_len = @intCast(tc);

        // Copy reporter
        const rc = @min(reporter.len, ADDR_MAX - 1);
        @memcpy(entry.reporter[0..rc], reporter[0..rc]);
        entry.reporter_len = @intCast(rc);

        // Copy note
        const nc = @min(note.len, NOTE_MAX - 1);
        @memcpy(entry.note[0..nc], note[0..nc]);
        entry.note_len = @intCast(nc);

        // Copy tx_hash
        const hc = @min(tx_hash.len, 63);
        @memcpy(entry.tx_hash[0..hc], tx_hash[0..hc]);
        entry.tx_hash_len = @intCast(hc);

        // Get or create list for target
        const gop = try self.labels.getOrPut(target);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, target);
            gop.value_ptr.* = array_list.Managed(LabelEntry).init(self.allocator);
        }
        const idx = gop.value_ptr.items.len;
        try gop.value_ptr.append(entry);

        // Index by id
        try self.by_id.put(id, .{ .addr = gop.key_ptr.*, .idx = idx });

        return id;
    }

    /// Marchează o etichetă ca removed (doar reporter-ul o poate remove).
    pub fn remove(self: *LabelRegistry, id: u64, requester: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ptr = self.by_id.get(id) orelse return false;
        const list = self.labels.getPtr(ptr.addr) orelse return false;
        if (ptr.idx >= list.items.len) return false;
        const entry = &list.items[ptr.idx];
        // Doar reporter-ul poate remove
        if (!std.mem.eql(u8, entry.reporterSlice(), requester)) return false;
        entry.removed = true;
        return true;
    }

    /// Calculează raportul pentru o adresă.
    pub fn report(self: *LabelRegistry, target: []const u8) AddressReport {
        self.mutex.lock();
        defer self.mutex.unlock();
        var r = AddressReport{};
        const list = self.labels.get(target) orelse return r;
        for (list.items) |entry| {
            if (entry.removed) continue;
            r.label_count += 1;
            if (entry.tag.isNegative()) {
                r.negative_score += entry.weight;
            } else if (entry.tag.isPositive()) {
                r.positive_score += entry.weight;
            }
            if (entry.weight > r.top_weight) {
                r.top_weight = entry.weight;
                r.top_tag = entry.tag;
            }
        }
        return r;
    }

    /// Returnează toate etichetele active pentru o adresă (max 64).
    pub fn listActive(
        self:   *LabelRegistry,
        target: []const u8,
        out:    []LabelEntry,
    ) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = self.labels.get(target) orelse return 0;
        var n: usize = 0;
        for (list.items) |entry| {
            if (entry.removed) continue;
            if (n >= out.len) break;
            out[n] = entry;
            n += 1;
        }
        return n;
    }
};

// ── op_return parsing ─────────────────────────────────────────────────────────

pub const ParsedLabel = struct {
    target: []const u8,
    tag:    Tag,
    note:   []const u8,
};

/// Parse "label:<target>:<tag>[:<note>]" din op_return.
pub fn parseApply(op_return: []const u8) ?ParsedLabel {
    const PREFIX = "label:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const rest = op_return[PREFIX.len..];
    var it = std.mem.splitScalar(u8, rest, ':');
    const target = it.next() orelse return null;
    const tag_str = it.next() orelse return null;
    const tag = Tag.fromStr(tag_str) orelse return null;
    const note = it.next() orelse "";
    return .{ .target = target, .tag = tag, .note = note };
}

/// Parse "label_remove:<id>" din op_return.
pub fn parseRemove(op_return: []const u8) ?u64 {
    const PREFIX = "label_remove:";
    if (!std.mem.startsWith(u8, op_return, PREFIX)) return null;
    const id_str = op_return[PREFIX.len..];
    return std.fmt.parseInt(u64, id_str, 10) catch null;
}

// ── Minimum fee ───────────────────────────────────────────────────────────────

/// 0.1 OMNI în SAT (1 OMNI = 1_000_000_000 SAT)
pub const LABEL_FEE_SAT: u64 = 100_000_000;
/// 0.5 OMNI pentru dispute
pub const LABEL_DISPUTE_FEE_SAT: u64 = 500_000_000;
