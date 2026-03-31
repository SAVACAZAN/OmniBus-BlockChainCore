const std = @import("std");
const secp256k1_mod = @import("secp256k1.zig");
const ripemd160_mod = @import("ripemd160.zig");
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Ripemd160 = ripemd160_mod.Ripemd160;

// ─── OpCode — Bitcoin-compatible script opcodes ─────────────────────────────

pub const OpCode = enum(u8) {
    // Constants
    OP_0 = 0x00,
    OP_1 = 0x51,
    OP_2 = 0x52,
    OP_3 = 0x53,
    // Stack
    OP_DUP = 0x76,
    OP_DROP = 0x75,
    OP_SWAP = 0x7c,
    // Crypto
    OP_SHA256 = 0xa8,
    OP_HASH160 = 0xa9, // SHA256 + RIPEMD160
    OP_CHECKSIG = 0xac, // Verify ECDSA signature
    OP_CHECKMULTISIG = 0xae,
    // Comparison
    OP_EQUAL = 0x87,
    OP_EQUALVERIFY = 0x88,
    // Flow
    OP_VERIFY = 0x69,
    OP_RETURN = 0x6a, // Marks output as unspendable data carrier
    // Locktime
    OP_CHECKLOCKTIMEVERIFY = 0xb1, // BIP-65
    OP_CHECKSEQUENCEVERIFY = 0xb2, // BIP-112
    // Data push
    OP_PUSHDATA1 = 0x4c,
    OP_PUSHDATA2 = 0x4d,
};

// ─── Script Errors ──────────────────────────────────────────────────────────

pub const ScriptError = error{
    StackOverflow,
    StackUnderflow,
    InvalidScript,
    InvalidOpcode,
    VerifyFailed,
    ScriptFailed,
    DataTooLarge,
    CheckSigFailed,
    LockTimeNotMet,
};

// ─── ScriptVM — stack-based Bitcoin-compatible script virtual machine ────────

pub const ScriptVM = struct {
    stack: [256][80]u8, // 256 stack items, max 80 bytes each
    stack_sizes: [256]u8, // actual size of each item
    sp: u8, // stack pointer (points to next free slot)

    pub fn init() ScriptVM {
        return .{
            .stack = std.mem.zeroes([256][80]u8),
            .stack_sizes = std.mem.zeroes([256]u8),
            .sp = 0,
        };
    }

    /// Push data onto the stack
    pub fn push(self: *ScriptVM, data: []const u8) ScriptError!void {
        if (self.sp == 0 and self.stackFull()) return ScriptError.StackOverflow;
        if (data.len > 80) return ScriptError.DataTooLarge;
        if (self.sp == 255 and self.stack_sizes[255] != 0 and self.stackFull())
            return ScriptError.StackOverflow;
        const slot = self.sp;
        if (slot >= 256) return ScriptError.StackOverflow;
        @memcpy(self.stack[slot][0..data.len], data);
        if (data.len < 80) {
            @memset(self.stack[slot][data.len..80], 0);
        }
        self.stack_sizes[slot] = @intCast(data.len);
        self.sp +|= 1;
        return;
    }

    fn stackFull(self: *const ScriptVM) bool {
        return self.sp >= 255 and self.stack_sizes[255] != 0;
    }

    /// Pop top item from stack, returns a slice into internal buffer
    pub fn pop(self: *ScriptVM) ScriptError!struct { data: [80]u8, len: u8 } {
        if (self.sp == 0) return ScriptError.StackUnderflow;
        self.sp -= 1;
        return .{
            .data = self.stack[self.sp],
            .len = self.stack_sizes[self.sp],
        };
    }

    /// Peek at top item without removing
    pub fn peek(self: *ScriptVM) ScriptError!struct { data: [80]u8, len: u8 } {
        if (self.sp == 0) return ScriptError.StackUnderflow;
        return .{
            .data = self.stack[self.sp - 1],
            .len = self.stack_sizes[self.sp - 1],
        };
    }

    /// Push a boolean value (0x01 for true, empty for false)
    fn pushBool(self: *ScriptVM, val: bool) ScriptError!void {
        if (val) {
            try self.push(&[_]u8{0x01});
        } else {
            try self.push(&[_]u8{});
        }
    }

    /// Check if top of stack is "true" (non-zero, non-empty)
    fn isTrue(item: [80]u8, len: u8) bool {
        if (len == 0) return false;
        for (item[0..len]) |b| {
            if (b != 0) return true;
        }
        return false;
    }

    /// Execute a script (byte array of opcodes + data pushes)
    /// Returns true if script succeeds (stack top is truthy or stack is empty for
    /// vacuously-valid scripts)
    pub fn execute(self: *ScriptVM, script: []const u8, tx_hash: [32]u8, current_height: u64) ScriptError!bool {
        var pc: usize = 0;

        while (pc < script.len) {
            const byte = script[pc];
            pc += 1;

            // Direct data push: bytes 0x01..0x4b push that many bytes
            if (byte >= 0x01 and byte <= 0x4b) {
                const push_len: usize = byte;
                if (pc + push_len > script.len) return ScriptError.InvalidScript;
                try self.push(script[pc .. pc + push_len]);
                pc += push_len;
                continue;
            }

            // Try to interpret as opcode
            const opcode: OpCode = std.meta.intToEnum(OpCode, byte) catch {
                return ScriptError.InvalidOpcode;
            };

            switch (opcode) {
                .OP_0 => {
                    try self.push(&[_]u8{});
                },
                .OP_1 => {
                    try self.push(&[_]u8{0x01});
                },
                .OP_2 => {
                    try self.push(&[_]u8{0x02});
                },
                .OP_3 => {
                    try self.push(&[_]u8{0x03});
                },
                .OP_DUP => {
                    const top = try self.peek();
                    try self.push(top.data[0..top.len]);
                },
                .OP_DROP => {
                    _ = try self.pop();
                },
                .OP_SWAP => {
                    if (self.sp < 2) return ScriptError.StackUnderflow;
                    const idx_a = self.sp - 1;
                    const idx_b = self.sp - 2;
                    const tmp_data = self.stack[idx_a];
                    const tmp_size = self.stack_sizes[idx_a];
                    self.stack[idx_a] = self.stack[idx_b];
                    self.stack_sizes[idx_a] = self.stack_sizes[idx_b];
                    self.stack[idx_b] = tmp_data;
                    self.stack_sizes[idx_b] = tmp_size;
                },
                .OP_SHA256 => {
                    const top = try self.pop();
                    var hash: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(top.data[0..top.len], &hash, .{});
                    try self.push(&hash);
                },
                .OP_HASH160 => {
                    // SHA256 then RIPEMD160, identical to Bitcoin's Hash160
                    const top = try self.pop();
                    var sha_hash: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(top.data[0..top.len], &sha_hash, .{});
                    var hash160: [20]u8 = undefined;
                    Ripemd160.hash(&sha_hash, &hash160);
                    try self.push(&hash160);
                },
                .OP_CHECKSIG => {
                    // Stack: <sig> <pubkey> → bool
                    const pubkey_item = try self.pop();
                    const sig_item = try self.pop();

                    if (pubkey_item.len != 33 or sig_item.len != 64) {
                        try self.pushBool(false);
                    } else {
                        var pubkey: [33]u8 = undefined;
                        @memcpy(&pubkey, pubkey_item.data[0..33]);
                        var sig: [64]u8 = undefined;
                        @memcpy(&sig, sig_item.data[0..64]);
                        const valid = Secp256k1Crypto.verify(pubkey, &tx_hash, sig);
                        try self.pushBool(valid);
                    }
                },
                .OP_CHECKMULTISIG => {
                    // Simplified multisig: <sig1>...<sigN> <N> <pub1>...<pubM> <M>
                    // Requires N of M signatures valid
                    const m_item = try self.pop();
                    if (m_item.len != 1) return ScriptError.InvalidScript;
                    const m: usize = m_item.data[0];
                    if (m == 0 or m > 20) return ScriptError.InvalidScript;

                    // Pop M public keys
                    var pubkeys: [20][33]u8 = undefined;
                    for (0..m) |i| {
                        const pk = try self.pop();
                        if (pk.len != 33) return ScriptError.InvalidScript;
                        @memcpy(&pubkeys[m - 1 - i], pk.data[0..33]);
                    }

                    const n_item = try self.pop();
                    if (n_item.len != 1) return ScriptError.InvalidScript;
                    const n: usize = n_item.data[0];
                    if (n == 0 or n > m) return ScriptError.InvalidScript;

                    // Pop N signatures
                    var sigs: [20][64]u8 = undefined;
                    for (0..n) |i| {
                        const s = try self.pop();
                        if (s.len != 64) return ScriptError.InvalidScript;
                        @memcpy(&sigs[n - 1 - i], s.data[0..64]);
                    }

                    // Verify: each sig must match a pubkey in order
                    var pk_idx: usize = 0;
                    var matched: usize = 0;
                    for (0..n) |si| {
                        while (pk_idx < m) : (pk_idx += 1) {
                            if (Secp256k1Crypto.verify(pubkeys[pk_idx], &tx_hash, sigs[si])) {
                                pk_idx += 1;
                                matched += 1;
                                break;
                            }
                        }
                    }
                    try self.pushBool(matched == n);
                },
                .OP_EQUAL => {
                    const b_item = try self.pop();
                    const a_item = try self.pop();
                    const equal = (a_item.len == b_item.len) and
                        std.mem.eql(u8, a_item.data[0..a_item.len], b_item.data[0..b_item.len]);
                    try self.pushBool(equal);
                },
                .OP_EQUALVERIFY => {
                    const b_item = try self.pop();
                    const a_item = try self.pop();
                    const equal = (a_item.len == b_item.len) and
                        std.mem.eql(u8, a_item.data[0..a_item.len], b_item.data[0..b_item.len]);
                    if (!equal) return ScriptError.VerifyFailed;
                },
                .OP_VERIFY => {
                    const top = try self.pop();
                    if (!isTrue(top.data, top.len)) return ScriptError.VerifyFailed;
                },
                .OP_RETURN => {
                    // OP_RETURN makes the script unconditionally fail (unspendable)
                    return ScriptError.ScriptFailed;
                },
                .OP_CHECKLOCKTIMEVERIFY => {
                    // BIP-65: stack top is the required minimum block height
                    const top = try self.peek();
                    if (top.len == 0 or top.len > 8) return ScriptError.InvalidScript;
                    // Decode little-endian integer from stack
                    var required_height: u64 = 0;
                    for (0..top.len) |i| {
                        required_height |= @as(u64, top.data[i]) << @intCast(i * 8);
                    }
                    if (current_height < required_height) return ScriptError.LockTimeNotMet;
                    // Item stays on stack (per BIP-65 spec)
                },
                .OP_CHECKSEQUENCEVERIFY => {
                    // BIP-112: similar to CLTV but for relative locktime
                    // Simplified: treat as relative height check from stack
                    const top = try self.peek();
                    if (top.len == 0 or top.len > 8) return ScriptError.InvalidScript;
                    var required: u64 = 0;
                    for (0..top.len) |i| {
                        required |= @as(u64, top.data[i]) << @intCast(i * 8);
                    }
                    if (current_height < required) return ScriptError.LockTimeNotMet;
                },
                .OP_PUSHDATA1 => {
                    // Next byte is the length, then that many bytes of data
                    if (pc >= script.len) return ScriptError.InvalidScript;
                    const push_len: usize = script[pc];
                    pc += 1;
                    if (pc + push_len > script.len) return ScriptError.InvalidScript;
                    if (push_len > 80) return ScriptError.DataTooLarge;
                    try self.push(script[pc .. pc + push_len]);
                    pc += push_len;
                },
                .OP_PUSHDATA2 => {
                    // Next 2 bytes (LE) are the length, then that many bytes
                    if (pc + 2 > script.len) return ScriptError.InvalidScript;
                    const push_len: usize = @as(u16, script[pc]) | (@as(u16, script[pc + 1]) << 8);
                    pc += 2;
                    if (pc + push_len > script.len) return ScriptError.InvalidScript;
                    if (push_len > 80) return ScriptError.DataTooLarge;
                    try self.push(script[pc .. pc + push_len]);
                    pc += push_len;
                },
            }
        }

        // Script succeeds if stack is empty (vacuously valid) or top is truthy
        if (self.sp == 0) return true;
        const top = try self.peek();
        return isTrue(top.data, top.len);
    }
};

// ─── Standard Script Constructors ───────────────────────────────────────────

/// Create standard P2PKH locking script:
/// OP_DUP OP_HASH160 <20-byte pubkey_hash> OP_EQUALVERIFY OP_CHECKSIG
pub fn createP2PKH(pubkey_hash: [20]u8) [25]u8 {
    var script: [25]u8 = undefined;
    script[0] = @intFromEnum(OpCode.OP_DUP); // 0x76
    script[1] = @intFromEnum(OpCode.OP_HASH160); // 0xa9
    script[2] = 0x14; // push 20 bytes
    @memcpy(script[3..23], &pubkey_hash);
    script[23] = @intFromEnum(OpCode.OP_EQUALVERIFY); // 0x88
    script[24] = @intFromEnum(OpCode.OP_CHECKSIG); // 0xac
    return script;
}

/// Create P2PKH unlocking script: <64-byte sig> <33-byte pubkey>
/// Layout: [push 64] [sig...] [push 33] [pubkey...]
pub fn createP2PKHUnlock(signature: [64]u8, pubkey: [33]u8) [99]u8 {
    var script: [99]u8 = undefined;
    script[0] = 0x40; // push 64 bytes (0x40 = 64, within 0x01..0x4b range)
    @memcpy(script[1..65], &signature);
    script[65] = 0x21; // push 33 bytes (0x21 = 33)
    @memcpy(script[66..99], &pubkey);
    return script;
}

/// Create P2SH locking script: OP_HASH160 <20-byte script_hash> OP_EQUAL
pub fn createP2SH(script_hash: [20]u8) [23]u8 {
    var script: [23]u8 = undefined;
    script[0] = @intFromEnum(OpCode.OP_HASH160);
    script[1] = 0x14; // push 20 bytes
    @memcpy(script[2..22], &script_hash);
    script[22] = @intFromEnum(OpCode.OP_EQUAL);
    return script;
}

/// Create OP_RETURN data carrier script
pub fn createOpReturn(data: []const u8) ScriptError![82]u8 {
    if (data.len > 80) return ScriptError.DataTooLarge;
    var script: [82]u8 = std.mem.zeroes([82]u8);
    script[0] = @intFromEnum(OpCode.OP_RETURN);
    script[1] = @intCast(data.len); // push N bytes
    @memcpy(script[2 .. 2 + data.len], data);
    return script;
}

/// Create a multisig redeem script: OP_0 (dummy) is expected to be pushed by the unlock script,
/// followed by M signatures; the lock script encodes M <pubkeys...> N OP_CHECKMULTISIG.
/// Returns the lock script and its actual length.
/// Max size: 1 (M) + N*(1+33) (push+pubkey) + 1 (N) + 1 (OP_CHECKMULTISIG) = 3 + N*34
/// For N=16: 3 + 16*34 = 547 bytes. We cap at 20 pubkeys for safety.
pub const MAX_MULTISIG_SCRIPT_LEN: usize = 3 + 20 * 34;

pub fn createMultisigLockScript(
    m: u8,
    pubkeys: []const [33]u8,
) struct { script: [MAX_MULTISIG_SCRIPT_LEN]u8, len: usize } {
    var script: [MAX_MULTISIG_SCRIPT_LEN]u8 = std.mem.zeroes([MAX_MULTISIG_SCRIPT_LEN]u8);
    var pos: usize = 0;

    // Push M (OP_1..OP_3 for 1..3, or direct push for larger values)
    if (m >= 1 and m <= 3) {
        script[pos] = @intFromEnum(OpCode.OP_0) + m; // OP_1=0x51, OP_2=0x52, OP_3=0x53
        pos += 1;
    } else {
        script[pos] = 0x01; // push 1 byte
        pos += 1;
        script[pos] = m;
        pos += 1;
    }

    // Push each pubkey (33 bytes each)
    for (pubkeys) |pk| {
        script[pos] = 0x21; // push 33 bytes
        pos += 1;
        @memcpy(script[pos .. pos + 33], &pk);
        pos += 33;
    }

    // Push N
    const n: u8 = @intCast(pubkeys.len);
    if (n >= 1 and n <= 3) {
        script[pos] = @intFromEnum(OpCode.OP_0) + n;
        pos += 1;
    } else {
        script[pos] = 0x01;
        pos += 1;
        script[pos] = n;
        pos += 1;
    }

    // OP_CHECKMULTISIG
    script[pos] = @intFromEnum(OpCode.OP_CHECKMULTISIG);
    pos += 1;

    return .{ .script = script, .len = pos };
}

/// Validate P2PKH: run unlock_script then lock_script on the same VM.
/// Returns true if the combined execution leaves a truthy value on stack.
pub fn validateScripts(unlock: []const u8, lock: []const u8, tx_hash: [32]u8, height: u64) bool {
    var vm = ScriptVM.init();
    // Execute unlock script (pushes sig + pubkey onto stack)
    _ = vm.execute(unlock, tx_hash, height) catch return false;
    // Execute lock script (consumes sig + pubkey, verifies)
    const result = vm.execute(lock, tx_hash, height) catch return false;
    return result;
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "script — empty script returns true (vacuously valid)" {
    var vm = ScriptVM.init();
    const result = try vm.execute(&[_]u8{}, [_]u8{0} ** 32, 0);
    try testing.expect(result);
}

test "script — OP_DUP duplicates top item" {
    var vm = ScriptVM.init();
    try vm.push(&[_]u8{ 0xAA, 0xBB });
    const script = [_]u8{@intFromEnum(OpCode.OP_DUP)};
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    // push set sp=1, then execute sees OP_DUP, peeks and pushes -> sp=2
    try testing.expectEqual(@as(u8, 2), vm.sp);
    const top = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, top.data[0..top.len]);
    const second = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, second.data[0..second.len]);
}

test "script — OP_HASH160 produces 20-byte hash" {
    var vm = ScriptVM.init();
    // Push some data, then OP_HASH160
    const script = [_]u8{
        0x04, 0xDE, 0xAD, 0xBE, 0xEF, // push 4 bytes
        @intFromEnum(OpCode.OP_HASH160),
    };
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    const top = try vm.pop();
    try testing.expectEqual(@as(u8, 20), top.len);
}

test "script — OP_SHA256 produces 32-byte hash" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x03, 0x01, 0x02, 0x03, // push 3 bytes
        @intFromEnum(OpCode.OP_SHA256),
    };
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    const top = try vm.pop();
    try testing.expectEqual(@as(u8, 32), top.len);
}

test "script — OP_EQUAL compares two items (true)" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x02, 0xAA, 0xBB, // push 2 bytes
        0x02, 0xAA, 0xBB, // push 2 bytes (same)
        @intFromEnum(OpCode.OP_EQUAL),
    };
    const result = try vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expect(result);
}

test "script — OP_EQUAL compares two items (false)" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x02, 0xAA, 0xBB, // push 2 bytes
        0x02, 0xCC, 0xDD, // push 2 bytes (different)
        @intFromEnum(OpCode.OP_EQUAL),
    };
    const result = try vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expect(!result);
}

test "script — OP_EQUALVERIFY fails on mismatch" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x02, 0xAA, 0xBB,
        0x02, 0xCC, 0xDD,
        @intFromEnum(OpCode.OP_EQUALVERIFY),
    };
    const result = vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expectError(ScriptError.VerifyFailed, result);
}

test "script — OP_EQUALVERIFY succeeds on match" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x02, 0xAA, 0xBB,
        0x02, 0xAA, 0xBB,
        @intFromEnum(OpCode.OP_EQUALVERIFY),
    };
    // After EQUALVERIFY, stack is empty → vacuously true
    const result = try vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expect(result);
}

test "script — OP_RETURN always fails (unspendable)" {
    var vm = ScriptVM.init();
    const script = [_]u8{@intFromEnum(OpCode.OP_RETURN)};
    const result = vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expectError(ScriptError.ScriptFailed, result);
}

test "script — OP_CHECKLOCKTIMEVERIFY rejects if height too low" {
    var vm = ScriptVM.init();
    // Push height 100 (little-endian), then CLTV
    const script = [_]u8{
        0x01, 100, // push 1 byte: 100
        @intFromEnum(OpCode.OP_CHECKLOCKTIMEVERIFY),
    };
    // Current height = 50, required = 100 → should fail
    const result = vm.execute(&script, [_]u8{0} ** 32, 50);
    try testing.expectError(ScriptError.LockTimeNotMet, result);
}

test "script — OP_CHECKLOCKTIMEVERIFY passes if height sufficient" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x01, 100,
        @intFromEnum(OpCode.OP_CHECKLOCKTIMEVERIFY),
    };
    const result = try vm.execute(&script, [_]u8{0} ** 32, 100);
    try testing.expect(result);
}

test "script — OP_CHECKSIG verifies ECDSA signature" {
    const kp = try Secp256k1Crypto.generateKeyPair();
    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("test transaction", &tx_hash, .{});
    const sig = try Secp256k1Crypto.sign(kp.private_key, &tx_hash);

    var vm = ScriptVM.init();
    // Push sig (64 bytes) then pubkey (33 bytes) then OP_CHECKSIG
    try vm.push(&sig);
    try vm.push(&kp.public_key);
    const script = [_]u8{@intFromEnum(OpCode.OP_CHECKSIG)};
    const result = try vm.execute(&script, tx_hash, 0);
    try testing.expect(result);
}

test "script — OP_CHECKSIG fails with wrong signature" {
    const kp = try Secp256k1Crypto.generateKeyPair();
    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("test transaction", &tx_hash, .{});

    // Sign a different message
    var wrong_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("wrong transaction", &wrong_hash, .{});
    const sig = try Secp256k1Crypto.sign(kp.private_key, &wrong_hash);

    var vm = ScriptVM.init();
    try vm.push(&sig);
    try vm.push(&kp.public_key);
    const script = [_]u8{@intFromEnum(OpCode.OP_CHECKSIG)};
    const result = try vm.execute(&script, tx_hash, 0);
    try testing.expect(!result);
}

test "script — P2PKH full flow" {
    // Generate keypair
    const kp = try Secp256k1Crypto.generateKeyPair();

    // Compute Hash160(pubkey)
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);

    // Create locking script: OP_DUP OP_HASH160 <hash> OP_EQUALVERIFY OP_CHECKSIG
    const lock_script = createP2PKH(pubkey_hash);

    // Create tx hash and sign it
    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("P2PKH test tx", &tx_hash, .{});
    const sig = try Secp256k1Crypto.sign(kp.private_key, &tx_hash);

    // Create unlocking script: <sig> <pubkey>
    const unlock_script = createP2PKHUnlock(sig, kp.public_key);

    // Validate
    const valid = validateScripts(&unlock_script, &lock_script, tx_hash, 0);
    try testing.expect(valid);
}

test "script — P2PKH fails with wrong key" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    // Lock to kp1's hash
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp1.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = createP2PKH(pubkey_hash);

    // Try to unlock with kp2's key
    var tx_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("P2PKH wrong key test", &tx_hash, .{});
    const sig = try Secp256k1Crypto.sign(kp2.private_key, &tx_hash);
    const unlock_script = createP2PKHUnlock(sig, kp2.public_key);

    // Should fail — pubkey hash doesn't match
    const valid = validateScripts(&unlock_script, &lock_script, tx_hash, 0);
    try testing.expect(!valid);
}

test "script — stack overflow returns error" {
    var vm = ScriptVM.init();
    // Fill the stack
    for (0..256) |_| {
        try vm.push(&[_]u8{0x01});
    }
    // One more should overflow
    const result = vm.push(&[_]u8{0x01});
    try testing.expectError(ScriptError.StackOverflow, result);
}

test "script — stack underflow returns error" {
    var vm = ScriptVM.init();
    const result = vm.pop();
    try testing.expectError(ScriptError.StackUnderflow, result);
}

test "script — OP_DROP removes top item" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x01, 0xAA, // push 1 byte
        0x01, 0xBB, // push 1 byte
        @intFromEnum(OpCode.OP_DROP),
    };
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expectEqual(@as(u8, 1), vm.sp);
    const top = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{0xAA}, top.data[0..top.len]);
}

test "script — OP_SWAP swaps top two items" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        0x01, 0xAA,
        0x01, 0xBB,
        @intFromEnum(OpCode.OP_SWAP),
    };
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    const top = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{0xAA}, top.data[0..top.len]);
    const second = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{0xBB}, second.data[0..second.len]);
}

test "script — OP_VERIFY with true succeeds" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        @intFromEnum(OpCode.OP_1),
        @intFromEnum(OpCode.OP_VERIFY),
    };
    const result = try vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expect(result); // stack empty = vacuously true
}

test "script — OP_VERIFY with false fails" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        @intFromEnum(OpCode.OP_0),
        @intFromEnum(OpCode.OP_VERIFY),
    };
    const result = vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expectError(ScriptError.VerifyFailed, result);
}

test "script — PUSHDATA1 pushes variable-length data" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        @intFromEnum(OpCode.OP_PUSHDATA1),
        0x03, // length
        0xDE, 0xAD, 0xFF,
    };
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    const top = try vm.pop();
    try testing.expectEqual(@as(u8, 3), top.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD, 0xFF }, top.data[0..3]);
}

test "script — constants OP_0, OP_1, OP_2, OP_3" {
    var vm = ScriptVM.init();
    const script = [_]u8{
        @intFromEnum(OpCode.OP_0),
        @intFromEnum(OpCode.OP_1),
        @intFromEnum(OpCode.OP_2),
        @intFromEnum(OpCode.OP_3),
    };
    _ = try vm.execute(&script, [_]u8{0} ** 32, 0);
    try testing.expectEqual(@as(u8, 4), vm.sp);

    const v3 = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, v3.data[0..v3.len]);
    const v2 = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{0x02}, v2.data[0..v2.len]);
    const v1 = try vm.pop();
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, v1.data[0..v1.len]);
    const v0 = try vm.pop();
    try testing.expectEqual(@as(u8, 0), v0.len); // OP_0 pushes empty
}
