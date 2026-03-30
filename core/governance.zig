const std = @import("std");
const array_list = std.array_list;

/// On-Chain Governance System for OmniBus
/// Permite token holders sa voteze pe schimbari de protocol:
///   - Parametri economici (UBI rate, fee burn %, block reward)
///   - Upgraduri de protocol (consensus type, block size, difficulty range)
///   - Emergency actions (freeze address, pause bridge)
///
/// Model: Bitcoin-inspired signaling via blocks + explicit voting
/// Inspirat de: Tezos (on-chain governance), Cosmos (proposal/deposit/vote),
///              EGLD (governance staking), Bitcoin BIP9 (version signaling)

/// Tipul propunerii
pub const ProposalType = enum(u8) {
    /// Schimbarea unui parametru numeric (fee_burn_pct, ubi_rate, etc.)
    ParamChange = 1,
    /// Upgrade de protocol (schimba consensus, adauga feature)
    ProtocolUpgrade = 2,
    /// Emergency: freeze, pause, etc.
    Emergency = 3,
    /// Text proposal (non-binding, for signaling/discussion)
    TextSignal = 4,
};

/// Starea unei propuneri
pub const ProposalStatus = enum(u8) {
    /// In perioada de depozit (asteapta quorum de deposit)
    DepositPeriod = 0,
    /// Perioada de vot activa
    VotingActive = 1,
    /// Aprobata (quorum atins + majoritate DA)
    Approved = 2,
    /// Respinsa (quorum atins + majoritate NU)
    Rejected = 3,
    /// Expirata (quorum neatins in timp)
    Expired = 4,
    /// Executata (schimbarea a fost aplicata)
    Executed = 5,
};

/// Un vot pe o propunere
pub const Vote = enum(u8) {
    Yes = 1,
    No = 2,
    Abstain = 3,
    NoWithVeto = 4, // No + propunere sa fie penalizata (Cosmos-style)
};

/// O inregistrare de vot
pub const VoteRecord = struct {
    voter_address: [32]u8,
    vote: Vote,
    /// Puterea de vot (proportionala cu balance-ul)
    voting_power: u64,
    block_height: u64,
};

/// Parametrii guvernantei (configurabili ei insisi prin governance!)
pub const GovernanceParams = struct {
    /// Durata perioadei de depozit (in blocuri)
    deposit_period_blocks: u64 = 100_800, // ~1.17 zile la 1 block/s
    /// Durata perioadei de vot (in blocuri)
    voting_period_blocks: u64 = 604_800, // ~7 zile
    /// Depozit minim pentru a crea o propunere (in SAT)
    min_deposit_sat: u64 = 100_000_000_000, // 100 OMNI
    /// Quorum: procentul minim din total voting power care trebuie sa voteze
    quorum_pct: u8 = 33, // 33%
    /// Threshold: procentul minim de DA din voturile non-Abstain
    threshold_pct: u8 = 50, // >50% = majoritate simpla
    /// Veto threshold: daca > veto_pct voteaza NoWithVeto, propunerea pica
    veto_pct: u8 = 33, // 33% veto = propunere respinsa
    /// Fee burn percentage (0-100), governes de governance
    fee_burn_pct: u8 = 0, // default: 0% (no burn)
};

/// O propunere de governance
pub const Proposal = struct {
    /// ID unic (auto-increment)
    id: u64,
    /// Cine a creat propunerea
    proposer: [32]u8,
    /// Tipul propunerii
    proposal_type: ProposalType,
    /// Titlu scurt (max 64 chars)
    title: [64]u8,
    title_len: u8,
    /// Descriere (max 256 chars)
    description: [256]u8,
    desc_len: u16,
    /// Parametrul care se schimba (pentru ParamChange)
    param_name: [32]u8,
    param_name_len: u8,
    /// Valoarea noua propusa
    param_new_value: u64,
    /// Depozitul total adunat
    deposit_sat: u64,
    /// Blocul la care a fost creata
    created_block: u64,
    /// Blocul la care incepe votul (dupa deposit period)
    voting_start_block: u64,
    /// Blocul la care se termina votul
    voting_end_block: u64,
    /// Starea curenta
    status: ProposalStatus,
    /// Totaluri voturi
    votes_yes: u64,
    votes_no: u64,
    votes_abstain: u64,
    votes_veto: u64,
    /// Total voting power care a votat
    total_voted_power: u64,

    /// Verifica daca propunerea e in perioada de vot
    pub fn isVotingActive(self: *const Proposal, current_block: u64) bool {
        return self.status == .VotingActive and
            current_block >= self.voting_start_block and
            current_block <= self.voting_end_block;
    }

    /// Calculeaza rezultatul final
    pub fn tallyResult(self: *const Proposal, total_voting_power: u64, params: GovernanceParams) ProposalStatus {
        // 1. Check quorum
        if (total_voting_power == 0) return .Expired;
        const quorum_needed = total_voting_power * params.quorum_pct / 100;
        if (self.total_voted_power < quorum_needed) return .Expired;

        // 2. Check veto
        const non_abstain = self.votes_yes + self.votes_no + self.votes_veto;
        if (non_abstain == 0) return .Expired;
        if (self.votes_veto * 100 / non_abstain >= params.veto_pct) return .Rejected;

        // 3. Check threshold (majority of non-abstain votes)
        if (self.votes_yes * 100 / non_abstain > params.threshold_pct) return .Approved;

        return .Rejected;
    }
};

/// Maximum proposals tracked
pub const MAX_PROPOSALS: usize = 256;

/// Governance Engine
pub const GovernanceEngine = struct {
    params: GovernanceParams,
    next_proposal_id: u64,
    proposals: [MAX_PROPOSALS]Proposal,
    proposal_count: usize,

    pub fn init(params: GovernanceParams) GovernanceEngine {
        return .{
            .params = params,
            .next_proposal_id = 1,
            .proposals = undefined,
            .proposal_count = 0,
        };
    }

    /// Creeaza o propunere noua
    pub fn createProposal(
        self: *GovernanceEngine,
        proposer: [32]u8,
        ptype: ProposalType,
        title: []const u8,
        description: []const u8,
        deposit_sat: u64,
        current_block: u64,
    ) !u64 {
        if (self.proposal_count >= MAX_PROPOSALS) return error.TooManyProposals;
        if (deposit_sat < self.params.min_deposit_sat) return error.InsufficientDeposit;

        var proposal: Proposal = std.mem.zeroInit(Proposal, .{
            .proposal_type = ptype,
            .status = .VotingActive,
        });
        proposal.id = self.next_proposal_id;
        proposal.proposer = proposer;
        proposal.deposit_sat = deposit_sat;
        proposal.created_block = current_block;
        proposal.voting_start_block = current_block;
        proposal.voting_end_block = current_block + self.params.voting_period_blocks;

        // Copy title
        const tlen = @min(title.len, 64);
        @memcpy(proposal.title[0..tlen], title[0..tlen]);
        proposal.title_len = @intCast(tlen);

        // Copy description
        const dlen = @min(description.len, 256);
        @memcpy(proposal.description[0..dlen], description[0..dlen]);
        proposal.desc_len = @intCast(dlen);

        self.proposals[self.proposal_count] = proposal;
        self.proposal_count += 1;
        self.next_proposal_id += 1;

        return proposal.id;
    }

    /// Voteaza pe o propunere
    pub fn vote(
        self: *GovernanceEngine,
        proposal_id: u64,
        voter_vote: Vote,
        voting_power: u64,
        current_block: u64,
    ) !void {
        const proposal = self.getProposalMut(proposal_id) orelse return error.ProposalNotFound;

        if (!proposal.isVotingActive(current_block)) return error.VotingNotActive;
        if (voting_power == 0) return error.NoVotingPower;

        switch (voter_vote) {
            .Yes => proposal.votes_yes += voting_power,
            .No => proposal.votes_no += voting_power,
            .Abstain => proposal.votes_abstain += voting_power,
            .NoWithVeto => proposal.votes_veto += voting_power,
        }
        proposal.total_voted_power += voting_power;
    }

    /// Finalizeaza o propunere dupa perioada de vot
    pub fn finalize(
        self: *GovernanceEngine,
        proposal_id: u64,
        total_voting_power: u64,
        current_block: u64,
    ) !ProposalStatus {
        const proposal = self.getProposalMut(proposal_id) orelse return error.ProposalNotFound;

        if (current_block <= proposal.voting_end_block) return error.VotingNotEnded;

        const result = proposal.tallyResult(total_voting_power, self.params);
        proposal.status = result;
        return result;
    }

    /// Get proposal by ID (mutable)
    fn getProposalMut(self: *GovernanceEngine, id: u64) ?*Proposal {
        for (self.proposals[0..self.proposal_count]) |*p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// Get proposal by ID (const)
    pub fn getProposal(self: *const GovernanceEngine, id: u64) ?*const Proposal {
        for (self.proposals[0..self.proposal_count]) |*p| {
            if (p.id == id) return p;
        }
        return null;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "GovernanceEngine — create proposal" {
    var gov = GovernanceEngine.init(GovernanceParams{});
    const proposer = [_]u8{0xAA} ** 32;

    const id = try gov.createProposal(
        proposer, .ParamChange,
        "Increase fee burn to 50%", "Burn 50% of fees like EIP-1559",
        100_000_000_000, // 100 OMNI deposit
        1000, // current block
    );
    try testing.expectEqual(@as(u64, 1), id);
    try testing.expectEqual(@as(usize, 1), gov.proposal_count);
}

test "GovernanceEngine — insufficient deposit fails" {
    var gov = GovernanceEngine.init(GovernanceParams{});
    const proposer = [_]u8{0xBB} ** 32;

    try testing.expectError(error.InsufficientDeposit, gov.createProposal(
        proposer, .TextSignal, "test", "test", 1, 1000,
    ));
}

test "GovernanceEngine — vote Yes/No/Abstain/Veto" {
    var gov = GovernanceEngine.init(GovernanceParams{});
    const proposer = [_]u8{0xCC} ** 32;

    const id = try gov.createProposal(
        proposer, .ParamChange, "test", "test", 100_000_000_000, 1000,
    );

    try gov.vote(id, .Yes, 500, 1001);
    try gov.vote(id, .No, 200, 1002);
    try gov.vote(id, .Abstain, 100, 1003);
    try gov.vote(id, .NoWithVeto, 50, 1004);

    const p = gov.getProposal(id).?;
    try testing.expectEqual(@as(u64, 500), p.votes_yes);
    try testing.expectEqual(@as(u64, 200), p.votes_no);
    try testing.expectEqual(@as(u64, 100), p.votes_abstain);
    try testing.expectEqual(@as(u64, 50), p.votes_veto);
    try testing.expectEqual(@as(u64, 850), p.total_voted_power);
}

test "GovernanceEngine — tally approved (majority yes)" {
    var params = GovernanceParams{};
    params.quorum_pct = 10;
    var gov = GovernanceEngine.init(params);
    const proposer = [_]u8{0xDD} ** 32;

    const id = try gov.createProposal(
        proposer, .ParamChange, "test", "test", 100_000_000_000, 1000,
    );

    try gov.vote(id, .Yes, 700, 1001);
    try gov.vote(id, .No, 300, 1002);

    const total_power: u64 = 10000;
    const voting_end = 1000 + params.voting_period_blocks;
    const result = try gov.finalize(id, total_power, voting_end + 1);
    try testing.expectEqual(ProposalStatus.Approved, result);
}

test "GovernanceEngine — tally rejected (majority no)" {
    var params = GovernanceParams{};
    params.quorum_pct = 10;
    var gov = GovernanceEngine.init(params);
    const proposer = [_]u8{0xEE} ** 32;

    const id = try gov.createProposal(
        proposer, .ParamChange, "test", "test", 100_000_000_000, 1000,
    );

    try gov.vote(id, .Yes, 300, 1001);
    try gov.vote(id, .No, 700, 1002);

    const result = try gov.finalize(id, 10000, 1000 + params.voting_period_blocks + 1);
    try testing.expectEqual(ProposalStatus.Rejected, result);
}

test "GovernanceEngine — veto kills proposal" {
    var params = GovernanceParams{};
    params.quorum_pct = 10;
    var gov = GovernanceEngine.init(params);
    const proposer = [_]u8{0xFF} ** 32;

    const id = try gov.createProposal(
        proposer, .ParamChange, "test", "test", 100_000_000_000, 1000,
    );

    try gov.vote(id, .Yes, 500, 1001);
    try gov.vote(id, .NoWithVeto, 500, 1002); // 50% veto > 33% threshold

    const result = try gov.finalize(id, 10000, 1000 + params.voting_period_blocks + 1);
    try testing.expectEqual(ProposalStatus.Rejected, result);
}

test "GovernanceEngine — expired (no quorum)" {
    var params = GovernanceParams{};
    params.quorum_pct = 50;
    var gov = GovernanceEngine.init(params);
    const proposer = [_]u8{0x11} ** 32;

    const id = try gov.createProposal(
        proposer, .TextSignal, "signal", "test", 100_000_000_000, 1000,
    );

    // Only 1% voting power voted (need 50%)
    try gov.vote(id, .Yes, 100, 1001);

    const result = try gov.finalize(id, 10000, 1000 + params.voting_period_blocks + 1);
    try testing.expectEqual(ProposalStatus.Expired, result);
}

test "GovernanceEngine — cannot finalize before voting ends" {
    var gov = GovernanceEngine.init(GovernanceParams{});
    const proposer = [_]u8{0x22} ** 32;

    const id = try gov.createProposal(
        proposer, .TextSignal, "test", "test", 100_000_000_000, 1000,
    );

    try testing.expectError(error.VotingNotEnded, gov.finalize(id, 10000, 1001));
}

test "GovernanceEngine — vote on nonexistent proposal fails" {
    var gov = GovernanceEngine.init(GovernanceParams{});
    try testing.expectError(error.ProposalNotFound, gov.vote(999, .Yes, 100, 1000));
}

test "GovernanceParams — fee_burn_pct default 0" {
    const params = GovernanceParams{};
    try testing.expectEqual(@as(u8, 0), params.fee_burn_pct);
}
