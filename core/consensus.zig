const std = @import("std");
const block_mod  = @import("block.zig");
const array_list = std.array_list;

pub const Block = block_mod.Block;

/// Tipul de consens — schimbabil fara sa afecteze trecutul
pub const ConsensusType = enum {
    /// Proof of Work simplu (default, compatibil cu codul existent)
    ProofOfWork,
    /// Majority vote — 50%+1 validatori (faza 2)
    MajorityVote,
    /// PBFT complet — 2f+1 din N (faza 3)
    PBFT,
};

/// Starea unui validator in runda curenta
pub const ValidatorVote = struct {
    validator_id: u16,
    block_hash:   [32]u8,
    approved:     bool,
    timestamp_ms: i64,
};

/// Configuratia consensului — independenta de blockchain
pub const ConsensusConfig = struct {
    consensus_type:   ConsensusType,
    /// Numarul total de validatori in shard
    total_validators: u16,
    /// Timeout per runda in ms (0.1s pentru micro-blocks)
    round_timeout_ms: u32,
    /// Minimul de voturi necesare (calculat automat din tipul consensului)
    min_votes:        u16,

    pub fn init(ctype: ConsensusType, total_validators: u16) ConsensusConfig {
        const min_votes: u16 = switch (ctype) {
            .ProofOfWork  => 1,          // PoW: un singur miner
            .MajorityVote => total_validators / 2 + 1, // >50%
            .PBFT         => 2 * (total_validators / 3) + 1, // 2f+1
        };
        return .{
            .consensus_type   = ctype,
            .total_validators = total_validators,
            .round_timeout_ms = 100, // 0.1s — micro-block timeout
            .min_votes        = min_votes,
        };
    }

    /// Tolereanta la Byzantine faults (noduri care mint)
    pub fn byzantineTolerance(self: *const ConsensusConfig) u16 {
        return switch (self.consensus_type) {
            .ProofOfWork  => 0,
            .MajorityVote => (self.total_validators - 1) / 2,
            .PBFT         => (self.total_validators - 1) / 3,
        };
    }

    pub fn print(self: *const ConsensusConfig) void {
        std.debug.print(
            "[CONSENSUS] Type={s} | Validators={d} | MinVotes={d} | ByzTolerance={d}\n",
            .{
                @tagName(self.consensus_type),
                self.total_validators,
                self.min_votes,
                self.byzantineTolerance(),
            },
        );
    }
};

/// Runda de consens pentru un bloc/micro-bloc
pub const ConsensusRound = struct {
    config:       ConsensusConfig,
    block_hash:   [32]u8,
    votes:        array_list.Managed(ValidatorVote),
    started_at:   i64,
    finalized:    bool,
    allocator:    std.mem.Allocator,

    pub fn init(
        config:     ConsensusConfig,
        block_hash: [32]u8,
        allocator:  std.mem.Allocator,
    ) ConsensusRound {
        return .{
            .config     = config,
            .block_hash = block_hash,
            .votes      = array_list.Managed(ValidatorVote).init(allocator),
            .started_at = std.time.milliTimestamp(),
            .finalized  = false,
            .allocator  = allocator,
        };
    }

    pub fn deinit(self: *ConsensusRound) void {
        self.votes.deinit();
    }

    /// Adauga votul unui validator
    /// Returneaza true daca votul a atins quorum-ul si runda e finalizata
    pub fn addVote(self: *ConsensusRound, vote: ValidatorVote) !bool {
        if (self.finalized) return true;

        // Verifica sa nu voteze de doua ori (Byzantine double-vote)
        for (self.votes.items) |existing| {
            if (existing.validator_id == vote.validator_id) {
                // Vot duplicat — ignorat (nu panic, doar skip)
                return false;
            }
        }

        try self.votes.append(vote);

        // Verifica quorum
        if (self.countApproved() >= self.config.min_votes) {
            self.finalized = true;
            return true;
        }

        return false;
    }

    /// Numara voturile de aprobare pentru hash-ul curent
    pub fn countApproved(self: *const ConsensusRound) u16 {
        var count: u16 = 0;
        for (self.votes.items) |v| {
            if (v.approved and std.mem.eql(u8, &v.block_hash, &self.block_hash)) {
                count += 1;
            }
        }
        return count;
    }

    /// Verifica daca runda a expirat (timeout)
    pub fn isTimedOut(self: *const ConsensusRound) bool {
        const elapsed = std.time.milliTimestamp() - self.started_at;
        return elapsed > self.config.round_timeout_ms;
    }

    /// Rezultatul rundei
    pub const Result = enum { Approved, Rejected, Timeout, Pending };

    pub fn getResult(self: *const ConsensusRound) Result {
        if (self.finalized) return .Approved;
        if (self.isTimedOut()) {
            // La timeout: daca avem macar min_votes, aprobat
            if (self.countApproved() >= self.config.min_votes) return .Approved;
            return .Timeout;
        }
        // Verificam daca e imposibil sa ajungem la quorum
        const remaining_validators =
            self.config.total_validators - @as(u16, @intCast(self.votes.items.len));
        const max_possible = self.countApproved() + remaining_validators;
        if (max_possible < self.config.min_votes) return .Rejected;
        return .Pending;
    }
};

/// Motor de consens simplu — orchestreaza rundele
/// Modular: poate fi inlocuit cu PBFT complet fara sa schimbe blockchain.zig
pub const ConsensusEngine = struct {
    config:   ConsensusConfig,
    allocator: std.mem.Allocator,

    pub fn init(config: ConsensusConfig, allocator: std.mem.Allocator) ConsensusEngine {
        return .{ .config = config, .allocator = allocator };
    }

    /// Creeaza o noua runda de consens pentru un bloc
    pub fn newRound(self: *const ConsensusEngine, block_hash: [32]u8) ConsensusRound {
        return ConsensusRound.init(self.config, block_hash, self.allocator);
    }

    /// Verifica daca un bloc poate fi acceptat in mod PoW
    /// (compatibil cu codul existent din blockchain.zig)
    pub fn validatePoW(self: *const ConsensusEngine, hash: []const u8) bool {
        _ = self;
        // Verifica leading zeros (dificultatea e in blockchain.zig)
        var zeros: u32 = 0;
        for (hash) |c| {
            if (c == '0') zeros += 1 else break;
        }
        return zeros >= 1; // minim 1 zero — blockchain.zig are dificultatea reala
    }

    /// Quick check: hash-ul unui bloc e valid pentru consensul curent?
    pub fn isBlockHashValid(self: *const ConsensusEngine, hash: []const u8, difficulty: u32) bool {
        _ = self;
        if (hash.len == 0) return false;
        var zeros: u32 = 0;
        for (hash) |c| {
            if (c == '0') zeros += 1 else break;
        }
        return zeros >= difficulty;
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ConsensusConfig ProofOfWork — 1 validator necesar" {
    const cfg = ConsensusConfig.init(.ProofOfWork, 1);
    try testing.expectEqual(@as(u16, 1), cfg.min_votes);
    try testing.expectEqual(@as(u16, 0), cfg.byzantineTolerance());
}

test "ConsensusConfig MajorityVote — quorum >50%" {
    const cfg = ConsensusConfig.init(.MajorityVote, 7);
    try testing.expectEqual(@as(u16, 4), cfg.min_votes); // 7/2+1 = 4
    try testing.expectEqual(@as(u16, 3), cfg.byzantineTolerance());
}

test "ConsensusConfig PBFT — quorum 2f+1" {
    const cfg = ConsensusConfig.init(.PBFT, 7);
    try testing.expectEqual(@as(u16, 5), cfg.min_votes); // 2*(7/3)+1 = 5
    try testing.expectEqual(@as(u16, 2), cfg.byzantineTolerance()); // f=2
}

test "ConsensusRound — quorum atins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cfg = ConsensusConfig.init(.MajorityVote, 5); // min 3 voturi
    const hash: [32]u8 = @splat(0xAB);
    var round = ConsensusRound.init(cfg, hash, arena.allocator());
    defer round.deinit();

    // 2 voturi — insuficient
    _ = try round.addVote(.{ .validator_id = 1, .block_hash = hash, .approved = true, .timestamp_ms = 0 });
    _ = try round.addVote(.{ .validator_id = 2, .block_hash = hash, .approved = true, .timestamp_ms = 0 });
    try testing.expect(!round.finalized);
    try testing.expectEqual(ConsensusRound.Result.Pending, round.getResult());

    // Al 3-lea vot — quorum atins
    const finalized = try round.addVote(.{ .validator_id = 3, .block_hash = hash, .approved = true, .timestamp_ms = 0 });
    try testing.expect(finalized);
    try testing.expect(round.finalized);
    try testing.expectEqual(ConsensusRound.Result.Approved, round.getResult());
}

test "ConsensusRound — vot duplicat ignorat" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cfg = ConsensusConfig.init(.MajorityVote, 3);
    const hash: [32]u8 = @splat(0x11);
    var round = ConsensusRound.init(cfg, hash, arena.allocator());
    defer round.deinit();

    _ = try round.addVote(.{ .validator_id = 1, .block_hash = hash, .approved = true, .timestamp_ms = 0 });
    _ = try round.addVote(.{ .validator_id = 1, .block_hash = hash, .approved = true, .timestamp_ms = 0 }); // duplicat
    try testing.expectEqual(@as(usize, 1), round.votes.items.len); // doar 1
}

test "ConsensusRound — vot rejectat daca hash diferit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cfg = ConsensusConfig.init(.MajorityVote, 3);
    const hash: [32]u8 = @splat(0xAA);
    var round = ConsensusRound.init(cfg, hash, arena.allocator());
    defer round.deinit();

    const bad_hash: [32]u8 = @splat(0xBB); // hash diferit = vot invalid
    _ = try round.addVote(.{ .validator_id = 1, .block_hash = bad_hash, .approved = true, .timestamp_ms = 0 });
    _ = try round.addVote(.{ .validator_id = 2, .block_hash = bad_hash, .approved = true, .timestamp_ms = 0 });

    try testing.expectEqual(@as(u16, 0), round.countApproved()); // 0 aprobate pentru hash-ul corect
}

test "ConsensusEngine — isBlockHashValid" {
    const cfg = ConsensusConfig.init(.ProofOfWork, 1);
    const engine = ConsensusEngine.init(cfg, testing.allocator);

    try testing.expect(engine.isBlockHashValid("0000abcd", 4));
    try testing.expect(!engine.isBlockHashValid("000abcd", 4)); // doar 3 zerouri
    try testing.expect(!engine.isBlockHashValid("", 1));
}
