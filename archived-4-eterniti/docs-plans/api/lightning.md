# lightning.zig — API Reference

> Auto-generated from core/lightning.zig

## Public Functions
```zig
pub const ChannelState = enum {
pub const Channel = struct {
    pub fn canSend(self: *const Channel, amount: u64) bool {
    pub fn canReceive(self: *const Channel, amount: u64) bool {
    pub fn updateBalance(self: *Channel, amount: u64, direction: enum { send, receive }) !void {
    pub fn initiateClose(self: *Channel) !void {
    pub fn forceClose(self: *Channel) !void {
    pub fn completeClose(self: *Channel) void {
pub const Invoice = struct {
    pub fn isExpired(self: *const Invoice) bool {
    pub fn create(payment_hash: [32]u8, amount: u64, recipient: []const u8, description: []const u8, expiry_secs: i64) Invoice {
pub const LightningNode = struct {
    pub fn init(address: []const u8, allocator: std.mem.Allocator) LightningNode {
    pub fn deinit(self: *LightningNode) void {
    pub fn openChannel(
    pub fn sendPayment(self: *LightningNode, channel_id: u64, amount: u64) !void {
    pub fn receivePayment(self: *LightningNode, channel_id: u64, amount: u64) !void {
    pub fn createInvoice(self: *LightningNode, amount: u64, description: []const u8, expiry_secs: i64) ![32]u8 {
    pub fn closeChannel(self: *LightningNode, channel_id: u64) !void {
    pub fn totalCapacity(self: *const LightningNode) u64 {
    pub fn outboundLiquidity(self: *const LightningNode) u64 {
    pub fn inboundLiquidity(self: *const LightningNode) u64 {
    pub fn activeChannels(self: *const LightningNode) u32 {
```

## Tests: 6
