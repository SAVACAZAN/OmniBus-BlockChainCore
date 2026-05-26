//! pq_migrate_consensus.zig — PQ key migration consensus rules (FAZA 6)
//!
//! Defines the `pq_migrate_v1` consensus transaction type that binds an
//! OLD post-quantum public key (held under the legacy non-deterministic
//! `signWithAllPQDomains` flow) to a NEW deterministic key derived via
//! HKDF-SHA512 from the wallet's BIP-39 master seed.
//!
//! Wire format (TLV-friendly, big-endian fixed offsets):
//!   ┌──────────────┬───────┐
//!   │ version       │ u8    │ 1 byte  — always 0x01 for v1
//!   │ scheme        │ u8    │ 1 byte  — 0x01=ML-DSA-87, 0x02=Falcon-512, 0x03=SLH-DSA-256s
//!   │ coin_type     │ u32   │ 4 bytes (LE)
//!   │ timestamp     │ i64   │ 8 bytes (LE)
//!   │ old_pk_size   │ u16   │ 2 bytes (LE)
//!   │ new_pk_size   │ u16   │ 2 bytes (LE)
//!   │ proof_size    │ u16   │ 2 bytes (LE)
//!   │ old_pubkey    │ var   │ old_pk_size bytes
//!   │ new_pubkey    │ var   │ new_pk_size bytes
//!   │ proof         │ var   │ proof_size bytes (signature by OLD key over NEW pubkey)
//!   └──────────────┴───────┘
//!
//! Validation rule: `pq_crypto.verify(old_pubkey, new_pubkey, proof)` must succeed
//! using the algorithm selected by `scheme`. This proves the holder of the old
//! private key authorised the migration.
//!
//! State application: on `apply(state)`, the chain rewrites every reference of
//! `old_pubkey` in PQ-key index to `new_pubkey`, marks `old_pubkey` as
//! `migrated_to=new_pubkey` (prevents double-spend / replay of the same proof),
//! and emits a `pq_migrated` event.
//!
//! NOTE: This module ships the data structure, serialize/deserialize, validate,
//! and apply primitives. Mempool/blockchain/RPC/CLI wiring is documented in
//! `PQ_MIGRATION_PLAN.md` (each is an invasive change on a running testnet, so
//! they are staged behind `chain_config.PQ_DETERMINISTIC_SIGNING` and a hard
//! fork height — wiring will land in FAZA 6.1 once the testnet/PC pair is
//! drained).

const std = @import("std");
const pq_crypto = @import("pq_crypto.zig");

pub const PQ_MIGRATE_V1_VERSION: u8 = 0x01;

/// Header is fixed; key/proof slices follow.
pub const PQMigrateV1Header = extern struct {
    version: u8,
    scheme: u8,
    coin_type: u32,
    timestamp: i64,
    old_pk_size: u16,
    new_pk_size: u16,
    proof_size: u16,
};

/// Heap-friendly representation. Use `serialize` / `deserialize` for wire form.
pub const PQMigrateV1 = struct {
    version: u8 = PQ_MIGRATE_V1_VERSION,
    scheme: u8,
    coin_type: u32,
    timestamp: i64,
    old_pubkey: []const u8,
    new_pubkey: []const u8,
    /// Signature by the OLD private key over `new_pubkey` bytes.
    proof_of_ownership: []const u8,

    /// Returns the exact serialized length in bytes (header + payload).
    pub fn serializedSize(self: PQMigrateV1) usize {
        return 20 + self.old_pubkey.len + self.new_pubkey.len + self.proof_of_ownership.len;
        // 20 = 1+1+4+8+2+2+2
    }

    /// Serialize TLV form. Caller owns the returned slice.
    pub fn serialize(self: PQMigrateV1, allocator: std.mem.Allocator) ![]u8 {
        if (self.old_pubkey.len > std.math.maxInt(u16)) return error.OldPubkeyTooLarge;
        if (self.new_pubkey.len > std.math.maxInt(u16)) return error.NewPubkeyTooLarge;
        if (self.proof_of_ownership.len > std.math.maxInt(u16)) return error.ProofTooLarge;

        const total = self.serializedSize();
        var buf = try allocator.alloc(u8, total);
        errdefer allocator.free(buf);

        var p: usize = 0;
        buf[p] = self.version; p += 1;
        buf[p] = self.scheme; p += 1;
        std.mem.writeInt(u32, buf[p..][0..4], self.coin_type, .little); p += 4;
        std.mem.writeInt(i64, buf[p..][0..8], self.timestamp, .little); p += 8;
        std.mem.writeInt(u16, buf[p..][0..2], @intCast(self.old_pubkey.len), .little); p += 2;
        std.mem.writeInt(u16, buf[p..][0..2], @intCast(self.new_pubkey.len), .little); p += 2;
        std.mem.writeInt(u16, buf[p..][0..2], @intCast(self.proof_of_ownership.len), .little); p += 2;
        @memcpy(buf[p..][0..self.old_pubkey.len], self.old_pubkey); p += self.old_pubkey.len;
        @memcpy(buf[p..][0..self.new_pubkey.len], self.new_pubkey); p += self.new_pubkey.len;
        @memcpy(buf[p..][0..self.proof_of_ownership.len], self.proof_of_ownership); p += self.proof_of_ownership.len;
        std.debug.assert(p == total);
        return buf;
    }

    /// Deserialize from wire bytes. Returned slices alias `bytes` — copy if you
    /// need to outlive the source buffer.
    pub fn deserialize(bytes: []const u8) !PQMigrateV1 {
        if (bytes.len < 20) return error.TruncatedHeader;
        var p: usize = 0;
        const version = bytes[p]; p += 1;
        if (version != PQ_MIGRATE_V1_VERSION) return error.UnsupportedVersion;
        const scheme = bytes[p]; p += 1;
        if (scheme != 0x01 and scheme != 0x02 and scheme != 0x03) return error.UnsupportedScheme;
        const coin_type = std.mem.readInt(u32, bytes[p..][0..4], .little); p += 4;
        const timestamp = std.mem.readInt(i64, bytes[p..][0..8], .little); p += 8;
        const old_pk_size = std.mem.readInt(u16, bytes[p..][0..2], .little); p += 2;
        const new_pk_size = std.mem.readInt(u16, bytes[p..][0..2], .little); p += 2;
        const proof_size  = std.mem.readInt(u16, bytes[p..][0..2], .little); p += 2;

        const required = @as(usize, old_pk_size) + new_pk_size + proof_size;
        if (bytes.len < 20 + required) return error.TruncatedPayload;

        const old_pubkey = bytes[p..][0..old_pk_size]; p += old_pk_size;
        const new_pubkey = bytes[p..][0..new_pk_size]; p += new_pk_size;
        const proof = bytes[p..][0..proof_size]; p += proof_size;

        return .{
            .version = version,
            .scheme = scheme,
            .coin_type = coin_type,
            .timestamp = timestamp,
            .old_pubkey = old_pubkey,
            .new_pubkey = new_pubkey,
            .proof_of_ownership = proof,
        };
    }

    /// Verify the proof-of-ownership: the OLD pubkey signed the NEW pubkey bytes.
    /// Returns true iff signature verifies under the appropriate PQ algorithm.
    ///
    /// Requires liboqs (`has_oqs == true`). Returns false otherwise — callers
    /// MUST treat false as "reject TX".
    pub fn validate(self: PQMigrateV1) bool {
        switch (self.scheme) {
            0x01 => return pq_crypto.mldsaVerify(self.old_pubkey, self.new_pubkey, self.proof_of_ownership),
            0x02 => {
                // Falcon-512: there is no top-level wrapper; reconstruct via
                // pq_crypto.Falcon512 struct verification by treating old_pubkey
                // as the keypair's public_key field.
                if (self.old_pubkey.len != pq_crypto.Falcon512.PUBLIC_KEY_SIZE) return false;
                var kp: pq_crypto.Falcon512 = undefined;
                @memcpy(&kp.public_key, self.old_pubkey[0..pq_crypto.Falcon512.PUBLIC_KEY_SIZE]);
                // secret_key unused by verify; leave undefined
                return kp.verify(self.new_pubkey, self.proof_of_ownership);
            },
            0x03 => {
                if (self.old_pubkey.len != pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE) return false;
                var kp: pq_crypto.SlhDsa256s = undefined;
                @memcpy(&kp.public_key, self.old_pubkey[0..pq_crypto.SlhDsa256s.PUBLIC_KEY_SIZE]);
                return kp.verify(self.new_pubkey, self.proof_of_ownership);
            },
            else => return false,
        }
    }
};

/// Minimal state interface for `apply`. The real chain state lives in
/// `blockchain.zig` / `state_trie.zig`; we keep `apply` decoupled so it can be
/// unit-tested without spinning up the whole chain.
pub const PQMigrationState = struct {
    /// Maps old_pubkey_hex → new_pubkey_hex (most recent migration wins).
    /// Hex-encoded keys keep the map serializable & debug-printable.
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) PQMigrationState {
        return .{ .map = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *PQMigrationState) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.map.allocator.free(entry.key_ptr.*);
            self.map.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }
};

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const HEX = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2]     = HEX[b >> 4];
        out[i * 2 + 1] = HEX[b & 0x0F];
    }
    return out;
}

/// Apply a validated migration to chain state. Caller MUST have called
/// `validate()` and confirmed it returned `true` before invoking apply.
/// Returns `error.AlreadyMigrated` if the old_pubkey was migrated before
/// (prevents proof replay).
pub fn apply(state: *PQMigrationState, tx: PQMigrateV1) !void {
    const old_hex = try hexEncode(state.map.allocator, tx.old_pubkey);

    if (state.map.contains(old_hex)) {
        state.map.allocator.free(old_hex);
        return error.AlreadyMigrated;
    }

    const new_hex = hexEncode(state.map.allocator, tx.new_pubkey) catch |err| {
        state.map.allocator.free(old_hex);
        return err;
    };

    state.map.put(old_hex, new_hex) catch |err| {
        state.map.allocator.free(old_hex);
        state.map.allocator.free(new_hex);
        return err;
    };

    std.log.info("pq_migrate_applied coin_type={d} scheme={d} from={s} to={s}", .{
        tx.coin_type, tx.scheme,
        old_hex[0..@min(old_hex.len, 16)],
        new_hex[0..@min(new_hex.len, 16)],
    });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "PQMigrateV1 serialize → deserialize round-trip" {
    var ally = testing.allocator;

    const old_pk = [_]u8{0xAA} ** 64;
    const new_pk = [_]u8{0xBB} ** 64;
    const proof  = [_]u8{0xCC} ** 128;

    const original = PQMigrateV1{
        .scheme = 0x01,
        .coin_type = 778,
        .timestamp = 1_700_000_000,
        .old_pubkey = &old_pk,
        .new_pubkey = &new_pk,
        .proof_of_ownership = &proof,
    };

    const wire = try original.serialize(ally);
    defer ally.free(wire);

    try testing.expectEqual(original.serializedSize(), wire.len);

    const parsed = try PQMigrateV1.deserialize(wire);
    try testing.expectEqual(original.version, parsed.version);
    try testing.expectEqual(original.scheme, parsed.scheme);
    try testing.expectEqual(original.coin_type, parsed.coin_type);
    try testing.expectEqual(original.timestamp, parsed.timestamp);
    try testing.expectEqualSlices(u8, original.old_pubkey, parsed.old_pubkey);
    try testing.expectEqualSlices(u8, original.new_pubkey, parsed.new_pubkey);
    try testing.expectEqualSlices(u8, original.proof_of_ownership, parsed.proof_of_ownership);
}

test "PQMigrateV1 deserialize rejects truncated buffer" {
    const tiny = [_]u8{0x01};
    try testing.expectError(error.TruncatedHeader, PQMigrateV1.deserialize(&tiny));
}

test "PQMigrateV1 deserialize rejects unknown version" {
    var buf: [20]u8 = [_]u8{0} ** 20;
    buf[0] = 0xFF; // bad version
    buf[1] = 0x01; // valid scheme placeholder
    try testing.expectError(error.UnsupportedVersion, PQMigrateV1.deserialize(&buf));
}

test "PQMigrateV1 deserialize rejects unknown scheme" {
    var buf: [20]u8 = [_]u8{0} ** 20;
    buf[0] = 0x01;
    buf[1] = 0x42; // bad scheme
    try testing.expectError(error.UnsupportedScheme, PQMigrateV1.deserialize(&buf));
}

test "PQMigrationState apply records mapping + rejects replay" {
    var state = PQMigrationState.init(testing.allocator);
    defer state.deinit();

    const old_pk = [_]u8{0xAA} ** 4;
    const new_pk = [_]u8{0xBB} ** 4;
    const proof  = [_]u8{0xCC} ** 4;

    const tx = PQMigrateV1{
        .scheme = 0x01,
        .coin_type = 778,
        .timestamp = 0,
        .old_pubkey = &old_pk,
        .new_pubkey = &new_pk,
        .proof_of_ownership = &proof,
    };

    try apply(&state, tx);
    try testing.expectEqual(@as(usize, 1), state.map.count());

    // Second apply with same old_pubkey → replay rejected
    try testing.expectError(error.AlreadyMigrated, apply(&state, tx));
    try testing.expectEqual(@as(usize, 1), state.map.count());
}
