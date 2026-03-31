# encrypted_p2p.zig — API Reference

> Auto-generated from core/encrypted_p2p.zig

## Public Functions
```zig
pub const EncryptedSession = struct {
    pub fn initiate() !EncryptedSession {
    pub fn completeHandshake(self: *EncryptedSession, remote_pubkey: [33]u8) !void {
    pub fn encrypt(self: *EncryptedSession, plaintext: []const u8, allocator: std.mem.Allocator) ![]u8 {
    pub fn decrypt(self: *EncryptedSession, ciphertext: []const u8, allocator: std.mem.Allocator) ![]u8 {
```

## Tests: 4
