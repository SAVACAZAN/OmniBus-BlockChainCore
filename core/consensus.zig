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

// ─── PBFT autentic (3 faze + view-change) ───────────────────────────────────
//
// Diferenta fata de ConsensusRound (single-quorum):
//   - PrePrepare: leader (primary) propune blocul cu numar de secventa n
//   - Prepare:    fiecare replica verifica + multicast Prepare. La 2f+1
//                 Prepare-uri concordante (acelasi hash + n + view) replica
//                 intra in starea "prepared".
//   - Commit:     fiecare replica prepared multicast Commit. La 2f+1
//                 Commit-uri concordante, replica intra "committed" si
//                 executa blocul. Finalitate stricta — nicio replica
//                 corecta nu poate executa un alt bloc la aceeasi pozitie.
//   - View-change: daca primary nu trimite PrePrepare in timeout, replicile
//                  cer NEW-VIEW si avanseaza view-ul; primary devine
//                  (view % total_validators).
//
// Modelul: f = (n-1)/3 falsi tolerati, n = total_validators.

pub const PbftPhase = enum {
    Idle,
    PrePrepared,
    Prepared,
    Committed,
    ViewChanging,
};

pub const PbftMsgKind = enum { PrePrepare, Prepare, Commit, ViewChange, NewView };

pub const PbftMessage = struct {
    kind:         PbftMsgKind,
    view:         u32,
    seq:          u64,
    block_hash:   [32]u8,
    validator_id: u16,
    timestamp_ms: i64,
};

/// O instanta PBFT pe o secventa (block height). Una per (view, seq).
pub const PbftInstance = struct {
    config:       ConsensusConfig,
    view:         u32,
    seq:          u64,
    block_hash:   [32]u8,
    phase:        PbftPhase,
    pre_prepare:  ?PbftMessage,
    prepares:     array_list.Managed(PbftMessage),
    commits:      array_list.Managed(PbftMessage),
    view_changes: array_list.Managed(PbftMessage),
    started_at:   i64,
    allocator:    std.mem.Allocator,

    pub fn init(
        config:     ConsensusConfig,
        view:       u32,
        seq:        u64,
        block_hash: [32]u8,
        allocator:  std.mem.Allocator,
    ) PbftInstance {
        return .{
            .config       = config,
            .view         = view,
            .seq          = seq,
            .block_hash   = block_hash,
            .phase        = .Idle,
            .pre_prepare  = null,
            .prepares     = array_list.Managed(PbftMessage).init(allocator),
            .commits      = array_list.Managed(PbftMessage).init(allocator),
            .view_changes = array_list.Managed(PbftMessage).init(allocator),
            .started_at   = std.time.milliTimestamp(),
            .allocator    = allocator,
        };
    }

    pub fn deinit(self: *PbftInstance) void {
        self.prepares.deinit();
        self.commits.deinit();
        self.view_changes.deinit();
    }

    /// Cine e primary in view-ul curent. Round-robin pe validatori.
    pub fn primaryId(self: *const PbftInstance) u16 {
        if (self.config.total_validators == 0) return 0;
        return @intCast(self.view % @as(u32, self.config.total_validators));
    }

    /// Quorum-ul: 2f+1 din N. Folosim formula din ConsensusConfig.PBFT.
    pub fn quorum(self: *const PbftInstance) u16 {
        return 2 * (self.config.total_validators / 3) + 1;
    }

    /// PrePrepare: doar primary-ul poate trimite. Returneaza eroare daca alt
    /// validator incearca, sau daca am primit deja un PrePrepare diferit
    /// pentru aceeasi (view, seq) — semn de Byzantine primary.
    pub fn onPrePrepare(self: *PbftInstance, msg: PbftMessage) !void {
        if (msg.kind != .PrePrepare) return error.WrongKind;
        if (msg.view != self.view or msg.seq != self.seq) return error.OutOfOrder;
        if (msg.validator_id != self.primaryId()) return error.NotPrimary;

        if (self.pre_prepare) |existing| {
            // Acelasi primary, dubla propunere — Byzantine. Refuzam silentios.
            if (!std.mem.eql(u8, &existing.block_hash, &msg.block_hash)) {
                return error.ByzantinePrimary;
            }
            return; // duplicat benign
        }
        self.pre_prepare = msg;
        self.block_hash  = msg.block_hash;
        if (self.phase == .Idle) self.phase = .PrePrepared;
    }

    fn hasFromValidator(
        list: *const array_list.Managed(PbftMessage),
        validator_id: u16,
    ) bool {
        for (list.items) |m| {
            if (m.validator_id == validator_id) return true;
        }
        return false;
    }

    /// Prepare de la o replica. Trecem in `Prepared` cand avem 2f+1 Prepare-uri
    /// distincte cu acelasi hash si view, INCLUSIV implicit cel al primary-ului
    /// (PrePrepare conteaza ca un Prepare).
    pub fn onPrepare(self: *PbftInstance, msg: PbftMessage) !bool {
        if (msg.kind != .Prepare) return error.WrongKind;
        if (msg.view != self.view or msg.seq != self.seq) return error.OutOfOrder;
        if (!std.mem.eql(u8, &msg.block_hash, &self.block_hash)) return error.HashMismatch;
        if (hasFromValidator(&self.prepares, msg.validator_id)) return false; // duplicat

        try self.prepares.append(msg);

        // PrePrepare conteaza ca Prepare implicit al primary-ului
        const total: u16 = blk: {
            var n: u16 = @intCast(self.prepares.items.len);
            if (self.pre_prepare) |pp| {
                if (!hasFromValidator(&self.prepares, pp.validator_id)) n += 1;
            }
            break :blk n;
        };

        if (total >= self.quorum() and self.phase == .PrePrepared) {
            self.phase = .Prepared;
            return true;
        }
        return false;
    }

    /// Commit de la o replica. Trecem in `Committed` la 2f+1 Commit-uri
    /// concordante. Asta e finalitate stricta — blocul nu mai poate fi
    /// inlocuit prin nicio combinatie de view-change-uri.
    pub fn onCommit(self: *PbftInstance, msg: PbftMessage) !bool {
        if (msg.kind != .Commit) return error.WrongKind;
        if (msg.view != self.view or msg.seq != self.seq) return error.OutOfOrder;
        if (!std.mem.eql(u8, &msg.block_hash, &self.block_hash)) return error.HashMismatch;
        if (self.phase != .Prepared and self.phase != .Committed) return false;
        if (hasFromValidator(&self.commits, msg.validator_id)) return false;

        try self.commits.append(msg);

        if (self.commits.items.len >= self.quorum() and self.phase == .Prepared) {
            self.phase = .Committed;
            return true;
        }
        return false;
    }

    /// View-change: o replica nu a primit PrePrepare in timeout. Cere
    /// avansarea view-ului. La 2f+1 ViewChange-uri concordante (acelasi
    /// view nou), instanta e gata sa accepte NEW-VIEW de la noul primary.
    pub fn onViewChange(self: *PbftInstance, msg: PbftMessage) !bool {
        if (msg.kind != .ViewChange) return error.WrongKind;
        if (msg.view <= self.view) return error.StaleView;
        if (hasFromValidator(&self.view_changes, msg.validator_id)) return false;

        try self.view_changes.append(msg);
        self.phase = .ViewChanging;

        // Numaram doar ViewChange-uri pentru ACELASI view nou cerut
        var count: u16 = 0;
        const target_view = msg.view;
        for (self.view_changes.items) |vc| {
            if (vc.view == target_view) count += 1;
        }
        if (count >= self.quorum()) {
            // Avans la noul view; resetam stadiile de propunere
            self.view        = target_view;
            self.pre_prepare = null;
            self.prepares.clearRetainingCapacity();
            self.commits.clearRetainingCapacity();
            self.view_changes.clearRetainingCapacity();
            self.phase       = .Idle;
            self.started_at  = std.time.milliTimestamp();
            return true;
        }
        return false;
    }

    /// True daca am ramas in Idle/PrePrepared peste round_timeout_ms.
    /// Folosit de wrapper-ul de mai sus ca sa emita ViewChange.
    pub fn shouldViewChange(self: *const PbftInstance) bool {
        if (self.phase == .Committed) return false;
        const elapsed = std.time.milliTimestamp() - self.started_at;
        return elapsed > self.config.round_timeout_ms;
    }

    pub fn isCommitted(self: *const PbftInstance) bool {
        return self.phase == .Committed;
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

test "PBFT primaryId — round-robin pe view" {
    const cfg = ConsensusConfig.init(.PBFT, 4);
    var p = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer p.deinit();
    try testing.expectEqual(@as(u16, 0), p.primaryId());
    p.view = 1; try testing.expectEqual(@as(u16, 1), p.primaryId());
    p.view = 5; try testing.expectEqual(@as(u16, 1), p.primaryId());
}

test "PBFT 3 faze fericite — 4 validatori, 1 Byzantine tolerat" {
    const cfg = ConsensusConfig.init(.PBFT, 4); // f=1, quorum=3
    const h: [32]u8 = @splat(0xAA);
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();

    // 1. PrePrepare de la primary (id=0, view=0)
    try inst.onPrePrepare(.{
        .kind = .PrePrepare, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 0, .timestamp_ms = 0,
    });
    try testing.expectEqual(PbftPhase.PrePrepared, inst.phase);

    // 2. Prepare-uri: 2 in plus + 1 implicit de la primary = 3 = quorum
    const ready1 = try inst.onPrepare(.{
        .kind = .Prepare, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 1, .timestamp_ms = 0,
    });
    try testing.expect(!ready1); // doar 2 echivalent (1 + PP), inca nu quorum
    const ready2 = try inst.onPrepare(.{
        .kind = .Prepare, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 2, .timestamp_ms = 0,
    });
    try testing.expect(ready2);
    try testing.expectEqual(PbftPhase.Prepared, inst.phase);

    // 3. Commits: 3 distincte = quorum
    _ = try inst.onCommit(.{
        .kind = .Commit, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 0, .timestamp_ms = 0,
    });
    _ = try inst.onCommit(.{
        .kind = .Commit, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 1, .timestamp_ms = 0,
    });
    const committed = try inst.onCommit(.{
        .kind = .Commit, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 2, .timestamp_ms = 0,
    });
    try testing.expect(committed);
    try testing.expect(inst.isCommitted());
}

test "PBFT Prepare cu hash gresit — respins" {
    const cfg = ConsensusConfig.init(.PBFT, 4);
    const h: [32]u8 = @splat(0xAA);
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();
    try inst.onPrePrepare(.{
        .kind = .PrePrepare, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 0, .timestamp_ms = 0,
    });
    const bad: [32]u8 = @splat(0xBB);
    try testing.expectError(error.HashMismatch, inst.onPrepare(.{
        .kind = .Prepare, .view = 0, .seq = 1,
        .block_hash = bad, .validator_id = 1, .timestamp_ms = 0,
    }));
}

test "PBFT Byzantine primary — 2 PrePrepare-uri diferite" {
    const cfg = ConsensusConfig.init(.PBFT, 4);
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();
    try inst.onPrePrepare(.{
        .kind = .PrePrepare, .view = 0, .seq = 1,
        .block_hash = @splat(0xAA), .validator_id = 0, .timestamp_ms = 0,
    });
    try testing.expectError(error.ByzantinePrimary, inst.onPrePrepare(.{
        .kind = .PrePrepare, .view = 0, .seq = 1,
        .block_hash = @splat(0xBB), .validator_id = 0, .timestamp_ms = 0,
    }));
}

test "PBFT non-primary nu poate trimite PrePrepare" {
    const cfg = ConsensusConfig.init(.PBFT, 4);
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();
    try testing.expectError(error.NotPrimary, inst.onPrePrepare(.{
        .kind = .PrePrepare, .view = 0, .seq = 1,
        .block_hash = @splat(0xAA), .validator_id = 2, .timestamp_ms = 0,
    }));
}

test "PBFT view-change — 2f+1 ViewChange-uri avanseaza view-ul" {
    const cfg = ConsensusConfig.init(.PBFT, 4); // quorum=3
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();

    _ = try inst.onViewChange(.{
        .kind = .ViewChange, .view = 1, .seq = 1,
        .block_hash = @splat(0), .validator_id = 1, .timestamp_ms = 0,
    });
    _ = try inst.onViewChange(.{
        .kind = .ViewChange, .view = 1, .seq = 1,
        .block_hash = @splat(0), .validator_id = 2, .timestamp_ms = 0,
    });
    try testing.expectEqual(PbftPhase.ViewChanging, inst.phase);
    const advanced = try inst.onViewChange(.{
        .kind = .ViewChange, .view = 1, .seq = 1,
        .block_hash = @splat(0), .validator_id = 3, .timestamp_ms = 0,
    });
    try testing.expect(advanced);
    try testing.expectEqual(@as(u32, 1), inst.view);
    try testing.expectEqual(@as(u16, 1), inst.primaryId());
    try testing.expectEqual(PbftPhase.Idle, inst.phase);
}

test "PBFT view-change stale respins" {
    const cfg = ConsensusConfig.init(.PBFT, 4);
    var inst = PbftInstance.init(cfg, 2, 1, @splat(0), testing.allocator);
    defer inst.deinit();
    try testing.expectError(error.StaleView, inst.onViewChange(.{
        .kind = .ViewChange, .view = 1, .seq = 1, // <= current
        .block_hash = @splat(0), .validator_id = 1, .timestamp_ms = 0,
    }));
}

test "PBFT shouldViewChange dupa timeout" {
    var cfg = ConsensusConfig.init(.PBFT, 4);
    cfg.round_timeout_ms = 0; // expirat instant
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    try testing.expect(inst.shouldViewChange());
}

test "PBFT Commit fara Prepared — refuzat" {
    const cfg = ConsensusConfig.init(.PBFT, 4);
    const h: [32]u8 = @splat(0xAA);
    var inst = PbftInstance.init(cfg, 0, 1, @splat(0), testing.allocator);
    defer inst.deinit();
    try inst.onPrePrepare(.{
        .kind = .PrePrepare, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 0, .timestamp_ms = 0,
    });
    // Phase = PrePrepared, dar nu am ajuns la Prepared inca → commit ignorat
    const ok = try inst.onCommit(.{
        .kind = .Commit, .view = 0, .seq = 1,
        .block_hash = h, .validator_id = 1, .timestamp_ms = 0,
    });
    try testing.expect(!ok);
    try testing.expect(!inst.isCommitted());
}

test "ConsensusEngine — isBlockHashValid" {
    const cfg = ConsensusConfig.init(.ProofOfWork, 1);
    const engine = ConsensusEngine.init(cfg, testing.allocator);

    try testing.expect(engine.isBlockHashValid("0000abcd", 4));
    try testing.expect(!engine.isBlockHashValid("000abcd", 4)); // doar 3 zerouri
    try testing.expect(!engine.isBlockHashValid("", 1));
}
