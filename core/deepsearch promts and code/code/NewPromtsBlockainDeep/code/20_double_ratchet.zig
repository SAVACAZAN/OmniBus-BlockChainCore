// ============================================
// Extensie pentru core/transaction.zig (adaugă la sfârșit)
// ============================================
// Adaugă acest cod la sfârșitul fișierului core/transaction.zig

pub const SighashFlag = enum(u8) {
    ALL = 0x01,
    NONE = 0x02,
    SINGLE = 0x03,
    ANYONECANPAY_ALL = 0x81,
    ANYONECANPAY_NONE = 0x82,
    ANYONECANPAY_SINGLE = 0x83,
};

pub fn computeSighash(
    tx: *const Transaction,
    input_index: usize,
    flag: SighashFlag,
    script_code: ?[]const u8,
    amount: ?u64,
) ![32]u8 {
    const is_anyone_can_pay = @intFromEnum(flag) & 0x80 != 0;
    const base_flag = @intFromEnum(flag) & 0x1F;
    
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    
    // Version
    hasher.update(std.mem.asBytes(&tx.version));
    
    // Inputs
    if (is_anyone_can_pay) {
        hasher.update(std.mem.asBytes(&@as(u32, 1)));
        // Hash single input logic
    } else {
        hasher.update(std.mem.asBytes(&@as(u32, @intCast(tx.inputs.len))));
        for (tx.inputs, 0..) |input, i| {
            _ = input;
            _ = i;
            // Hash each input
        }
    }
    
    // Outputs based on base_flag
    switch (base_flag) {
        0x01 => { // ALL
            hasher.update(std.mem.asBytes(&@as(u32, @intCast(tx.outputs.len))));
        },
        0x02 => { // NONE
            hasher.update(std.mem.asBytes(&@as(u32, 0)));
        },
        0x03 => { // SINGLE
            if (input_index >= tx.outputs.len) {
                return [_]u8{0xFF} ** 32;
            }
            hasher.update(std.mem.asBytes(&@as(u32, @intCast(tx.outputs.len))));
        },
        else => {},
    }
    
    // Locktime
    hasher.update(std.mem.asBytes(&tx.locktime));
    hasher.update(&[_]u8{@intFromEnum(flag)});
    
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}