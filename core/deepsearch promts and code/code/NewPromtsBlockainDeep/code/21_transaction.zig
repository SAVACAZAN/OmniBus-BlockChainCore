// ============================================
// Extensie pentru core/evm_signer.zig (adaugă EIP-1559)
// ============================================
// Adaugă acest cod la sfârșitul fișierului core/evm_signer.zig

pub const Eip1559Tx = struct {
    chain_id: u64,
    nonce: u64,
    max_priority_fee_per_gas: u128,
    max_fee_per_gas: u128,
    gas_limit: u64,
    to: ?[20]u8,
    value: u128,
    data: []const u8,
    access_list: []AccessListEntry,
    
    pub fn deinit(self: *Eip1559Tx, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        for (self.access_list) |entry| {
            allocator.free(entry.storage_keys);
        }
        allocator.free(self.access_list);
    }
};

pub const AccessListEntry = struct {
    address: [20]u8,
    storage_keys: [][32]u8,
};

pub fn rlpEncodeEip1559(tx: *const Eip1559Tx, allocator: std.mem.Allocator) ![]u8 {
    var rlp = std.ArrayList(u8).init(allocator);
    defer rlp.deinit();
    
    // Prefix 0x02 for EIP-1559
    try rlp.append(0x02);
    
    // RLP list of fields
    try rlp.append(0xf8); // List prefix
    
    var fields = std.ArrayList(u8).init(allocator);
    defer fields.deinit();
    
    // chain_id
    try fields.appendSlice(rlpEncodeU64(tx.chain_id, allocator));
    // nonce
    try fields.appendSlice(rlpEncodeU64(tx.nonce, allocator));
    // max_priority_fee_per_gas
    try fields.appendSlice(rlpEncodeU128(tx.max_priority_fee_per_gas, allocator));
    // max_fee_per_gas
    try fields.appendSlice(rlpEncodeU128(tx.max_fee_per_gas, allocator));
    // gas_limit
    try fields.appendSlice(rlpEncodeU64(tx.gas_limit, allocator));
    // to
    if (tx.to) |addr| {
        try fields.append(0x94); // 0x80 + 20
        try fields.appendSlice(&addr);
    } else {
        try fields.append(0x80); // empty string
    }
    // value
    try fields.appendSlice(rlpEncodeU128(tx.value, allocator));
    // data
    try fields.appendSlice(rlpEncodeBytes(tx.data, allocator));
    // access_list
    try fields.appendSlice(rlpEncodeAccessList(tx.access_list, allocator));
    
    try rlp.appendSlice(fields.items);
    return rlp.toOwnedSlice();
}

fn rlpEncodeU64(val: u64, _: std.mem.Allocator) []const u8 {
    if (val == 0) return &[_]u8{0x80};
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, val, .big);
    var i: usize = 0;
    while (i < 8 and buf[i] == 0) i += 1;
    return buf[i..];
}

fn rlpEncodeU128(val: u128, _: std.mem.Allocator) []const u8 {
    if (val == 0) return &[_]u8{0x80};
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u128, &buf, val, .big);
    var i: usize = 0;
    while (i < 16 and buf[i] == 0) i += 1;
    return buf[i..];
}

fn rlpEncodeBytes(bytes: []const u8, _: std.mem.Allocator) []const u8 {
    if (bytes.len == 0) return &[_]u8{0x80};
    if (bytes.len == 1 and bytes[0] < 0x80) return bytes;
    return bytes;
}

fn rlpEncodeAccessList(list: []AccessListEntry, allocator: std.mem.Allocator) ![]const u8 {
    if (list.len == 0) return &[_]u8{0xc0}; // empty list
    
    var rlp = std.ArrayList(u8).init(allocator);
    defer rlp.deinit();
    
    for (list) |entry| {
        try rlp.appendSlice(&entry.address);
        var keys_rlp = std.ArrayList(u8).init(allocator);
        defer keys_rlp.deinit();
        for (entry.storage_keys) |key| {
            try keys_rlp.appendSlice(&key);
        }
        try rlp.appendSlice(keys_rlp.items);
    }
    
    return rlp.toOwnedSlice();
}

pub fn signEip1559(
    tx: Eip1559Tx,
    private_key: [32]u8,
    allocator: std.mem.Allocator,
) !struct { r: [32]u8, s: [32]u8, v: u8 } {
    const encoded = try rlpEncodeEip1559(&tx, allocator);
    defer allocator.free(encoded);
    
    var hasher = std.crypto.hash.keccak.Keccak256.init(.{});
    hasher.update(encoded);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    
    // Sign with secp256k1
    const sig = try secp256k1.sign(&hash, private_key);
    
    // recovery_id (v = 0 or 1)
    const v: u8 = 0;
    
    return .{ .r = sig.r, .s = sig.s, .v = v };
}