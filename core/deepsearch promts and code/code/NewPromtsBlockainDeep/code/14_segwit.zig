// ============================================
// 5. core/pq_handshake.zig
// ============================================
const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = std.crypto;
const X25519 = crypto.dh.X25519;
const sha256 = crypto.hash.sha2.Sha256;

// Placeholder for liboqs wrapper
const pq_crypto = @import("pq_crypto.zig");

pub const HandshakeError = error{
    InvalidCiphertext,
    KeyMismatch,
    DecapsulationFailed,
};

pub const HybridKeyPair = struct {
    classic_private: [32]u8,
    classic_public: [32]u8,
    pq_private: []u8,
    pq_public: []u8,
    
    pub fn init(allocator: Allocator) !HybridKeyPair {
        var classic_private: [32]u8 = undefined;
        var classic_public: [32]u8 = undefined;
        try X25519.KeyPair.create(&classic_private, &classic_public);
        
        const pq_keys = try pq_crypto.MLKEM768.keypair(allocator);
        
        return HybridKeyPair{
            .classic_private = classic_private,
            .classic_public = classic_public,
            .pq_private = pq_keys.private,
            .pq_public = pq_keys.public,
        };
    }
    
    pub fn deinit(self: *HybridKeyPair, allocator: Allocator) void {
        allocator.free(self.pq_private);
        allocator.free(self.pq_public);
    }
};

pub const HandshakeState = enum {
    Init,
    SentEphemeral,
    ReceivedResponse,
    Completed,
};

pub const PQHandshake = struct {
    allocator: Allocator,
    state: HandshakeState,
    ephemeral_classic: ?[32]u8,
    ephemeral_classic_private: ?[32]u8,
    shared_secret: ?[32]u8,
    
    pub fn init(allocator: Allocator) PQHandshake {
        return PQHandshake{
            .allocator = allocator,
            .state = .Init,
            .ephemeral_classic = null,
            .ephemeral_classic_private = null,
            .shared_secret = null,
        };
    }
    
    pub fn initiate(
        self: *PQHandshake,
        responder_static: *const HybridKeyPair,
    ) !struct { classic_pub: [32]u8, pq_ciphertext: []u8 } {
        // Generate ephemeral X25519 keypair
        var ephemeral_priv: [32]u8 = undefined;
        var ephemeral_pub: [32]u8 = undefined;
        try X25519.KeyPair.create(&ephemeral_priv, &ephemeral_pub);
        self.ephemeral_classic_private = ephemeral_priv;
        self.ephemeral_classic = ephemeral_pub;
        
        // Encapsulate ML-KEM-768 to responder's static PQ key
        const pq_ciphertext = try pq_crypto.MLKEM768.encapsulate(
            self.allocator,
            responder_static.pq_public,
        );
        
        self.state = .SentEphemeral;
        return .{
            .classic_pub = ephemeral_pub,
            .pq_ciphertext = pq_ciphertext,
        };
    }
    
    pub fn respond(
        self: *PQHandshake,
        initiator_classic_pub: [32]u8,
        initiator_pq_ciphertext: []const u8,
        my_static: *const HybridKeyPair,
    ) !struct { pq_ciphertext: []u8 } {
        // Decapsulate ML-KEM-768
        const pq_shared = try pq_crypto.MLKEM768.decapsulate(
            self.allocator,
            initiator_pq_ciphertext,
            my_static.pq_private,
        );
        defer self.allocator.free(pq_shared);
        
        // Perform X25519 DH
        var classic_shared: [32]u8 = undefined;
        try X25519.scalarmult(&classic_shared, my_static.classic_private, initiator_classic_pub);
        
        // Combine secrets
        var combined: [64]u8 = undefined;
        @memcpy(combined[0..32], &classic_shared);
        @memcpy(combined[32..64], pq_shared);
        
        var session_key: [32]u8 = undefined;
        sha256.hash(&combined, &session_key, .{});
        self.shared_secret = session_key;
        
        // Generate ephemeral PQ ciphertext for responder
        const responder_pq_ciphertext = try pq_crypto.MLKEM768.encapsulate(
            self.allocator,
            my_static.pq_public,
        );
        
        self.state = .ReceivedResponse;
        return .{ .pq_ciphertext = responder_pq_ciphertext };
    }
    
    pub fn finalize(
        self: *PQHandshake,
        responder_pq_ciphertext: []const u8,
        my_static: *const HybridKeyPair,
    ) !void {
        // Decapsulate responder's PQ
        const pq_shared = try pq_crypto.MLKEM768.decapsulate(
            self.allocator,
            responder_pq_ciphertext,
            my_static.pq_private,
        );
        defer self.allocator.free(pq_shared);
        
        // Get classic shared from ephemeral
        var classic_shared: [32]u8 = undefined;
        try X25519.scalarmult(
            &classic_shared,
            self.ephemeral_classic_private.?,
            my_static.classic_public,
        );
        
        // Combine secrets
        var combined: [64]u8 = undefined;
        @memcpy(combined[0..32], &classic_shared);
        @memcpy(combined[32..64], pq_shared);
        
        var session_key: [32]u8 = undefined;
        sha256.hash(&combined, &session_key, .{});
        self.shared_secret = session_key;
        
        self.state = .Completed;
    }
    
    pub fn getSessionKey(self: *const PQHandshake) ![32]u8 {
        if (self.shared_secret == null) return error.HandshakeNotComplete;
        return self.shared_secret.?;
    }
};

test "PQ handshake roundtrip" {
    var allocator = std.testing.allocator;
    
    var responder_static = try HybridKeyPair.init(allocator);
    defer responder_static.deinit(allocator);
    
    var initiator_handshake = PQHandshake.init(allocator);
    var responder_handshake = PQHandshake.init(allocator);
    
    const init_msg = try initiator_handshake.initiate(&responder_static);
    defer allocator.free(init_msg.pq_ciphertext);
    
    const resp_msg = try responder_handshake.respond(
        init_msg.classic_pub,
        init_msg.pq_ciphertext,
        &responder_static,
    );
    defer allocator.free(resp_msg.pq_ciphertext);
    
    try initiator_handshake.finalize(resp_msg.pq_ciphertext, &responder_static);
    
    const key1 = try initiator_handshake.getSessionKey();
    const key2 = try responder_handshake.getSessionKey();
    
    try std.testing.expect(std.mem.eql(u8, &key1, &key2));
}