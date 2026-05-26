// ============================================
// 3. core/sighash.zig
// ============================================
const std = @import("std");
const crypto = std.crypto;
const sha256 = crypto.hash.sha2.Sha256;

pub const SighashFlag = enum(u8) {
    ALL = 0x01,
    NONE = 0x02,
    SINGLE = 0x03,
    ANYONECANPAY_ALL = 0x81,
    ANYONECANPAY_NONE = 0x82,
    ANYONECANPAY_SINGLE = 0x83,
    
    pub fn isAnyoneCanPay(self: SighashFlag) bool {
        return @intFromEnum(self) & 0x80 != 0;
    }
    
    pub fn baseType(self: SighashFlag) SighashFlag {
        const val = @intFromEnum(self) & 0x1F;
        return @enumFromInt(val);
    }
};

pub const Transaction = struct {
    version: u32 = 2,
    inputs: []Input,
    outputs: []Output,
    locktime: u32 = 0,
    
    pub fn computeSighash(
        self: *const Transaction,
        input_index: usize,
        flag: SighashFlag,
        script_code: ?[]const u8,
        amount: ?u64,
    ) ![32]u8 {
        const is_anyone_can_pay = flag.isAnyoneCanPay();
        const base = flag.baseType();
        
        var hasher = sha256.init(.{});
        
        // Version
        hasher.update(std.mem.asBytes(&self.version));
        
        // Inputs based on flag
        if (is_anyone_can_pay) {
            // Only hash the current input
            hasher.update(std.mem.asBytes(&@as(u32, 1)));
            try self.hashSingleInput(&mut hasher, input_index, script_code, amount);
        } else {
            // Hash all inputs
            hasher.update(std.mem.asBytes(&@as(u32, @intCast(self.inputs.len))));
            for (self.inputs, 0..) |input, i| {
                try self.hashInput(&mut hasher, input, i, script_code, amount);
            }
        }
        
        // Outputs based on base flag
        switch (base) {
            .ALL => {
                hasher.update(std.mem.asBytes(&@as(u32, @intCast(self.outputs.len))));
                for (self.outputs) |output| {
                    try self.hashOutput(&mut hasher, output);
                }
            },
            .NONE => {
                hasher.update(std.mem.asBytes(&@as(u32, 0)));
            },
            .SINGLE => {
                if (input_index >= self.outputs.len) {
                    // Return all-ones hash per spec
                    return [_]u8{0xFF} ** 32;
                }
                hasher.update(std.mem.asBytes(&@as(u32, @intCast(self.outputs.len))));
                for (self.outputs, 0..) |output, i| {
                    if (i == input_index) {
                        try self.hashOutput(&mut hasher, output);
                    } else {
                        // Null output for other indices
                        const null_output = [_]u8{0} ** 32;
                        hasher.update(&null_output);
                    }
                }
            },
            else => unreachable,
        }
        
        // Locktime
        hasher.update(std.mem.asBytes(&self.locktime));
        
        // Sighash type
        hasher.update(&[_]u8{@intFromEnum(flag)});
        
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }
    
    fn hashSingleInput(
        self: *const Transaction,
        hasher: *sha256,
        input_index: usize,
        script_code: ?[]const u8,
        amount: ?u64,
    ) !void {
        const input = self.inputs[input_index];
        hasher.update(&input.outpoint.txid);
        hasher.update(std.mem.asBytes(&input.outpoint.index));
        if (script_code) |sc| {
            hasher.update(std.mem.asBytes(&@as(u32, @intCast(sc.len))));
            hasher.update(sc);
        } else {
            hasher.update(&[_]u8{0,0,0,0});
        }
        if (amount) |amt| {
            hasher.update(std.mem.asBytes(&amt));
        } else {
            hasher.update(&[_]u8{0} ** 8);
        }
        hasher.update(std.mem.asBytes(&input.sequence));
    }
    
    fn hashInput(
        self: *const Transaction,
        hasher: *sha256,
        input: Input,
        _: usize,
        script_code: ?[]const u8,
        amount: ?u64,
    ) !void {
        hasher.update(&input.outpoint.txid);
        hasher.update(std.mem.asBytes(&input.outpoint.index));
        if (script_code) |sc| {
            hasher.update(std.mem.asBytes(&@as(u32, @intCast(sc.len))));
            hasher.update(sc);
        } else {
            hasher.update(&[_]u8{0,0,0,0});
        }
        if (amount) |amt| {
            hasher.update(std.mem.asBytes(&amt));
        } else {
            hasher.update(&[_]u8{0} ** 8);
        }
        hasher.update(std.mem.asBytes(&input.sequence));
    }
    
    fn hashOutput(self: *const Transaction, hasher: *sha256, output: Output) !void {
        hasher.update(std.mem.asBytes(&output.amount));
        hasher.update(std.mem.asBytes(&@as(u32, @intCast(output.script.len))));
        hasher.update(output.script);
    }
};

pub const OutPoint = struct {
    txid: [32]u8,
    index: u32,
};

pub const Input = struct {
    outpoint: OutPoint,
    script_sig: []const u8,
    sequence: u32 = 0xFFFFFFFF,
    witness: ?[][]const u8 = null,
};

pub const Output = struct {
    amount: u64,
    script: []const u8,
};

test "SIGHASH_ALL basic" {
    var allocator = std.testing.allocator;
    const tx = Transaction{
        .inputs = &[_]Input{},
        .outputs = &[_]Output{},
        .locktime = 0,
    };
    const hash = try tx.computeSighash(0, SighashFlag.ALL, null, null);
    try std.testing.expect(hash.len == 32);
}

test "SIGHASH_SINGLE with missing output" {
    var allocator = std.testing.allocator;
    const tx = Transaction{
        .inputs = &[_]Input{Input{
            .outpoint = OutPoint{ .txid = [_]u8{0} ** 32, .index = 0 },
            .script_sig = &[_]u8{},
            .sequence = 0xFFFFFFFF,
        }},
        .outputs = &[_]Output{},
        .locktime = 0,
    };
    const hash = try tx.computeSighash(0, SighashFlag.SINGLE, null, null);
    // Should be all-ones
    for (hash) |byte| {
        try std.testing.expect(byte == 0xFF);
    }
}