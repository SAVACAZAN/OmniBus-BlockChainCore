//! Slashing evidence collector pentru validatori OmniBus.
//!
//! Folosit de finality.zig / staking.zig pentru a colecta dovezi de comportament
//! malițios (double-signing, equivocation, unavailability) și a le pregăti pentru
//! submission on-chain. Verificarea criptografică propriu-zisă (signatures) rămâne
//! în handler-ul de submission — aici doar stocăm + serializăm.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ValidatorId = [32]u8;

pub const EvidenceType = enum(u8) {
    double_signing = 1,
    invalid_block = 2,
    unavailability = 3,
};

pub const SlashingEvidence = struct {
    validator_id: ValidatorId,
    evidence_type: EvidenceType,
    block_height: u64,
    timestamp: u64,
    /// Owned by collector — proof bytes (signatures, conflicting blocks, etc.)
    proof: []u8,
};

pub const EvidenceCollector = struct {
    allocator: Allocator,
    evidences: std.ArrayList(SlashingEvidence) = .empty,

    pub fn init(allocator: Allocator) EvidenceCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EvidenceCollector) void {
        for (self.evidences.items) |ev| {
            self.allocator.free(ev.proof);
        }
        self.evidences.deinit(self.allocator);
    }

    /// Adaugă o dovadă nouă. Duplică `proof` în memory propriu.
    pub fn submitEvidence(
        self: *EvidenceCollector,
        validator_id: ValidatorId,
        evidence_type: EvidenceType,
        block_height: u64,
        proof: []const u8,
    ) !void {
        // Skip duplicate (acelasi validator + tip + height + proof) — idempotent.
        for (self.evidences.items) |ev| {
            if (std.mem.eql(u8, &ev.validator_id, &validator_id) and
                ev.evidence_type == evidence_type and
                ev.block_height == block_height and
                std.mem.eql(u8, ev.proof, proof))
            {
                return;
            }
        }

        const proof_copy = try self.allocator.dupe(u8, proof);
        errdefer self.allocator.free(proof_copy);
        try self.evidences.append(self.allocator, .{
            .validator_id = validator_id,
            .evidence_type = evidence_type,
            .block_height = block_height,
            .timestamp = @intCast(std.time.timestamp()),
            .proof = proof_copy,
        });
    }

    /// Câte dovezi pentru un anumit validator?
    pub fn countFor(self: *const EvidenceCollector, validator_id: ValidatorId) usize {
        var c: usize = 0;
        for (self.evidences.items) |ev| {
            if (std.mem.eql(u8, &ev.validator_id, &validator_id)) c += 1;
        }
        return c;
    }

    /// Serializează toate dovezile într-un buffer pentru on-chain TX.
    /// Format: pentru fiecare evidence:
    ///   [validator_id 32B][type 1B][height 8B LE][proof_len 4B LE][proof N bytes]
    pub fn serializeAll(self: *const EvidenceCollector) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        for (self.evidences.items) |ev| {
            try buf.appendSlice(self.allocator, &ev.validator_id);
            try buf.append(self.allocator, @intFromEnum(ev.evidence_type));

            var height_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &height_bytes, ev.block_height, .little);
            try buf.appendSlice(self.allocator, &height_bytes);

            var len_bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_bytes, @intCast(ev.proof.len), .little);
            try buf.appendSlice(self.allocator, &len_bytes);

            try buf.appendSlice(self.allocator, ev.proof);
        }

        return try buf.toOwnedSlice(self.allocator);
    }

    /// Curăță colectorul după submission on-chain reușit.
    pub fn clear(self: *EvidenceCollector) void {
        for (self.evidences.items) |ev| {
            self.allocator.free(ev.proof);
        }
        self.evidences.clearRetainingCapacity();
    }
};

// ============================================================
// Tests
// ============================================================

test "submit and count evidence" {
    var c = EvidenceCollector.init(std.testing.allocator);
    defer c.deinit();

    const v1: ValidatorId = [_]u8{1} ** 32;
    const v2: ValidatorId = [_]u8{2} ** 32;

    try c.submitEvidence(v1, .double_signing, 100, "proof_a");
    try c.submitEvidence(v1, .invalid_block, 101, "proof_b");
    try c.submitEvidence(v2, .double_signing, 100, "proof_c");

    try std.testing.expectEqual(@as(usize, 3), c.evidences.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.countFor(v1));
    try std.testing.expectEqual(@as(usize, 1), c.countFor(v2));
}

test "duplicate submit is idempotent" {
    var c = EvidenceCollector.init(std.testing.allocator);
    defer c.deinit();

    const v: ValidatorId = [_]u8{3} ** 32;
    try c.submitEvidence(v, .double_signing, 100, "proof");
    try c.submitEvidence(v, .double_signing, 100, "proof");
    try c.submitEvidence(v, .double_signing, 100, "proof");

    try std.testing.expectEqual(@as(usize, 1), c.evidences.items.len);
}

test "serializeAll produces expected layout" {
    var c = EvidenceCollector.init(std.testing.allocator);
    defer c.deinit();

    const v: ValidatorId = [_]u8{0xAA} ** 32;
    try c.submitEvidence(v, .invalid_block, 0x1234, "xy");

    const out = try c.serializeAll();
    defer std.testing.allocator.free(out);

    // 32 (id) + 1 (type) + 8 (height) + 4 (len) + 2 (proof) = 47
    try std.testing.expectEqual(@as(usize, 47), out.len);
    try std.testing.expectEqual(@as(u8, 0xAA), out[0]);
    try std.testing.expectEqual(@as(u8, 2), out[32]); // invalid_block = 2
    try std.testing.expectEqual(@as(u8, 'x'), out[45]);
    try std.testing.expectEqual(@as(u8, 'y'), out[46]);
}

test "clear empties collector and frees proofs" {
    var c = EvidenceCollector.init(std.testing.allocator);
    defer c.deinit();

    const v: ValidatorId = [_]u8{4} ** 32;
    try c.submitEvidence(v, .unavailability, 50, "abc");
    try c.submitEvidence(v, .unavailability, 51, "def");

    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.evidences.items.len);
}
