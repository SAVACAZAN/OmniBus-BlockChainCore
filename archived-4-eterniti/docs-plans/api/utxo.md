# utxo.zig — API Reference

> Auto-generated from core/utxo.zig

## Public Functions
```zig
pub const UTXO = struct {
    pub fn outpoint(self: *const UTXO, allocator: std.mem.Allocator) ![]u8 {
    pub fn isMature(self: *const UTXO, current_height: u64) bool {
pub const UTXOSet = struct {
    pub fn init(allocator: std.mem.Allocator) UTXOSet {
    pub fn deinit(self: *UTXOSet) void {
    pub fn addUTXO(
    pub fn spendUTXO(self: *UTXOSet, tx_hash: []const u8, output_index: u32) !UTXO {
    pub fn getUTXOsForAddress(self: *const UTXOSet, address: []const u8) []const []const u8 {
    pub fn getBalance(self: *const UTXOSet, address: []const u8) u64 {
    pub fn getUTXO(self: *const UTXOSet, tx_hash: []const u8, output_index: u32) ?UTXO {
    pub fn hasUTXO(self: *const UTXOSet, tx_hash: []const u8, output_index: u32) bool {
    pub fn selectUTXOs(
    pub fn getUTXOCount(self: *const UTXOSet, address: []const u8) usize {
    pub fn getStats(self: *const UTXOSet) struct { count: u64, total_value: u64, addresses: u32 } {
```

## Tests: 7
