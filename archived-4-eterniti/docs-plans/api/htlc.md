# htlc.zig — API Reference

> Auto-generated from core/htlc.zig

## Public Functions
```zig
pub const HTLCState = enum {
pub const HTLC = struct {
    pub fn create(
    pub fn activate(self: *HTLC) !void {
    pub fn claim(self: *HTLC, preimage: [32]u8) !void {
    pub fn refund(self: *HTLC, current_height: u64) !void {
    pub fn checkExpiry(self: *HTLC, current_height: u64) void {
    pub fn canClaim(self: *const HTLC) bool {
    pub fn canRefund(self: *const HTLC, current_height: u64) bool {
    pub fn generatePreimage() struct { preimage: [32]u8, hash: [32]u8 } {
pub const HTLCRegistry = struct {
    pub fn init(allocator: std.mem.Allocator) HTLCRegistry {
    pub fn deinit(self: *HTLCRegistry) void {
    pub fn createHTLC(
    pub fn getHTLC(self: *const HTLCRegistry, id: u64) ?HTLC {
    pub fn activateHTLC(self: *HTLCRegistry, id: u64) !void {
    pub fn claimHTLC(self: *HTLCRegistry, id: u64, preimage: [32]u8) !void {
    pub fn refundHTLC(self: *HTLCRegistry, id: u64, current_height: u64) !void {
    pub fn expireAll(self: *HTLCRegistry, current_height: u64) u32 {
    pub fn activeCount(self: *const HTLCRegistry) u32 {
```

## Tests: 6
