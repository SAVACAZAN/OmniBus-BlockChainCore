# tor_proxy.zig — API Reference

> Auto-generated from core/tor_proxy.zig

## Public Functions
```zig
pub const TorConfig = struct {
    pub fn default() TorConfig {
    pub fn enabled_default() TorConfig {
    pub fn tor_browser() TorConfig {
pub const Socks5Result = enum {
pub fn buildSocks5ConnectRequest(target_host: []const u8, target_port: u16) struct { handshake: [3]u8, request: [263]u8, request_len: usize } {
pub fn validateSocks5Auth(response: [2]u8) bool {
pub fn validateSocks5Connect(response: [10]u8) Socks5Result {
pub fn isTorAvailable(config: TorConfig) bool {
pub fn isOnionAddress(host: []const u8) bool {
```

## Tests: 7
