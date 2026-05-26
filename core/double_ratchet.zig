//! Double Ratchet — KDF chain Signal-style pentru forward secrecy.
//!
//! Folosit de encrypted_p2p (cu PQ hybrid key) ca să rotească session keys per
//! mesaj. AEAD propriu-zis (AES-GCM/ChaCha20) e responsabilitatea call-site-ului;
//! aici doar derivăm message keys din chain keys.
//!
//! Notă: simplificare față de Signal — fără ratchet DH între mesaje, doar
//! symmetric chain ratchet (suficient pentru un session în P2P).

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const RatchetError = error{
    OutOfOrderMessage,
    TooManySkippedMessages,
    HandshakeNotComplete,
};

pub const SymmetricKey = [32]u8;

pub const MAX_SKIPPED_KEYS: usize = 1000;

/// KDF: out[0..32] = HMAC-like Sha256(chain_key || msg_num), folosit ca message key.
/// out[32..64] = Sha256(chain_key || 0xFF), folosit ca next chain key.
/// Două hash-uri separate ca să nu existe corelație directă între message key și next.
fn kdfChainStep(chain_key: SymmetricKey, msg_num: u32) struct {
    message_key: SymmetricKey,
    next_chain_key: SymmetricKey,
} {
    var msg_input: [36]u8 = undefined;
    @memcpy(msg_input[0..32], &chain_key);
    std.mem.writeInt(u32, msg_input[32..36], msg_num, .little);
    var message_key: SymmetricKey = undefined;
    Sha256.hash(&msg_input, &message_key, .{});

    var chain_input: [33]u8 = undefined;
    @memcpy(chain_input[0..32], &chain_key);
    chain_input[32] = 0xFF;
    var next_chain_key: SymmetricKey = undefined;
    Sha256.hash(&chain_input, &next_chain_key, .{});

    return .{ .message_key = message_key, .next_chain_key = next_chain_key };
}

pub const SendingChain = struct {
    chain_key: SymmetricKey,
    message_number: u32 = 0,

    pub fn init(chain_key: SymmetricKey) SendingChain {
        return .{ .chain_key = chain_key };
    }

    /// Derivă următorul message key, avansează chain. Mesaj #N va folosi această cheie.
    pub fn nextMessageKey(self: *SendingChain) struct { message_key: SymmetricKey, message_number: u32 } {
        const step = kdfChainStep(self.chain_key, self.message_number);
        const n = self.message_number;
        self.chain_key = step.next_chain_key;
        self.message_number += 1;
        return .{ .message_key = step.message_key, .message_number = n };
    }
};

pub const ReceivingChain = struct {
    allocator: std.mem.Allocator,
    chain_key: SymmetricKey,
    message_number: u32 = 0,
    /// Mesaje sărite (sosite out-of-order ulterior) — cache key per msg_num.
    skipped_keys: std.AutoHashMap(u32, SymmetricKey),

    pub fn init(allocator: std.mem.Allocator, chain_key: SymmetricKey) ReceivingChain {
        return .{
            .allocator = allocator,
            .chain_key = chain_key,
            .skipped_keys = std.AutoHashMap(u32, SymmetricKey).init(allocator),
        };
    }

    pub fn deinit(self: *ReceivingChain) void {
        self.skipped_keys.deinit();
    }

    /// Avansează chain până la `until` (exclusiv), cache-ând keys pentru mesaje sărite.
    fn skipMessageKeys(self: *ReceivingChain, until: u32) !void {
        if (until <= self.message_number) return;
        while (self.message_number < until) {
            if (self.skipped_keys.count() >= MAX_SKIPPED_KEYS) {
                return error.TooManySkippedMessages;
            }
            const step = kdfChainStep(self.chain_key, self.message_number);
            try self.skipped_keys.put(self.message_number, step.message_key);
            self.chain_key = step.next_chain_key;
            self.message_number += 1;
        }
    }

    /// Cheie pentru mesajul `msg_num`. Suportă out-of-order via skipped_keys.
    pub fn keyForMessage(self: *ReceivingChain, msg_num: u32) !SymmetricKey {
        if (self.skipped_keys.fetchRemove(msg_num)) |kv| {
            return kv.value;
        }
        if (msg_num < self.message_number) return error.OutOfOrderMessage;

        // Sărim peste keys lipsă pentru mesajele intermediare.
        try self.skipMessageKeys(msg_num);

        // Derivăm cheia pentru msg_num exact.
        const step = kdfChainStep(self.chain_key, self.message_number);
        self.chain_key = step.next_chain_key;
        self.message_number += 1;
        return step.message_key;
    }
};

// ============================================================
// Tests
// ============================================================

test "send and receive in order: keys match" {
    const root: SymmetricKey = [_]u8{0xAB} ** 32;

    var sender = SendingChain.init(root);
    var receiver = ReceivingChain.init(std.testing.allocator, root);
    defer receiver.deinit();

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const s = sender.nextMessageKey();
        const r = try receiver.keyForMessage(s.message_number);
        try std.testing.expectEqual(s.message_key, r);
    }
}

test "out of order: cache works" {
    const root: SymmetricKey = [_]u8{0xCD} ** 32;

    var sender = SendingChain.init(root);
    var receiver = ReceivingChain.init(std.testing.allocator, root);
    defer receiver.deinit();

    // Sender derivă 3 keys
    const k0 = sender.nextMessageKey();
    const k1 = sender.nextMessageKey();
    const k2 = sender.nextMessageKey();

    // Receiver primește mesajul #2 primul (#0 și #1 sunt sărite în cache)
    const r2 = try receiver.keyForMessage(k2.message_number);
    try std.testing.expectEqual(k2.message_key, r2);
    try std.testing.expectEqual(@as(usize, 2), receiver.skipped_keys.count());

    // Apoi #0 (din cache)
    const r0 = try receiver.keyForMessage(k0.message_number);
    try std.testing.expectEqual(k0.message_key, r0);
    try std.testing.expectEqual(@as(usize, 1), receiver.skipped_keys.count());

    // Apoi #1
    const r1 = try receiver.keyForMessage(k1.message_number);
    try std.testing.expectEqual(k1.message_key, r1);
    try std.testing.expectEqual(@as(usize, 0), receiver.skipped_keys.count());
}

test "reusing already-consumed message rejected" {
    const root: SymmetricKey = [_]u8{0xEF} ** 32;

    var sender = SendingChain.init(root);
    var receiver = ReceivingChain.init(std.testing.allocator, root);
    defer receiver.deinit();

    const k0 = sender.nextMessageKey();
    _ = try receiver.keyForMessage(k0.message_number);

    // Re-primire #0 = out-of-order (chain a avansat, nu mai e in cache).
    try std.testing.expectError(error.OutOfOrderMessage, receiver.keyForMessage(k0.message_number));
}

test "skipped key limit enforced" {
    const root: SymmetricKey = [_]u8{0x12} ** 32;
    var receiver = ReceivingChain.init(std.testing.allocator, root);
    defer receiver.deinit();

    // Cerem direct key pentru msg #(MAX+1) — ar trebui să sară prea multe.
    try std.testing.expectError(
        error.TooManySkippedMessages,
        receiver.keyForMessage(@intCast(MAX_SKIPPED_KEYS + 5)),
    );
}

test "different chain keys produce different message keys" {
    var s1 = SendingChain.init([_]u8{1} ** 32);
    var s2 = SendingChain.init([_]u8{2} ** 32);

    const k1 = s1.nextMessageKey();
    const k2 = s2.nextMessageKey();
    try std.testing.expect(!std.mem.eql(u8, &k1.message_key, &k2.message_key));
}
