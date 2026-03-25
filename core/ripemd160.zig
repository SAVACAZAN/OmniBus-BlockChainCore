const std = @import("std");


// Constante rotatie stanga (80 runde, left half)
const RL = [80]u5{
    11, 14, 15, 12,  5,  8,  7,  9, 11, 13, 14, 15,  6,  7,  9,  8,
     7,  6,  8, 13, 11,  9,  7, 15,  7, 12, 15,  9, 11,  7, 13, 12,
    11, 13,  6,  7, 14,  9, 13, 15, 14,  8, 13,  6,  5, 12,  7,  5,
    11, 12, 14, 15, 14, 15,  9,  8,  9, 14,  5,  6,  8,  6,  5, 12,
     9, 15,  5, 11,  6,  8, 13, 12,  5, 12, 13, 14, 11,  8,  5,  6,
};
const RR = [80]u5{
     8,  9,  9, 11, 13, 15, 15,  5,  7,  7,  8, 11, 14, 14, 12,  6,
     9, 13, 15,  7, 12,  8,  9, 11,  7,  7, 12,  7,  6, 15, 13, 11,
     9,  7, 15, 11,  8,  6,  6, 14, 12, 13,  5, 14, 13, 13,  7,  5,
    15,  5,  8, 11, 14, 14,  6, 14,  6,  9, 12,  9, 12,  5, 15,  8,
     8,  5, 12,  9, 12,  5, 14,  6,  8, 13,  6,  5, 15, 13, 11, 11,
};
const ML = [80]u4{
     0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
     7,  4, 13,  1, 10,  6, 15,  3, 12,  0,  9,  5,  2, 14, 11,  8,
     3, 10, 14,  4,  9, 15,  8,  1,  2,  7,  0,  6, 13, 11,  5, 12,
     1,  9, 11, 10,  0,  8, 12,  4, 13,  3,  7, 15, 14,  5,  6,  2,
     4,  0,  5,  9,  7, 12,  2, 10, 14,  1,  3,  8, 11,  6, 15, 13,
};
const MR = [80]u4{
     5, 14,  7,  0,  9,  2, 11,  4, 13,  6, 15,  8,  1, 10,  3, 12,
     6, 11,  3,  7,  0, 13,  5, 10, 14, 15,  8, 12,  4,  9,  1,  2,
    15,  5,  1,  3,  7, 14,  6,  9, 11,  8, 12,  2, 10,  0,  4, 13,
     8,  6,  4,  1,  3, 11, 15,  0,  5, 12,  2, 13,  9,  7, 10, 14,
    12, 15, 10,  4,  1,  5,  8,  7,  6,  2, 13, 14,  0,  3,  9, 11,
};

inline fn f0(x: u32, y: u32, z: u32) u32 { return x ^ y ^ z; }
inline fn f1(x: u32, y: u32, z: u32) u32 { return (x & y) | (~x & z); }
inline fn f2(x: u32, y: u32, z: u32) u32 { return (x | ~y) ^ z; }
inline fn f3(x: u32, y: u32, z: u32) u32 { return (x & z) | (y & ~z); }
inline fn f4(x: u32, y: u32, z: u32) u32 { return x ^ (y | ~z); }

inline fn rol32(x: u32, n: u5) u32 {
    if (n == 0) return x;
    return (x << n) | (x >> @as(u5, 32 - @as(u6, n)));
}

pub const Ripemd160 = struct {
    pub const digest_length = 20;

    state: [5]u32,
    buf: [64]u8,
    buf_len: usize,
    total_len: u64,

    pub fn init() Ripemd160 {
        return .{
            .state = .{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Ripemd160, data: []const u8) void {
        var i: usize = 0;
        if (self.buf_len > 0) {
            const fill = @min(64 - self.buf_len, data.len);
            @memcpy(self.buf[self.buf_len..][0..fill], data[0..fill]);
            self.buf_len += fill;
            i = fill;
            if (self.buf_len == 64) {
                self.processBlock(&self.buf);
                self.buf_len = 0;
            }
        }
        while (i + 64 <= data.len) : (i += 64) {
            self.processBlock(data[i..][0..64]);
        }
        if (i < data.len) {
            const rem = data.len - i;
            @memcpy(self.buf[0..rem], data[i..]);
            self.buf_len = rem;
        }
        self.total_len += data.len;
    }

    pub fn final(self: *Ripemd160, out: *[20]u8) void {
        var tmp: [128]u8 = undefined;
        @memcpy(tmp[0..self.buf_len], self.buf[0..self.buf_len]);
        tmp[self.buf_len] = 0x80;
        var pad_end = self.buf_len + 1;
        if (pad_end > 56) {
            @memset(tmp[pad_end..64], 0);
            self.processBlock(tmp[0..64]);
            pad_end = 0;
        }
        @memset(tmp[pad_end..56], 0);
        std.mem.writeInt(u64, tmp[56..64], self.total_len * 8, .little);
        self.processBlock(tmp[0..64]);
        for (self.state, 0..) |s, idx| {
            std.mem.writeInt(u32, out[idx * 4 ..][0..4], s, .little);
        }
    }

    fn processBlock(self: *Ripemd160, block: *const [64]u8) void {
        var w: [16]u32 = undefined;
        for (0..16) |i| {
            w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
        }
        var al = self.state[0]; var bl = self.state[1];
        var cl = self.state[2]; var dl = self.state[3]; var el = self.state[4];
        var ar = al; var br = bl; var cr = cl; var dr = dl; var er = el;

        const KL = [5]u32{ 0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
        const KR = [5]u32{ 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };

        comptime var j: usize = 0;
        inline while (j < 80) : (j += 1) {
            const round = j / 16;
            const fl: u32 = switch (round) {
                0 => f0(bl, cl, dl),
                1 => f1(bl, cl, dl),
                2 => f2(bl, cl, dl),
                3 => f3(bl, cl, dl),
                else => f4(bl, cl, dl),
            };
            var tl = al +% fl +% w[ML[j]] +% KL[round];
            tl = rol32(tl, RL[j]) +% el;
            al = el; el = dl; dl = rol32(cl, 10); cl = bl; bl = tl;

            const fr: u32 = switch (round) {
                0 => f4(br, cr, dr),
                1 => f3(br, cr, dr),
                2 => f2(br, cr, dr),
                3 => f1(br, cr, dr),
                else => f0(br, cr, dr),
            };
            var tr = ar +% fr +% w[MR[j]] +% KR[round];
            tr = rol32(tr, RR[j]) +% er;
            ar = er; er = dr; dr = rol32(cr, 10); cr = br; br = tr;
        }

        const t = self.state[1] +% cl +% dr;
        self.state[1] = self.state[2] +% dl +% er;
        self.state[2] = self.state[3] +% el +% ar;
        self.state[3] = self.state[4] +% al +% br;
        self.state[4] = self.state[0] +% bl +% cr;
        self.state[0] = t;
    }

    pub fn hash(data: []const u8, out: *[20]u8) void {
        var h = Ripemd160.init();
        h.update(data);
        h.final(out);
    }
};

const testing = std.testing;

test "RIPEMD-160 string gol" {
    var out: [20]u8 = undefined;
    Ripemd160.hash("", &out);
    const expected = [20]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54,
        0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48,
        0xb2, 0x25, 0x8d, 0x31,
    };
    try testing.expectEqualSlices(u8, &expected, &out);
}

test "RIPEMD-160 abc" {
    var out: [20]u8 = undefined;
    Ripemd160.hash("abc", &out);
    const expected = [20]u8{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a,
        0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87,
        0xf1, 0x5a, 0x0b, 0xfc,
    };
    try testing.expectEqualSlices(u8, &expected, &out);
}

test "RIPEMD-160 determinist" {
    var o1: [20]u8 = undefined; var o2: [20]u8 = undefined;
    Ripemd160.hash("OmniBus", &o1);
    Ripemd160.hash("OmniBus", &o2);
    try testing.expectEqualSlices(u8, &o1, &o2);
}

test "RIPEMD-160 input diferit output diferit" {
    var o1: [20]u8 = undefined; var o2: [20]u8 = undefined;
    Ripemd160.hash("msg1", &o1);
    Ripemd160.hash("msg2", &o2);
    try testing.expect(!std.mem.eql(u8, &o1, &o2));
}
