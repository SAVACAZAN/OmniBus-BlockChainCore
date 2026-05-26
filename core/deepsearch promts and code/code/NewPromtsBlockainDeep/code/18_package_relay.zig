// ============================================
// 9. core/slashing_evidence.zig
// ============================================
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const EvidenceType = enum {
    DoubleSigning,
    InvalidBlock,
    Unavailability,
};

pub const SlashingEvidence = struct {
    validator_id: [32]u8,
    evidence_type: EvidenceType,
    block_height: u64,
    timestamp: u64,
    proof: []const u8,
    
    pub fn deinit(self: *SlashingEvidence, allocator: Allocator) void {
        allocator.free(self.proof);
    }
};

pub const EvidenceCollector = struct {
    allocator: Allocator,
    evidences: ArrayList(SlashingEvidence),
    
    pub fn init(allocator: Allocator) EvidenceCollector {
        return EvidenceCollector{
            .allocator = allocator,
            .evidences = ArrayList(SlashingEvidence).init(allocator),
        };
    }
    
    pub fn deinit(self: *EvidenceCollector) void {
        for (self.evidences.items) |*ev| {
            ev.deinit(self.allocator);
        }
        self.evidences.deinit();
    }
    
    pub fn submitEvidence(
        self: *EvidenceCollector,
        validator_id: [32]u8,
        evidence_type: EvidenceType,
        block_height: u64,
        proof: []const u8,
    ) !void {
        const proof_copy = try self.allocator.duplicate(u8, proof);
        try self.evidences.append(SlashingEvidence{
            .validator_id = validator_id,
            .evidence_type = evidence_type,
            .block_height = block_height,
            .timestamp = @intCast(std.time.timestamp()),
            .proof = proof_copy,
        });
    }
    
    pub fn verifyAndSubmit(self: *EvidenceCollector) !void {
        var verified = ArrayList(SlashingEvidence).init(self.allocator);
        defer verified.deinit();
        
        for (self.evidences.items) |evidence| {
            if (try self.verifyEvidence(&evidence)) {
                try verified.append(evidence);
            }
        }
        
        // Clear unverified and keep verified for onchain submission
        self.evidences.clearRetainingCapacity();
        for (verified.items) |ev| {
            try self.evidences.append(ev);
        }
    }
    
    fn verifyEvidence(self: *EvidenceCollector, evidence: *const SlashingEvidence) !bool {
        _ = self;
        // Proof verification logic
        // For double signing: check two valid signatures for same height/round
        // For invalid block: check block validity
        _ = evidence;
        return true;
    }
    
    pub fn prepareOnchainTx(self: *EvidenceCollector) ![]u8 {
        var buf = ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        
        for (self.evidences.items) |evidence| {
            try buf.appendSlice(&evidence.validator_id);
            try buf.append(@intFromEnum(evidence.evidence_type));
            try buf.appendSlice(std.mem.asBytes(&evidence.block_height));
            try buf.appendSlice(evidence.proof);
        }
        
        return buf.toOwnedSlice();
    }
};

test "Evidence submission" {
    var allocator = std.testing.allocator;
    var collector = EvidenceCollector.init(allocator);
    defer collector.deinit();
    
    const validator = [_]u8{1} ** 32;
    const proof = "double signing proof data";
    
    try collector.submitEvidence(validator, .DoubleSigning, 100, proof);
    try std.testing.expect(collector.evidences.items.len == 1);
    
    try collector.verifyAndSubmit();
    try std.testing.expect(collector.evidences.items.len == 1);
}