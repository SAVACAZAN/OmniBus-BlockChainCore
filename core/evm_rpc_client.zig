//! evm_rpc_client.zig — minimal JSON-RPC client for talking to EVM nodes
//! (Sepolia, Base, BNB, etc.) over HTTP. Lets the OmniBus chain call
//! arbitrary `eth_*` methods against any public RPC endpoint without
//! pulling in a heavyweight library.
//!
//! Used by the DEX settler thread to:
//!   - eth_call:           read OmnibusDEX.getOrder, ERC-20 allowances, etc.
//!   - eth_sendRawTransaction: submit signed settle() / cancel() tx
//!   - eth_getTransactionReceipt: confirm a submitted tx landed
//!   - eth_getLogs:        watch OrderPlaced / OrderCancelled events
//!   - eth_blockNumber:    poll for chain head when reorganising state
//!   - eth_getTransactionCount: pick the next nonce for the operator key
//!
//! Designed to be DRIVEN by chain alone — no frontend dependency. If the
//! UI is offline, the settler thread keeps watching and submitting tx
//! using only this module + evm_signer.zig.

const std = @import("std");

pub const RpcError = error{
    HttpError,
    BadJson,
    RpcReturnedError,
    NoResult,
    OutOfMemory,
};

/// Owned response from an EVM RPC call. Caller frees both `body` and
/// `result_slice` (the latter being a sub-slice of body, kept around so
/// the caller can re-parse without copying).
pub const RpcResponse = struct {
    /// Full HTTP body. Owned by the caller.
    body: []u8,
    /// Slice into `body` pointing at the `"result"` value (string, number,
    /// or object — depending on the method). Empty when the call errored.
    result: []const u8,

    pub fn deinit(self: *RpcResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.result = &.{};
    }
};

/// Perform an arbitrary JSON-RPC 2.0 call against `rpc_url`. `method` is the
/// `eth_*` method name; `params_json` is the raw JSON array (caller builds
/// it). Returns the response body + a sub-slice pointing at `"result"`.
///
/// Example:
///   const resp = try call(alloc, "https://sepolia.drpc.org",
///       "eth_blockNumber", "[]");
///   defer resp.deinit(alloc);
///   // resp.result == "\"0x1a2b3c\""
pub fn call(
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    method: []const u8,
    params_json: []const u8,
) RpcError!RpcResponse {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build request body: {"jsonrpc":"2.0","id":1,"method":"<m>","params":<p>}
    var body_buf = std.array_list.Managed(u8).init(allocator);
    defer body_buf.deinit();
    std.fmt.format(body_buf.writer(),
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json },
    ) catch return RpcError.OutOfMemory;

    var wa = std.Io.Writer.Allocating.init(allocator);
    defer wa.deinit();

    const result = client.fetch(.{
        .location = .{ .url = rpc_url },
        .method = .POST,
        .payload = body_buf.items,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &wa.writer,
        .keep_alive = false,
    }) catch return RpcError.HttpError;

    const status: u16 = @intCast(@intFromEnum(result.status));
    if (status != 200) return RpcError.HttpError;

    const body = wa.toOwnedSlice() catch return RpcError.OutOfMemory;

    // Find "result": in the response. If "error": comes first, the RPC
    // returned a structured error — surface that to the caller so they
    // can decide whether to retry.
    if (std.mem.indexOf(u8, body, "\"error\"") != null and
        std.mem.indexOf(u8, body, "\"result\"") == null)
    {
        allocator.free(body);
        return RpcError.RpcReturnedError;
    }

    const key = "\"result\":";
    const key_pos = std.mem.indexOf(u8, body, key) orelse {
        allocator.free(body);
        return RpcError.NoResult;
    };
    var i = key_pos + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    // Caller pulls the field value out — we hand the rest of the slice
    // up to the final '}' (closing the top-level object). Most callers
    // only care about scalar values which they parse with helpers below.
    const end = std.mem.lastIndexOfScalar(u8, body, '}') orelse body.len;
    const result_slice = body[i..end];

    return RpcResponse{ .body = body, .result = result_slice };
}

// ── Convenience helpers (common eth_* methods) ────────────────────────────

/// eth_blockNumber → u64. Used to detect chain reorgs and pick safe block
/// confirmations for event watching.
pub fn blockNumber(allocator: std.mem.Allocator, rpc_url: []const u8) !u64 {
    var resp = try call(allocator, rpc_url, "eth_blockNumber", "[]");
    defer resp.deinit(allocator);
    return parseHexU64FromQuotedField(resp.result);
}

/// eth_getTransactionCount(addr, "latest") → u64 nonce. Required before
/// signing a new tx so we don't clash with a pending in-flight one.
pub fn getTransactionCount(
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    address_hex_with_0x: []const u8,
) !u64 {
    var params_buf: [128]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf,
        "[\"{s}\",\"latest\"]", .{address_hex_with_0x});
    var resp = try call(allocator, rpc_url, "eth_getTransactionCount", params);
    defer resp.deinit(allocator);
    return parseHexU64FromQuotedField(resp.result);
}

/// eth_gasPrice → u64 wei. Caller multiplies this by a margin (e.g. 1.2x)
/// to ensure the tx mines promptly even if base fee bumps mid-block.
pub fn gasPrice(allocator: std.mem.Allocator, rpc_url: []const u8) !u64 {
    var resp = try call(allocator, rpc_url, "eth_gasPrice", "[]");
    defer resp.deinit(allocator);
    return parseHexU64FromQuotedField(resp.result);
}

/// eth_chainId → u64. Sanity check before signing: prevents replaying a
/// Sepolia tx on Base (different chain id → tx rejected, EIP-155).
pub fn chainId(allocator: std.mem.Allocator, rpc_url: []const u8) !u64 {
    var resp = try call(allocator, rpc_url, "eth_chainId", "[]");
    defer resp.deinit(allocator);
    return parseHexU64FromQuotedField(resp.result);
}

/// eth_sendRawTransaction → tx hash (0x-prefixed). The signer module
/// produces the raw bytes hex; this just submits.
pub fn sendRawTransaction(
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    raw_tx_hex_with_0x: []const u8,
) ![]u8 {
    var params_buf = std.array_list.Managed(u8).init(allocator);
    defer params_buf.deinit();
    try params_buf.appendSlice("[\"");
    try params_buf.appendSlice(raw_tx_hex_with_0x);
    try params_buf.appendSlice("\"]");

    var resp = try call(allocator, rpc_url, "eth_sendRawTransaction", params_buf.items);
    defer resp.deinit(allocator);
    return try allocator.dupe(u8, std.mem.trim(u8, resp.result, " \t\"\n"));
}

/// eth_call (read-only contract execution). `data` is the ABI-encoded
/// call hex with 0x prefix. Returns the raw return data (also 0x hex).
pub fn ethCall(
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    to_addr_hex_with_0x: []const u8,
    data_hex_with_0x: []const u8,
) ![]u8 {
    var params_buf = std.array_list.Managed(u8).init(allocator);
    defer params_buf.deinit();
    try std.fmt.format(params_buf.writer(),
        "[{{\"to\":\"{s}\",\"data\":\"{s}\"}},\"latest\"]",
        .{ to_addr_hex_with_0x, data_hex_with_0x },
    );

    var resp = try call(allocator, rpc_url, "eth_call", params_buf.items);
    defer resp.deinit(allocator);
    return try allocator.dupe(u8, std.mem.trim(u8, resp.result, " \t\"\n"));
}

/// eth_getLogs for a specific address + topic filter. Used to watch
/// OrderPlaced / OrderCancelled events on OmnibusDEX without polling
/// every block individually.
///
/// `topic0_hex` is the keccak256 hash of the event signature with 0x prefix.
/// Caller passes block range as hex strings ("0x" + lowercase hex).
pub fn getLogs(
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    contract_addr_hex_with_0x: []const u8,
    topic0_hex: []const u8,
    from_block_hex: []const u8,
    to_block_hex: []const u8,
) ![]u8 {
    var params_buf = std.array_list.Managed(u8).init(allocator);
    defer params_buf.deinit();
    try std.fmt.format(params_buf.writer(),
        "[{{\"address\":\"{s}\",\"topics\":[\"{s}\"],\"fromBlock\":\"{s}\",\"toBlock\":\"{s}\"}}]",
        .{ contract_addr_hex_with_0x, topic0_hex, from_block_hex, to_block_hex },
    );

    var resp = try call(allocator, rpc_url, "eth_getLogs", params_buf.items);
    defer resp.deinit(allocator);
    return try allocator.dupe(u8, resp.result);
}

/// eth_getTransactionReceipt → JSON (caller parses). Returns null when
/// the tx hasn't mined yet.
pub fn getReceipt(
    allocator: std.mem.Allocator,
    rpc_url: []const u8,
    tx_hash_hex_with_0x: []const u8,
) !?[]u8 {
    var params_buf: [96]u8 = undefined;
    const params = try std.fmt.bufPrint(&params_buf,
        "[\"{s}\"]", .{tx_hash_hex_with_0x});

    var resp = try call(allocator, rpc_url, "eth_getTransactionReceipt", params);
    defer resp.deinit(allocator);

    const trimmed = std.mem.trim(u8, resp.result, " \t\n");
    if (std.mem.eql(u8, trimmed, "null")) return null;
    return try allocator.dupe(u8, resp.result);
}

// ── Parsing helpers ───────────────────────────────────────────────────────

/// Parse a hex string like `"0x1a2b"` into u64. Tolerates the leading
/// quotation marks emitted by RPC responses, AND trailing fields like
/// `,"id":1` that the lazy `call()` slicer hands us along with the value.
fn parseHexU64FromQuotedField(s: []const u8) !u64 {
    // Find the actual hex value: starts after first `"` (or at byte 0 if
    // no quote), ends at next `"` or `,` or end of slice.
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '"')) : (start += 1) {}
    var end: usize = start;
    while (end < s.len and s[end] != '"' and s[end] != ',' and s[end] != '}' and s[end] != ' ' and s[end] != '\n') : (end += 1) {}
    var hex = s[start..end];
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) {
        hex = hex[2..];
    }
    if (hex.len == 0) return 0;
    return std.fmt.parseInt(u64, hex, 16) catch |err| {
        std.debug.print("[evm_rpc] parseHex failed on input='{s}' extracted='{s}'\n", .{ s, hex });
        return err;
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "parseHexU64FromQuotedField handles common shapes" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 0x1a2b), try parseHexU64FromQuotedField("\"0x1a2b\""));
    try t.expectEqual(@as(u64, 0), try parseHexU64FromQuotedField("\"0x0\""));
    try t.expectEqual(@as(u64, 0xff), try parseHexU64FromQuotedField("\"0xff\""));
    try t.expectEqual(@as(u64, 0xff), try parseHexU64FromQuotedField(" \"0xff\" "));
}
