/// chain_rpc_client.zig — Minimal JSON-RPC client for talking to the
/// omnibus-node chain process from sibling daemons (agents, explorer).
///
/// HTTP/1.1, POST, port configurable (default 8332). Token auth via
/// OMNIBUS_RPC_TOKEN env var (Bearer header). All allocations are
/// caller-owned via the passed allocator.

const std = @import("std");

pub const CHAIN_RPC_DEFAULT_HOST = "127.0.0.1";
pub const CHAIN_RPC_DEFAULT_PORT: u16 = 8332;

pub const RpcError = error{
    ConnectionFailed,
    BadResponse,
    ChainError,
    OutOfMemory,
};

pub const ChainClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8 = CHAIN_RPC_DEFAULT_HOST,
    port: u16 = CHAIN_RPC_DEFAULT_PORT,
    token: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) ChainClient {
        const tok = std.process.getEnvVarOwned(allocator, "OMNIBUS_RPC_TOKEN") catch null;
        return .{ .allocator = allocator, .token = tok };
    }

    pub fn deinit(self: *ChainClient) void {
        if (self.token) |t| self.allocator.free(t);
    }

    /// Call a JSON-RPC method on the chain. `params_json` is the raw
    /// JSON for the params field (e.g. "[]" or "{\"height\":5}").
    /// Returns the full response body (caller owns).
    pub fn call(
        self: *ChainClient,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        const body = try std.fmt.allocPrint(self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json });
        defer self.allocator.free(body);

        const addr = try std.net.Address.parseIp4(self.host, self.port);
        var stream = std.net.tcpConnectToAddress(addr) catch return RpcError.ConnectionFailed;
        defer stream.close();

        // Build HTTP request
        var req_buf = std.ArrayList(u8){};
        defer req_buf.deinit(self.allocator);
        const writer = req_buf.writer(self.allocator);
        try writer.print("POST / HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ self.host, self.port });
        try writer.print("Content-Type: application/json\r\n", .{});
        try writer.print("Content-Length: {d}\r\n", .{body.len});
        if (self.token) |t| try writer.print("Authorization: Bearer {s}\r\n", .{t});
        try writer.print("Connection: close\r\n\r\n", .{});
        try writer.writeAll(body);

        _ = try stream.writeAll(req_buf.items);

        // Read full response
        var resp = std.ArrayList(u8){};
        defer resp.deinit(self.allocator);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = stream.read(&chunk) catch break;
            if (n == 0) break;
            try resp.appendSlice(self.allocator, chunk[0..n]);
            if (resp.items.len > 1024 * 1024) break; // 1MB cap
        }

        const sep = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse return RpcError.BadResponse;
        const json_body = resp.items[sep + 4 ..];
        return try self.allocator.dupe(u8, json_body);
    }

    /// Convenience: getblockcount → u64
    pub fn getBlockCount(self: *ChainClient) !u64 {
        const resp = try self.call("getblockcount", "[]");
        defer self.allocator.free(resp);
        // Find "result":<number>
        const key = "\"result\":";
        const idx = std.mem.indexOf(u8, resp, key) orelse return RpcError.BadResponse;
        var p = idx + key.len;
        while (p < resp.len and (resp[p] == ' ' or resp[p] == '\t')) : (p += 1) {}
        var end = p;
        while (end < resp.len and resp[end] >= '0' and resp[end] <= '9') : (end += 1) {}
        if (end == p) return RpcError.BadResponse;
        return std.fmt.parseInt(u64, resp[p..end], 10) catch RpcError.BadResponse;
    }
};
