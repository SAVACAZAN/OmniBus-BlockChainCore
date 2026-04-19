# bech32.zig — API Reference

> Auto-generated from core/bech32.zig

## Public Functions
```zig
pub const Encoding = enum {
pub fn encode(hrp: []const u8, data: []const u5, encoding: Encoding, allocator: std.mem.Allocator) ![]u8 {
pub fn decode(input: []const u8, allocator: std.mem.Allocator) !struct { hrp: []u8, data: []u5, encoding: Encoding } {
pub fn convertBits8to5(data: []const u8, pad: bool, allocator: std.mem.Allocator) ![]u5 {
pub fn convertBits5to8(data: []const u5, pad: bool, allocator: std.mem.Allocator) ![]u8 {
pub fn encodeWitnessAddress(
pub const WitnessResult = struct { version: u5, program: []u8 };
pub fn decodeWitnessAddress(
pub const OB_HRP = "ob";
pub fn encodeOBAddress(hash160: [20]u8, allocator: std.mem.Allocator) ![]u8 {
pub fn encodeOBTaprootAddress(pubkey_x: [32]u8, allocator: std.mem.Allocator) ![]u8 {
pub fn decodeOBAddress(addr: []const u8, allocator: std.mem.Allocator) !WitnessResult {
pub fn isValidOBAddress(addr: []const u8, allocator: std.mem.Allocator) bool {
```

## Tests: 6
