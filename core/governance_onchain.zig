/// governance_onchain.zig — On-chain governance voting for OmniBus
///
/// Anyone can propose. Voting weight = reputation tier weight:
///   ZEN=1000 > VACATION=500 > RENT=200 > FOOD=100 > LOVE=50 > default=10
///
/// Proposals pass when voting period ends if:
///   yes_weight >= quorum_weight AND yes_weight > no_weight
///
/// op_return formats:
///   "gov_propose:<title_hash>:<voting_blocks>:<quorum>[:<note>]"
///   "gov_vote:<proposal_id>:<yes|no>"
///
/// Fees:
///   GOV_PROPOSE_FEE_SAT = 500_000_000  (0.5 OMNI, anti-spam)
///   GOV_VOTE_FEE_SAT    = 1_000_000    (0.001 OMNI, small but non-zero)

const std = @import("std");
const array_list = std.array_list;

// ── Constants ─────────────────────────────────────────────────────────────────

/// Anti-spam fee to create a proposal (0.5 OMNI in SAT).
pub const GOV_PROPOSE_FEE_SAT: u64 = 500_000_000;
/// Fee to cast a vote (0.001 OMNI in SAT).
pub const GOV_VOTE_FEE_SAT: u64 = 1_000_000;
/// Length of the SHA-256 hex title_hash (64 hex chars).
pub const TITLE_HASH_LEN: usize = 64;
/// Maximum length for the optional proposal note.
pub const NOTE_MAX: usize = 128;
/// Maximum length for an address string (including null terminator space).
pub const ADDR_MAX: usize = 128;
/// Maximum proposals held in memory at once.
pub const MAX_PROPOSALS: usize = 1024;

// ── Tier voting weights ───────────────────────────────────────────────────────

/// Returns the voting weight for a given tier label.
/// Matches: ZEN=1000, VACATION=500, RENT=200, FOOD=100, LOVE=50, default=10.
pub fn tierWeight(tier: []const u8) u32 {
    if (std.mem.eql(u8, tier, "ZEN")) return 1000;
    if (std.mem.eql(u8, tier, "VACATION")) return 500;
    if (std.mem.eql(u8, tier, "RENT")) return 200;
    if (std.mem.eql(u8, tier, "FOOD")) return 100;
    if (std.mem.eql(u8, tier, "LOVE")) return 50;
    return 10;
}

// ── Enums ─────────────────────────────────────────────────────────────────────

pub const ProposalStatus = enum(u8) {
    voting = 0,
    passed = 1,
    rejected = 2,
    expired = 3,
};

// ── Named structs ─────────────────────────────────────────────────────────────

/// A single vote record attached to a proposal.
pub const Vote = struct {
    voter: [ADDR_MAX]u8,
    voter_len: usize,
    weight: u32,
    yes: bool,
    block_height: u64,

    pub fn getVoter(self: *const Vote) []const u8 {
        return self.voter[0..self.voter_len];
    }
};

/// Full proposal record stored in the registry.
pub const Proposal = struct {
    id: u64,
    proposer: [ADDR_MAX]u8,
    proposer_len: usize,
    title_hash: [TITLE_HASH_LEN]u8,
    title_hash_len: usize,
    note: [NOTE_MAX]u8,
    note_len: usize,
    voting_end_block: u64,
    quorum_weight: u32,
    yes_weight: u32,
    no_weight: u32,
    status: ProposalStatus,
    create_block: u64,
    vote_count: u32,

    // ── Slice helpers ────────────────────────────────────────────────────────

    pub fn getProposer(self: *const Proposal) []const u8 {
        return self.proposer[0..self.proposer_len];
    }

    pub fn getTitleHash(self: *const Proposal) []const u8 {
        return self.title_hash[0..self.title_hash_len];
    }

    pub fn getNote(self: *const Proposal) []const u8 {
        return self.note[0..self.note_len];
    }

    /// Human-readable status string.
    pub fn statusStr(self: *const Proposal) []const u8 {
        return switch (self.status) {
            .voting => "voting",
            .passed => "passed",
            .rejected => "rejected",
            .expired => "expired",
        };
    }
};

/// Parsed fields from a "gov_propose:..." op_return.
pub const ParsedPropose = struct {
    title_hash: []const u8,
    voting_blocks: u64,
    quorum: u32,
    note: []const u8,
};

/// Named result type for parseVote — avoids anonymous struct in HashMap context.
pub const ParsedVote = struct {
    id: u64,
    yes: bool,
};

// ── GovernanceRegistry ────────────────────────────────────────────────────────

pub const GovernanceRegistry = struct {
    allocator: std.mem.Allocator,
    /// proposal_id → Proposal
    proposals: std.AutoHashMap(u64, Proposal),
    /// proposal_id → list of Vote records
    votes: std.AutoHashMap(u64, array_list.Managed(Vote)),
    /// "<proposal_id>:<voter>" → void, prevents double-voting
    voted: std.StringHashMap(void),
    mutex: std.Thread.Mutex,
    next_id: u64,

    // ── Lifecycle ────────────────────────────────────────────────────────────

    pub fn init(allocator: std.mem.Allocator) GovernanceRegistry {
        return .{
            .allocator = allocator,
            .proposals = std.AutoHashMap(u64, Proposal).init(allocator),
            .votes = std.AutoHashMap(u64, array_list.Managed(Vote)).init(allocator),
            .voted = std.StringHashMap(void).init(allocator),
            .mutex = .{},
            .next_id = 1,
        };
    }

    pub fn deinit(self: *GovernanceRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free owned keys in `voted` map.
        var vit = self.voted.keyIterator();
        while (vit.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.voted.deinit();

        // Free each Managed(Vote) list in `votes` map.
        var it = self.votes.valueIterator();
        while (it.next()) |list_ptr| {
            list_ptr.deinit();
        }
        self.votes.deinit();

        self.proposals.deinit();
    }

    // ── Public API ───────────────────────────────────────────────────────────

    /// Create a new proposal. Returns the new proposal id.
    pub fn propose(
        self: *GovernanceRegistry,
        proposer: []const u8,
        parsed: ParsedPropose,
        block_height: u64,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.proposals.count() >= MAX_PROPOSALS)
            return error.TooManyProposals;

        var p = std.mem.zeroes(Proposal);
        p.id = self.next_id;
        p.create_block = block_height;
        p.voting_end_block = block_height + parsed.voting_blocks;
        p.quorum_weight = parsed.quorum;
        p.status = .voting;
        p.vote_count = 0;
        p.yes_weight = 0;
        p.no_weight = 0;

        // Copy proposer address.
        {
            const len = @min(proposer.len, ADDR_MAX);
            @memcpy(p.proposer[0..len], proposer[0..len]);
            p.proposer_len = len;
        }

        // Copy title_hash.
        {
            const len = @min(parsed.title_hash.len, TITLE_HASH_LEN);
            @memcpy(p.title_hash[0..len], parsed.title_hash[0..len]);
            p.title_hash_len = len;
        }

        // Copy optional note.
        {
            const len = @min(parsed.note.len, NOTE_MAX);
            @memcpy(p.note[0..len], parsed.note[0..len]);
            p.note_len = len;
        }

        try self.proposals.put(p.id, p);

        // Pre-allocate an empty Vote list for this proposal.
        var vote_list = array_list.Managed(Vote).init(self.allocator);
        errdefer vote_list.deinit();
        try self.votes.put(p.id, vote_list);

        self.next_id += 1;
        return p.id;
    }

    /// Cast a vote on a proposal.
    /// Errors: ProposalNotFound, VotingEnded, AlreadyVoted.
    pub fn vote(
        self: *GovernanceRegistry,
        proposal_id: u64,
        voter: []const u8,
        yes: bool,
        voter_tier: []const u8,
        block_height: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Fetch proposal (mutable).
        const p_ptr = self.proposals.getPtr(proposal_id) orelse
            return error.ProposalNotFound;

        if (block_height > p_ptr.voting_end_block)
            return error.VotingEnded;
        if (p_ptr.status != .voting)
            return error.VotingEnded;

        // Build the double-vote guard key "<proposal_id>:<voter>".
        const key = try std.fmt.allocPrint(self.allocator, "{}:{s}", .{
            proposal_id,
            voter,
        });
        if (self.voted.contains(key)) {
            self.allocator.free(key);
            return error.AlreadyVoted;
        }
        // Insert key (owned — freed in deinit).
        try self.voted.put(key, {});

        // Build the Vote record.
        const weight = tierWeight(voter_tier);
        var v = std.mem.zeroes(Vote);
        {
            const len = @min(voter.len, ADDR_MAX);
            @memcpy(v.voter[0..len], voter[0..len]);
            v.voter_len = len;
        }
        v.weight = weight;
        v.yes = yes;
        v.block_height = block_height;

        // Append to vote list.
        const list_ptr = self.votes.getPtr(proposal_id) orelse
            return error.ProposalNotFound;
        try list_ptr.append(v);

        // Update tallies.
        if (yes) {
            p_ptr.yes_weight +|= weight;
        } else {
            p_ptr.no_weight +|= weight;
        }
        p_ptr.vote_count +|= 1;
    }

    /// Evaluate all proposals whose voting period has ended and mark them
    /// passed, rejected, or expired. Call once per block.
    pub fn finalizeProposals(self: *GovernanceRegistry, current_block: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.proposals.valueIterator();
        while (it.next()) |p_ptr| {
            if (p_ptr.status != .voting) continue;
            if (current_block <= p_ptr.voting_end_block) continue;

            // Voting period has ended — apply result.
            const quorum_met = p_ptr.yes_weight >= p_ptr.quorum_weight;
            const majority = p_ptr.yes_weight > p_ptr.no_weight;

            if (quorum_met and majority) {
                p_ptr.status = .passed;
            } else if (p_ptr.yes_weight == 0 and p_ptr.no_weight == 0) {
                // Nobody voted → expired (no participation).
                p_ptr.status = .expired;
            } else {
                p_ptr.status = .rejected;
            }
        }
    }

    /// Return a copy of a proposal by id, or null if not found.
    pub fn getProposal(self: *GovernanceRegistry, id: u64) ?Proposal {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.proposals.get(id);
    }

    /// Fill `out` with currently-active (status=voting) proposals.
    /// Returns the number written.
    pub fn listActive(self: *GovernanceRegistry, out: []Proposal) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        var it = self.proposals.valueIterator();
        while (it.next()) |p_ptr| {
            if (n >= out.len) break;
            if (p_ptr.status == .voting) {
                out[n] = p_ptr.*;
                n += 1;
            }
        }
        return n;
    }

    /// Fill `out` with all proposals (any status).
    /// Returns the number written.
    pub fn listAll(self: *GovernanceRegistry, out: []Proposal) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var n: usize = 0;
        var it = self.proposals.valueIterator();
        while (it.next()) |p_ptr| {
            if (n >= out.len) break;
            out[n] = p_ptr.*;
            n += 1;
        }
        return n;
    }

    /// Returns the count of proposals currently in `voting` status.
    pub fn activeProposalCount(self: *GovernanceRegistry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.proposals.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.status == .voting) n += 1;
        }
        return n;
    }

    /// Returns the number of proposals that `voter` has voted on.
    pub fn voteCountBy(self: *GovernanceRegistry, voter: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var it = self.voted.keyIterator();
        while (it.next()) |key| {
            // Keys are stored as "<proposal_id>:<voter>"
            if (std.mem.endsWith(u8, key.*, voter)) {
                const suffix_start = key.len - voter.len;
                if (suffix_start > 0 and key.*[suffix_start - 1] == ':') n += 1;
            }
        }
        return n;
    }

    /// Returns true if `voter` has already voted on `proposal_id`.
    pub fn hasVoted(self: *GovernanceRegistry, proposal_id: u64, voter: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Build the key on the stack using a fixed-size buffer.
        var buf: [32 + 1 + ADDR_MAX]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{}:{s}", .{ proposal_id, voter }) catch
            return false;
        return self.voted.contains(key);
    }
};

// ── Parsers ───────────────────────────────────────────────────────────────────

/// Parse a "gov_propose:<title_hash>:<voting_blocks>:<quorum>[:<note>]" op_return.
/// Returns null on any parse failure.
pub fn parsePropose(op_return: []const u8) ?ParsedPropose {
    const prefix = "gov_propose:";
    if (!std.mem.startsWith(u8, op_return, prefix)) return null;
    const body = op_return[prefix.len..];

    // Split into at most 4 fields: title_hash, voting_blocks, quorum, note(optional)
    var it = std.mem.splitScalar(u8, body, ':');

    const title_hash = it.next() orelse return null;
    if (title_hash.len == 0 or title_hash.len > TITLE_HASH_LEN) return null;

    const voting_blocks_str = it.next() orelse return null;
    const voting_blocks = std.fmt.parseInt(u64, voting_blocks_str, 10) catch return null;
    if (voting_blocks == 0) return null;

    const quorum_str = it.next() orelse return null;
    const quorum = std.fmt.parseInt(u32, quorum_str, 10) catch return null;

    // Note is optional — everything after the third colon (may contain colons itself).
    const note: []const u8 = blk: {
        const rest = it.rest();
        if (rest.len == 0) break :blk "";
        if (rest.len > NOTE_MAX) return null;
        break :blk rest;
    };

    return ParsedPropose{
        .title_hash = title_hash,
        .voting_blocks = voting_blocks,
        .quorum = quorum,
        .note = note,
    };
}

/// Parse a "gov_vote:<proposal_id>:<yes|no>" op_return.
/// Returns null on any parse failure.
pub fn parseVote(op_return: []const u8) ?ParsedVote {
    const prefix = "gov_vote:";
    if (!std.mem.startsWith(u8, op_return, prefix)) return null;
    const body = op_return[prefix.len..];

    var it = std.mem.splitScalar(u8, body, ':');

    const id_str = it.next() orelse return null;
    const id = std.fmt.parseInt(u64, id_str, 10) catch return null;

    const vote_str = it.next() orelse return null;
    const yes: bool = blk: {
        if (std.mem.eql(u8, vote_str, "yes")) break :blk true;
        if (std.mem.eql(u8, vote_str, "no")) break :blk false;
        return null;
    };

    return ParsedVote{ .id = id, .yes = yes };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tierWeight — known tiers" {
    try testing.expectEqual(@as(u32, 1000), tierWeight("ZEN"));
    try testing.expectEqual(@as(u32, 500), tierWeight("VACATION"));
    try testing.expectEqual(@as(u32, 200), tierWeight("RENT"));
    try testing.expectEqual(@as(u32, 100), tierWeight("FOOD"));
    try testing.expectEqual(@as(u32, 50), tierWeight("LOVE"));
    try testing.expectEqual(@as(u32, 10), tierWeight(""));
    try testing.expectEqual(@as(u32, 10), tierWeight("unknown"));
}

test "parsePropose — basic (no note)" {
    const op = "gov_propose:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890:100:500";
    const parsed = parsePropose(op) orelse return error.TestFailed;
    try testing.expectEqualSlices(u8, "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890", parsed.title_hash);
    try testing.expectEqual(@as(u64, 100), parsed.voting_blocks);
    try testing.expectEqual(@as(u32, 500), parsed.quorum);
    try testing.expectEqualSlices(u8, "", parsed.note);
}

test "parsePropose — with note" {
    const op = "gov_propose:abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890:200:1000:increase block size";
    const parsed = parsePropose(op) orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 200), parsed.voting_blocks);
    try testing.expectEqual(@as(u32, 1000), parsed.quorum);
    try testing.expectEqualSlices(u8, "increase block size", parsed.note);
}

test "parsePropose — bad prefix returns null" {
    try testing.expectEqual(@as(?ParsedPropose, null), parsePropose("gov_vote:123:yes"));
    try testing.expectEqual(@as(?ParsedPropose, null), parsePropose(""));
}

test "parsePropose — zero voting_blocks returns null" {
    const op = "gov_propose:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:0:100";
    try testing.expectEqual(@as(?ParsedPropose, null), parsePropose(op));
}

test "parseVote — yes" {
    const r = parseVote("gov_vote:42:yes") orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 42), r.id);
    try testing.expect(r.yes);
}

test "parseVote — no" {
    const r = parseVote("gov_vote:7:no") orelse return error.TestFailed;
    try testing.expectEqual(@as(u64, 7), r.id);
    try testing.expect(!r.yes);
}

test "parseVote — bad input returns null" {
    try testing.expectEqual(@as(?ParsedVote, null), parseVote("gov_vote:abc:yes"));
    try testing.expectEqual(@as(?ParsedVote, null), parseVote("gov_vote:1:maybe"));
    try testing.expectEqual(@as(?ParsedVote, null), parseVote("gov_propose:1:yes"));
}

test "GovernanceRegistry — propose and getProposal" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "a" ** TITLE_HASH_LEN,
        .voting_blocks = 100,
        .quorum = 200,
        .note = "test note",
    };
    const id = try reg.propose("ob1proposer", pp, 1000);
    try testing.expectEqual(@as(u64, 1), id);

    const p = reg.getProposal(id) orelse return error.TestFailed;
    try testing.expectEqual(ProposalStatus.voting, p.status);
    try testing.expectEqual(@as(u64, 1100), p.voting_end_block);
    try testing.expectEqual(@as(u32, 200), p.quorum_weight);
    try testing.expectEqualSlices(u8, "test note", p.getNote());
}

test "GovernanceRegistry — vote tallies and double-vote prevention" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "b" ** TITLE_HASH_LEN,
        .voting_blocks = 100,
        .quorum = 50,
        .note = "",
    };
    const id = try reg.propose("ob1alice", pp, 1000);

    // Alice votes yes (VACATION weight=500)
    try reg.vote(id, "ob1alice", true, "VACATION", 1001);
    // Bob votes no (LOVE weight=50)
    try reg.vote(id, "ob1bob", false, "LOVE", 1002);

    const p = reg.getProposal(id) orelse return error.TestFailed;
    try testing.expectEqual(@as(u32, 500), p.yes_weight);
    try testing.expectEqual(@as(u32, 50), p.no_weight);
    try testing.expectEqual(@as(u32, 2), p.vote_count);

    // Alice tries to vote again — must fail.
    try testing.expectError(error.AlreadyVoted, reg.vote(id, "ob1alice", false, "VACATION", 1003));
}

test "GovernanceRegistry — vote on nonexistent proposal fails" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();
    try testing.expectError(error.ProposalNotFound, reg.vote(999, "ob1x", true, "LOVE", 1));
}

test "GovernanceRegistry — vote after period ends fails" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "c" ** TITLE_HASH_LEN,
        .voting_blocks = 10,
        .quorum = 100,
        .note = "",
    };
    const id = try reg.propose("ob1prop", pp, 1000);
    // block_height 1011 > voting_end_block 1010
    try testing.expectError(error.VotingEnded, reg.vote(id, "ob1x", true, "RENT", 1011));
}

test "GovernanceRegistry — finalize passed" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "d" ** TITLE_HASH_LEN,
        .voting_blocks = 100,
        .quorum = 100,
        .note = "",
    };
    const id = try reg.propose("ob1prop", pp, 1000);
    // ZEN voter with weight 1000 → yes_weight=1000 >= quorum=100, yes > no
    try reg.vote(id, "ob1zen", true, "ZEN", 1001);

    reg.finalizeProposals(1101); // voting_end_block = 1100, current = 1101

    const p = reg.getProposal(id) orelse return error.TestFailed;
    try testing.expectEqual(ProposalStatus.passed, p.status);
}

test "GovernanceRegistry — finalize rejected (yes < no)" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "e" ** TITLE_HASH_LEN,
        .voting_blocks = 50,
        .quorum = 1, // low quorum so it isn't expired
        .note = "",
    };
    const id = try reg.propose("ob1prop", pp, 500);
    try reg.vote(id, "ob1a", false, "ZEN", 501);   // no weight=1000
    try reg.vote(id, "ob1b", true, "LOVE", 502);  // yes weight=50

    reg.finalizeProposals(551);

    const p = reg.getProposal(id) orelse return error.TestFailed;
    try testing.expectEqual(ProposalStatus.rejected, p.status);
}

test "GovernanceRegistry — finalize expired (no votes)" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "f" ** TITLE_HASH_LEN,
        .voting_blocks = 50,
        .quorum = 1000,
        .note = "",
    };
    const id = try reg.propose("ob1prop", pp, 500);
    // Nobody votes.
    reg.finalizeProposals(551);

    const p = reg.getProposal(id) orelse return error.TestFailed;
    try testing.expectEqual(ProposalStatus.expired, p.status);
}

test "GovernanceRegistry — hasVoted" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp = ParsedPropose{
        .title_hash = "g" ** TITLE_HASH_LEN,
        .voting_blocks = 100,
        .quorum = 10,
        .note = "",
    };
    const id = try reg.propose("ob1prop", pp, 100);

    try testing.expect(!reg.hasVoted(id, "ob1voter"));
    try reg.vote(id, "ob1voter", true, "FOOD", 101);
    try testing.expect(reg.hasVoted(id, "ob1voter"));
    try testing.expect(!reg.hasVoted(id, "ob1other"));
}

test "GovernanceRegistry — listActive and listAll" {
    var reg = GovernanceRegistry.init(testing.allocator);
    defer reg.deinit();

    const pp1 = ParsedPropose{ .title_hash = "h" ** TITLE_HASH_LEN, .voting_blocks = 100, .quorum = 10, .note = "" };
    const pp2 = ParsedPropose{ .title_hash = "i" ** TITLE_HASH_LEN, .voting_blocks = 5, .quorum = 10, .note = "" };
    _ = try reg.propose("ob1p1", pp1, 1000);
    const id2 = try reg.propose("ob1p2", pp2, 1000);

    // Finalize proposal 2 (ends at block 1005, current 1006).
    reg.finalizeProposals(1006);

    var buf: [MAX_PROPOSALS]Proposal = undefined;
    const active = reg.listActive(&buf);
    try testing.expectEqual(@as(usize, 1), active);

    const all = reg.listAll(&buf);
    try testing.expectEqual(@as(usize, 2), all);

    _ = id2;
}

test "Proposal — statusStr" {
    var p = std.mem.zeroes(Proposal);
    p.status = .voting;
    try testing.expectEqualSlices(u8, "voting", p.statusStr());
    p.status = .passed;
    try testing.expectEqualSlices(u8, "passed", p.statusStr());
    p.status = .rejected;
    try testing.expectEqualSlices(u8, "rejected", p.statusStr());
    p.status = .expired;
    try testing.expectEqualSlices(u8, "expired", p.statusStr());
}
