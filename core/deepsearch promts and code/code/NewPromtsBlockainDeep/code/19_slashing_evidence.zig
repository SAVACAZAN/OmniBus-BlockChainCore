// ============================================
// 10. core/double_ratchet.zig
// ============================================
const std = @import("std");
const crypto = std.crypto;
const sha256 = crypto.hash.sha2.Sha256;

pub const DoubleRatchetError = error{
    OutOfOrderMessage,
    TooManySkippedMessages,
};

pub const SymmetricKey = [32]u8;

pub const RootChain = struct {
    root_key: SymmetricKey,
    
    pub fn init(root_key: SymmetricKey) RootChain {
        return RootChain{ .root_key = root_key };
    }
    
    pub fn step(self: *RootChain, dh_output: SymmetricKey) struct { send_key: SymmetricKey, recv_key: SymmetricKey } {
        var kdf_input: [64]u8 = undefined;
        @memcpy(kdf_input[0..32], &self.root_key);
        @memcpy(kdf_input[32..64], &dh_output);
        
        var output: [64]u8 = undefined;
        sha256.hash(&kdf_input, &output, .{});
        
        self.root_key = output[0..32].*;
        var send_key: SymmetricKey = undefined;
        var recv_key: SymmetricKey = undefined;
        @memcpy(&send_key, output[32..64]);
        @memcpy(&recv_key, output[0..32]);
        
        return .{ .send_key = send_key, .recv_key = recv_key };
    }
};

pub const SendingChain = struct {
    chain_key: SymmetricKey,
    message_number: u32,
    
    pub fn init(chain_key: SymmetricKey) SendingChain {
        return SendingChain{
            .chain_key = chain_key,
            .message_number = 0,
        };
    }
    
    pub fn nextKey(self: *SendingChain) struct { message_key: SymmetricKey, next_chain_key: SymmetricKey } {
        var kdf_input: [64]u8 = undefined;
        @memcpy(kdf_input[0..32], &self.chain_key);
        @memcpy(kdf_input[32..64], std.mem.asBytes(&self.message_number));
        
        var output: [64]u8 = undefined;
        sha256.hash(&kdf_input, &output, .{});
        
        var message_key: SymmetricKey = undefined;
        var next_chain_key: SymmetricKey = undefined;
        @memcpy(&message_key, output[0..32]);
        @memcpy(&next_chain_key, output[32..64]);
        
        self.message_number += 1;
        self.chain_key = next_chain_key;
        
        return .{ .message_key = message_key, .next_chain_key = next_chain_key };
    }
};

pub const ReceivingChain = struct {
    chain_key: SymmetricKey,
    message_number: u32,
    skipped_keys: std.AutoHashMap(u32, SymmetricKey),
    
    pub fn init(allocator: std.mem.Allocator, chain_key: SymmetricKey) ReceivingChain {
        return ReceivingChain{
            .chain_key = chain_key,
            .message_number = 0,
            .skipped_keys = std.AutoHashMap(u32, SymmetricKey).init(allocator),
        };
    }
    
    pub fn deinit(self: *ReceivingChain) void {
        self.skipped_keys.deinit();
    }
    
    pub fn trySkip(self: *ReceivingChain, until: u32) !void {
        if (until <= self.message_number) return;
        
        var n = self.message_number;
        while (n < until) : (n += 1) {
            if (self.skipped_keys.count() > 1000) {
                return error.TooManySkippedMessages;
            }
            const key_pair = self.nextKey();
            try self.skipped_keys.put(n, key_pair.message_key);
        }
        self.message_number = until;
    }
    
    pub fn nextKey(self: *ReceivingChain) struct { message_key: SymmetricKey, next_chain_key: SymmetricKey } {
        var kdf_input: [64]u8 = undefined;
        @memcpy(kdf_input[0..32], &self.chain_key);
        @memcpy(kdf_input[32..64], std.mem.asBytes(&self.message_number));
        
        var output: [64]u8 = undefined;
        sha256.hash(&kdf_input, &output, .{});
        
        var message_key: SymmetricKey = undefined;
        var next_chain_key: SymmetricKey = undefined;
        @memcpy(&message_key, output[0..32]);
        @memcpy(&next_chain_key, output[32..64]);
        
        self.message_number += 1;
        self.chain_key = next_chain_key;
        
        return .{ .message_key = message_key, .next_chain_key = next_chain_key };
    }
    
    pub fn receiveKey(self: *ReceivingChain, message_number: u32) !SymmetricKey {
        if (self.skipped_keys.get(message_number)) |key| {
            return key;
        }
        if (message_number == self.message_number) {
            const key_pair = self.nextKey();
            return key_pair.message_key;
        }
        return error.OutOfOrderMessage;
    }
};

pub const DoubleRatchet = struct {
    allocator: std.mem.Allocator,
    root_chain: RootChain,
    sending_chain: SendingChain,
    receiving_chain: ReceivingChain,
    
    pub fn init(
        allocator: std.mem.Allocator,
        root_key: SymmetricKey,
        send_key: SymmetricKey,
        recv_key: SymmetricKey,
    ) DoubleRatchet {
        return DoubleRatchet{
            .allocator = allocator,
            .root_chain = RootChain.init(root_key),
            .sending_chain = SendingChain.init(send_key),
            .receiving_chain = ReceivingChain.init(allocator, recv_key),
        };
    }
    
    pub fn deinit(self: *DoubleRatchet) void {
        self.receiving_chain.deinit();
    }
    
    pub fn encrypt(self: *DoubleRatchet, plaintext: []const u8) !struct { ciphertext: []u8, header: u32 } {
        const key_pair = self.sending_chain.nextKey();
        const message_number = self.sending_chain.message_number - 1;
        
        // Simulate encryption with message_key
        var ciphertext = try self.allocator.alloc(u8, plaintext.len);
        @memcpy(ciphertext, plaintext);
        
        return .{ .ciphertext = ciphertext, .header = message_number };
    }
    
    pub fn decrypt(self: *DoubleRatchet, ciphertext: []const u8, message_number: u32) ![]u8 {
        const message_key = try self.receiving_chain.receiveKey(message_number);
        _ = message_key;
        
        // Simulate decryption
        var plaintext = try self.allocator.alloc(u8, ciphertext.len);
        @memcpy(plaintext, ciphertext);
        
        return plaintext;
    }
};

test "Double ratchet basic" {
    var allocator = std.testing.allocator;
    const root_key = [_]u8{0} ** 32;
    const send_key = [_]u8{1} ** 32;
    const recv_key = [_]u8{2} ** 32;
    
    var dr = DoubleRatchet.init(allocator, root_key, send_key, recv_key);
    defer dr.deinit();
    
    const msg = "Hello secure channel";
    const encrypted = try dr.encrypt(msg);
    defer allocator.free(encrypted.ciphertext);
    
    const decrypted = try dr.decrypt(encrypted.ciphertext, encrypted.header);
    defer allocator.free(decrypted);
    
    try std.testing.expect(std.mem.eql(u8, msg, decrypted));
}