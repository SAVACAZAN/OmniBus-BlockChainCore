# psbt.zig — API Reference

> Auto-generated from core/psbt.zig

## Public Functions
```zig
pub const PSBT_MAGIC = [4]u8{ 'p', 's', 'b', 't' };
pub const PSBT_SEPARATOR = 0xFF;
pub const PSBTRole = enum {
pub const PartialSig = struct {
pub const PSBTInput = struct {
    pub fn isFullySigned(self: *const PSBTInput) bool {
pub const PSBT_TX = struct {
    pub fn create(tx: Transaction, num_inputs: u32, allocator: std.mem.Allocator) !PSBT_TX {
    pub fn deinit(self: *PSBT_TX) void {
    pub fn addSignature(self: *PSBT_TX, input_index: u32, pubkey: [33]u8, signature: [64]u8) !void {
    pub fn signInput(self: *PSBT_TX, input_index: u32, private_key: [32]u8) !void {
    pub fn isComplete(self: *const PSBT_TX) bool {
    pub fn finalize(self: *PSBT_TX, allocator: std.mem.Allocator) !Transaction {
    pub fn getProgress(self: *const PSBT_TX) struct { signed: u32, required: u32 } {
    pub fn serialize(self: *const PSBT_TX, allocator: std.mem.Allocator) ![]u8 {
```

## Tests: 5
