// core/evm/types.zig — EVM primitive types for OmniBus BlockChainCore
// Mirrors core-rust/src/evm/executor.rs types without revm dependency.
// chain_id = 7771 (CHAINID opcode constant)

const std = @import("std");

// ---------------------------------------------------------------------------
// U256 — 256-bit unsigned integer, 4 x u64 big-endian word order
// word[0] = most significant 64 bits
// ---------------------------------------------------------------------------
pub const U256 = struct {
    words: [4]u64, // words[0] = MSW, words[3] = LSW

    pub const ZERO: U256 = .{ .words = .{ 0, 0, 0, 0 } };
    pub const ONE: U256 = .{ .words = .{ 0, 0, 0, 1 } };
    pub const MAX: U256 = .{ .words = .{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) } };

    pub fn from_u64(v: u64) U256 {
        return .{ .words = .{ 0, 0, 0, v } };
    }

    pub fn from_u128(v: u128) U256 {
        return .{ .words = .{ 0, 0, @intCast(v >> 64), @intCast(v & 0xFFFFFFFFFFFFFFFF) } };
    }

    /// Parse from 32-byte big-endian slice
    pub fn from_bytes32(b: [32]u8) U256 {
        var w: [4]u64 = undefined;
        for (0..4) |i| {
            var v: u64 = 0;
            for (0..8) |j| {
                v = (v << 8) | b[i * 8 + j];
            }
            w[i] = v;
        }
        return .{ .words = w };
    }

    /// Serialize to 32-byte big-endian
    pub fn to_bytes32(self: U256) [32]u8 {
        var b: [32]u8 = undefined;
        for (0..4) |i| {
            const v = self.words[i];
            for (0..8) |j| {
                b[i * 8 + j] = @intCast((v >> @intCast(56 - j * 8)) & 0xFF);
            }
        }
        return b;
    }

    pub fn to_u64(self: U256) u64 {
        return self.words[3];
    }

    pub fn is_zero(self: U256) bool {
        return self.words[0] == 0 and self.words[1] == 0 and
            self.words[2] == 0 and self.words[3] == 0;
    }

    pub fn eq(a: U256, b: U256) bool {
        return a.words[0] == b.words[0] and a.words[1] == b.words[1] and
            a.words[2] == b.words[2] and a.words[3] == b.words[3];
    }

    /// Returns true if a < b (unsigned)
    pub fn lt(a: U256, b: U256) bool {
        for (0..4) |i| {
            if (a.words[i] < b.words[i]) return true;
            if (a.words[i] > b.words[i]) return false;
        }
        return false;
    }

    /// Returns true if a > b (unsigned)
    pub fn gt(a: U256, b: U256) bool {
        return lt(b, a);
    }

    /// Wrapping add mod 2^256
    pub fn add(a: U256, b: U256) U256 {
        var carry: u64 = 0;
        var result: [4]u64 = undefined;
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            const sum = @as(u128, a.words[i]) + @as(u128, b.words[i]) + carry;
            result[i] = @truncate(sum);
            carry = @intCast(sum >> 64);
        }
        return .{ .words = result };
    }

    /// Wrapping sub mod 2^256
    pub fn sub(a: U256, b: U256) U256 {
        var borrow: u64 = 0;
        var result: [4]u64 = undefined;
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            const av = @as(i128, a.words[i]);
            const bv = @as(i128, b.words[i]) + borrow;
            if (av >= bv) {
                result[i] = @intCast(av - bv);
                borrow = 0;
            } else {
                result[i] = @intCast(@as(i128, av) + (1 << 64) - bv);
                borrow = 1;
            }
        }
        return .{ .words = result };
    }

    /// Wrapping mul mod 2^256 (schoolbook, fast enough for MVP)
    pub fn mul(a: U256, b: U256) U256 {
        var r: [4]u64 = .{ 0, 0, 0, 0 };
        // Treat as 4 limbs little-endian for multiplication, then reverse
        const al = [4]u64{ a.words[3], a.words[2], a.words[1], a.words[0] };
        const bl = [4]u64{ b.words[3], b.words[2], b.words[1], b.words[0] };
        var rl = [4]u64{ 0, 0, 0, 0 };
        for (0..4) |i| {
            var carry: u64 = 0;
            var j: usize = 0;
            while (i + j < 4) : (j += 1) {
                const prod = @as(u128, al[i]) * @as(u128, bl[j]) +
                    @as(u128, rl[i + j]) + @as(u128, carry);
                rl[i + j] = @truncate(prod);
                carry = @intCast(prod >> 64);
            }
        }
        r = .{ rl[3], rl[2], rl[1], rl[0] };
        return .{ .words = r };
    }

    /// Unsigned division (returns quotient). Returns ZERO if b==0.
    pub fn div(a: U256, b: U256) U256 {
        if (b.is_zero()) return ZERO;
        // Fast path for small values
        if (a.words[0] == 0 and a.words[1] == 0 and a.words[2] == 0 and
            b.words[0] == 0 and b.words[1] == 0 and b.words[2] == 0)
        {
            return from_u64(a.words[3] / b.words[3]);
        }
        // General case: long division using bit-by-bit method
        var q = ZERO;
        var r = ZERO;
        var i: usize = 256;
        while (i > 0) {
            i -= 1;
            // r = r << 1
            r = shl1(r);
            // r[0] |= bit i of a
            const word_idx = (255 - i) / 64;
            const bit_idx: u6 = @intCast((255 - i) % 64);
            const bit = (a.words[word_idx] >> (63 - bit_idx)) & 1;
            r.words[3] |= bit;
            if (!lt(r, b)) {
                r = sub(r, b);
                // set bit i of q
                const qi = i / 64;
                const qb: u6 = @intCast(i % 64);
                q.words[3 - qi] |= @as(u64, 1) << qb;
            }
        }
        return q;
    }

    /// Unsigned mod. Returns ZERO if b==0.
    pub fn mod(a: U256, b: U256) U256 {
        if (b.is_zero()) return ZERO;
        if (a.words[0] == 0 and a.words[1] == 0 and a.words[2] == 0 and
            b.words[0] == 0 and b.words[1] == 0 and b.words[2] == 0)
        {
            return from_u64(a.words[3] % b.words[3]);
        }
        // r = a - (a/b)*b
        const q = div(a, b);
        return sub(a, mul(q, b));
    }

    pub fn bitAnd(a: U256, b: U256) U256 {
        return .{ .words = .{ a.words[0] & b.words[0], a.words[1] & b.words[1], a.words[2] & b.words[2], a.words[3] & b.words[3] } };
    }

    pub fn bitOr(a: U256, b: U256) U256 {
        return .{ .words = .{ a.words[0] | b.words[0], a.words[1] | b.words[1], a.words[2] | b.words[2], a.words[3] | b.words[3] } };
    }

    pub fn bitXor(a: U256, b: U256) U256 {
        return .{ .words = .{ a.words[0] ^ b.words[0], a.words[1] ^ b.words[1], a.words[2] ^ b.words[2], a.words[3] ^ b.words[3] } };
    }

    pub fn bitNot(a: U256) U256 {
        return .{ .words = .{ ~a.words[0], ~a.words[1], ~a.words[2], ~a.words[3] } };
    }

    /// Logical shift left by `n` bits (n must be < 256)
    pub fn shl(a: U256, n: u64) U256 {
        if (n >= 256) return ZERO;
        if (n == 0) return a;
        var result = ZERO;
        const word_shift = n / 64;
        const bit_shift: u6 = @intCast(n % 64);
        // We store MSW at index 0, so shifting left means moving towards index 0
        var i: usize = 0;
        while (i + word_shift < 4) : (i += 1) {
            const src_idx = 3 - i;
            const dst_idx = 3 - i - word_shift;
            result.words[dst_idx] |= a.words[src_idx] << bit_shift;
            if (bit_shift > 0 and dst_idx > 0) {
                // 64 - bit_shift is in range 1..63, safe to cast to u6
                const rshift: u6 = @intCast(64 - @as(u64, bit_shift));
                result.words[dst_idx - 1] |= a.words[src_idx] >> rshift;
            }
        }
        return result;
    }

    /// Logical shift right by `n` bits
    pub fn shr(a: U256, n: u64) U256 {
        if (n >= 256) return ZERO;
        if (n == 0) return a;
        var result = ZERO;
        const word_shift = n / 64;
        const bit_shift: u6 = @intCast(n % 64);
        var i: usize = 0;
        while (i + word_shift < 4) : (i += 1) {
            const src_idx = i;
            const dst_idx = i + word_shift;
            result.words[dst_idx] |= a.words[src_idx] >> bit_shift;
            if (bit_shift > 0 and dst_idx < 3) {
                // 64 - bit_shift is in range 1..63, safe to cast to u6
                const lshift: u6 = @intCast(64 - @as(u64, bit_shift));
                result.words[dst_idx + 1] |= a.words[src_idx] << lshift;
            }
        }
        return result;
    }

    // Internal helper: shift left by exactly 1 bit
    fn shl1(a: U256) U256 {
        var result: [4]u64 = undefined;
        result[0] = (a.words[0] << 1) | (a.words[1] >> 63);
        result[1] = (a.words[1] << 1) | (a.words[2] >> 63);
        result[2] = (a.words[2] << 1) | (a.words[3] >> 63);
        result[3] = a.words[3] << 1;
        return .{ .words = result };
    }

    /// Get i-th byte (big-endian, i=0 = MSB)
    pub fn byte_at(self: U256, i: u64) u8 {
        if (i >= 32) return 0;
        const bytes = self.to_bytes32();
        return bytes[@intCast(i)];
    }
};

// ---------------------------------------------------------------------------
// Address — 20-byte EVM address
// ---------------------------------------------------------------------------
pub const Address = [20]u8;

pub const ZERO_ADDRESS: Address = [_]u8{0} ** 20;

// ---------------------------------------------------------------------------
// ExecStatus
// ---------------------------------------------------------------------------
pub const ExecStatus = enum {
    success,
    revert,
    halt,
};

// ---------------------------------------------------------------------------
// Log — EVM event log
// ---------------------------------------------------------------------------
pub const Log = struct {
    address: Address,
    topics: [][32]u8,
    data: []u8,
    block: u64,
    tx_hash: [32]u8,
};

// ---------------------------------------------------------------------------
// ExecResult — result of execute_tx
// ---------------------------------------------------------------------------
pub const ExecResult = struct {
    gas_used: u64,
    status: ExecStatus,
    /// Call: return-data; Create: deployed runtime code.
    output: []u8,
    contract_addr: ?Address,
    logs: []Log,
};

// ---------------------------------------------------------------------------
// CallResult — result of execute_call (read-only, no logs/contract_addr)
// ---------------------------------------------------------------------------
pub const CallResult = struct {
    gas_used: u64,
    status: ExecStatus,
    output: []u8,
};

// ---------------------------------------------------------------------------
// TxInput — caller-supplied transaction
// ---------------------------------------------------------------------------
pub const TxInput = struct {
    from: Address,
    /// null = contract creation
    to: ?Address,
    /// Value in OMNI atoms (smallest unit)
    value: u64,
    data: []const u8,
    gas_limit: u64,
    nonce: u64,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "U256 from_u64 and is_zero" {
    const z = U256.ZERO;
    try testing.expect(z.is_zero());
    const v = U256.from_u64(42);
    try testing.expect(!v.is_zero());
    try testing.expectEqual(@as(u64, 42), v.to_u64());
}

test "U256 add wrapping" {
    const a = U256.MAX;
    const b = U256.ONE;
    const r = a.add(b);
    try testing.expect(r.is_zero());
}

test "U256 sub" {
    const a = U256.from_u64(10);
    const b = U256.from_u64(3);
    const r = a.sub(b);
    try testing.expectEqual(@as(u64, 7), r.to_u64());
}

test "U256 mul" {
    const a = U256.from_u64(6);
    const b = U256.from_u64(7);
    try testing.expectEqual(@as(u64, 42), a.mul(b).to_u64());
}

test "U256 div and mod" {
    const a = U256.from_u64(17);
    const b = U256.from_u64(5);
    try testing.expectEqual(@as(u64, 3), a.div(b).to_u64());
    try testing.expectEqual(@as(u64, 2), a.mod(b).to_u64());
}

test "U256 lt gt eq" {
    const a = U256.from_u64(5);
    const b = U256.from_u64(10);
    try testing.expect(a.lt(b));
    try testing.expect(b.gt(a));
    try testing.expect(a.eq(a));
    try testing.expect(!a.eq(b));
}

test "U256 to_bytes32 from_bytes32 roundtrip" {
    const v = U256.from_u64(0xDEADBEEF);
    const b = v.to_bytes32();
    const v2 = U256.from_bytes32(b);
    try testing.expect(v.eq(v2));
}

test "U256 shl shr" {
    const v = U256.from_u64(1);
    const shifted = v.shl(128);
    const back = shifted.shr(128);
    try testing.expect(back.eq(U256.ONE));
}
