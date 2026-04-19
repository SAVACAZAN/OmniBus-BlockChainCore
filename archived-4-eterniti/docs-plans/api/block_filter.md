# block_filter.zig — API Reference

> Auto-generated from core/block_filter.zig

## Public Functions
```zig
pub const FilterType = enum(u8) {
pub const BlockFilter = struct {
    pub fn mayContain(self: *const BlockFilter, address: []const u8) bool {
pub const FilterBuilder = struct {
    pub fn buildBasicFilter(
pub const FilterHeaderChain = struct {
    pub fn init(allocator: std.mem.Allocator) FilterHeaderChain {
    pub fn deinit(self: *FilterHeaderChain) void {
    pub fn addHeader(self: *FilterHeaderChain, header: [32]u8) !void {
    pub fn getHeader(self: *const FilterHeaderChain, height: u64) ?[32]u8 {
    pub fn chainHeight(self: *const FilterHeaderChain) u64 {
```

## Tests: 4
