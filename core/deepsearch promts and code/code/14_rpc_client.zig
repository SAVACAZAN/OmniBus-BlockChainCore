//! TON RPC Client (ADNL + HTTP API)
//! Communicates with TON nodes via lite-server or REST API

const std = @import("std");
const allocator = std.mem.Allocator;
const http = std.http;
const json = std.json;
const cell = @import("cell.zig");
const address = @import("address.zig");

// ============================================================
// RPC Types
// ============================================================

pub const RpcConfig = struct {
    /// HTTP API endpoint (e.g., https://toncenter.com/api/v2/)
    http_url: []const u8,
    
    /// API key (optional)
    api_key: ?[]const u8 = null,
    
    /// Lite-server ADNL address (optional, for direct access)
    lite_server: ?[]const u8 = null,
    
    timeout_ms: u32 = 30000,
};

pub const AccountInfo = struct {
    address: address.TonAddress,
    balance: u64,
    code: ?*cell.Cell,
    data: ?*cell.Cell,
    last_transaction_lt: u64,
    status: AccountStatus,
    
    pub const AccountStatus = enum {
        uninit,
        active,
        frozen,
        deleted,
    };
    
    pub fn deinit(self: *AccountInfo) void {
        if (self.code) |c| c.deinit();
        if (self.data) |d| d.deinit();
    }
};

pub const Transaction = struct {
    hash: [32]u8,
    lt: u64,
    fee: u64,
    storage_fee: u64,
    other_fee: u64,
    status: TransactionStatus,
    now: u64,
    
    pub const TransactionStatus = enum {
        pending,
        success,
        failed,
    };
};

pub const RunResult = struct {
    success: bool,
    exit_code: i32,
    gas_used: u64,
    stack: []RunStackItem,
    
    pub fn deinit(self: *RunResult) void {
        for (self.stack) |*item| {
            item.deinit();
        }
        allocator.free(self.stack);
    }
};

pub const RunStackItem = struct {
    type: StackType,
    value: StackValue,
    
    pub const StackType = enum {
        int,
        cell,
        slice,
        null,
    };
    
    pub const StackValue = union(enum) {
        int: u256,
        cell: *cell.Cell,
        slice: []u8,
        
        pub fn deinit(self: *StackValue) void {
            switch (self.*) {
                .cell => |c| c.deinit(),
                .slice => |s| allocator.free(s),
                else => {},
            }
        }
    };
    
    pub fn deinit(self: *RunStackItem) void {
        self.value.deinit();
    }
};

// ============================================================
// RPC Client
// ============================================================

pub const TonRpcClient = struct {
    allocator: Allocator,
    config: RpcConfig,
    client: http.Client,
    next_id: u32,
    
    pub fn init(allocator: Allocator, config: RpcConfig) !TonRpcClient {
        return .{
            .allocator = allocator,
            .config = config,
            .client = http.Client{ .allocator = allocator },
            .next_id = 1,
        };
    }
    
    pub fn deinit(self: *TonRpcClient) void {
        self.client.deinit();
    }
    
    /// Get account info by address
    pub fn getAccountInfo(self: *TonRpcClient, addr: address.TonAddress) !AccountInfo {
        const addr_str = try addr.toBounceable();
        defer self.allocator.free(addr_str);
        
        const response = try self.httpCall("getAddressInformation", .{addr_str});
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const obj = result.object;
        
        const balance_str = obj.get("balance").?.string;
        const balance = try std.fmt.parseInt(u64, balance_str, 10);
        
        const status_str = obj.get("status").?.string;
        const status = if (std.mem.eql(u8, status_str, "active"))
            AccountInfo.AccountStatus.active
        else if (std.mem.eql(u8, status_str, "uninit"))
            .uninit
        else if (std.mem.eql(u8, status_str, "frozen"))
            .frozen
        else
            .deleted;
        
        const lt_str = obj.get("last_transaction_lt").?.string;
        const last_transaction_lt = try std.fmt.parseInt(u64, lt_str, 10);
        
        // Code and data cells (would need to fetch separately)
        return AccountInfo{
            .address = addr,
            .balance = balance,
            .code = null,
            .data = null,
            .last_transaction_lt = last_transaction_lt,
            .status = status,
        };
    }
    
    /// Get account balance in nanoTON
    pub fn getBalance(self: *TonRpcClient, addr: address.TonAddress) !u64 {
        const info = try self.getAccountInfo(addr);
        return info.balance;
    }
    
    /// Send external message
    pub fn sendMessage(self: *TonRpcClient, msg_cell: *cell.Cell) ![]u8 {
        const serialized = try msg_cell.serialize(self.allocator);
        defer self.allocator.free(serialized);
        
        const base64_msg = try base64Encode(self.allocator, serialized);
        defer self.allocator.free(base64_msg);
        
        const response = try self.httpCall("sendRawMessage", .{base64_msg});
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        if (result == .null) {
            return self.allocator.dupe(u8, "sent");
        }
        
        return self.allocator.dupe(u8, result.string);
    }
    
    /// Estimate fee for a message
    pub fn estimateFee(self: *TonRpcClient, msg_cell: *cell.Cell) !u64 {
        const serialized = try msg_cell.serialize(self.allocator);
        defer self.allocator.free(serialized);
        
        const base64_msg = try base64Encode(self.allocator, serialized);
        defer self.allocator.free(base64_msg);
        
        const response = try self.httpCall("estimateFee", .{base64_msg});
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const source_fees = result.object.get("source_fees").?;
        const total_fee_str = source_fees.object.get("total_fee").?.string;
        
        return try std.fmt.parseInt(u64, total_fee_str, 10);
    }
    
    /// Run get method on contract
    pub fn runGetMethod(
        self: *TonRpcClient,
        addr: address.TonAddress,
        method: []const u8,
        params: []const []const u8,
    ) !RunResult {
        const addr_str = try addr.toBounceable();
        defer self.allocator.free(addr_str);
        
        var params_array = json.Array.init(self.allocator);
        defer params_array.deinit();
        
        for (params) |p| {
            try params_array.append(json.Value{ .string = p });
        }
        
        const response = try self.httpCallRaw("runGetMethod", .{
            .address = addr_str,
            .method = method,
            .stack = params_array,
        });
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const success = result.object.get("success").?.bool;
        const exit_code = @as(i32, @intCast(result.object.get("exit_code").?.integer));
        const gas_used = @as(u64, @intCast(result.object.get("gas_used").?.integer));
        
        var stack = std.ArrayList(RunStackItem).init(self.allocator);
        errdefer {
            for (stack.items) |*item| item.deinit();
            stack.deinit();
        }
        
        if (result.object.get("stack")) |stack_arr| {
            for (stack_arr.array.items) |item| {
                const stack_item = try self.parseStackItem(item);
                try stack.append(stack_item);
            }
        }
        
        return RunResult{
            .success = success,
            .exit_code = exit_code,
            .gas_used = gas_used,
            .stack = try stack.toOwnedSlice(),
        };
    }
    
    /// Get transaction by hash and LT
    pub fn getTransaction(self: *TonRpcClient, hash: [32]u8, lt: u64) !Transaction {
        const hash_hex = std.fmt.bytesToHex(&hash, .lower);
        const response = try self.httpCall("getTransaction", .{hash_hex, lt});
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const obj = result.object;
        
        const fee_str = obj.get("fee").?.string;
        const storage_fee_str = obj.get("storage_fee").?.string;
        const other_fee_str = obj.get("other_fee").?.string;
        
        const status_str = obj.get("status").?.string;
        const status = if (std.mem.eql(u8, status_str, "ok"))
            Transaction.TransactionStatus.success
        else if (std.mem.eql(u8, status_str, "pending"))
            .pending
        else
            .failed;
        
        const now = @as(u64, @intCast(obj.get("now").?.integer));
        
        return Transaction{
            .hash = hash,
            .lt = lt,
            .fee = try std.fmt.parseInt(u64, fee_str, 10),
            .storage_fee = try std.fmt.parseInt(u64, storage_fee_str, 10),
            .other_fee = try std.fmt.parseInt(u64, other_fee_str, 10),
            .status = status,
            .now = now,
        };
    }
    
    /// Get masterchain info (for sync)
    pub fn getMasterchainInfo(self: *TonRpcClient) !struct { seqno: u64, last_lt: u64 } {
        const response = try self.httpCall("getMasterchainInfo", .{});
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const obj = result.object;
        const seqno = @as(u64, @intCast(obj.get("seqno").?.integer));
        const last_lt = @as(u64, @intCast(obj.get("last_lt").?.integer));
        
        return .{ .seqno = seqno, .last_lt = last_lt };
    }
    
    // ============================================================
    // Private Methods
    // ============================================================
    
    fn httpCall(self: *TonRpcClient, method: []const u8, params: anytype) !json.Parsed(json.Value) {
        const request_json = try self.buildJsonRequest(method, params);
        defer self.allocator.free(request_json);
        
        var uri = try std.Uri.parse(self.config.http_url);
        var request = try self.client.open(.POST, uri, .{});
        defer request.deinit();
        
        request.transfer_encoding = .{ .content_length = request_json.len };
        request.headers.content_type = .json;
        
        try request.send();
        
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.appendSlice(request_json);
        try request.writeAll(buffer.items);
        
        try request.finish();
        try request.wait();
        
        var response_body = std.ArrayList(u8).init(self.allocator);
        defer response_body.deinit();
        try request.reader().readAllArrayList(&response_body, 1024 * 1024);
        
        var parser = json.Parser.init(self.allocator, false);
        defer parser.deinit();
        
        const parsed = try parser.parse(response_body.items);
        
        if (parsed.value == .object) {
            if (parsed.value.object.get("error")) |err| {
                if (err != .null) {
                    return error.RpcError;
                }
            }
        }
        
        return parsed;
    }
    
    fn httpCallRaw(self: *TonRpcClient, method: []const u8, params: anytype) !json.Parsed(json.Value) {
        _ = self;
        _ = method;
        _ = params;
        // Similar to httpCall but for raw JSON
        return error.NotImplemented;
    }
    
    fn buildJsonRequest(self: *TonRpcClient, method: []const u8, params: anytype) ![]u8 {
        const id = self.next_id;
        self.next_id += 1;
        
        var request_obj = json.ObjectMap.init(self.allocator);
        defer request_obj.deinit();
        
        try request_obj.put("jsonrpc", json.Value{ .string = "2.0" });
        try request_obj.put("id", json.Value{ .integer = id });
        try request_obj.put("method", json.Value{ .string = method });
        
        var params_array = json.Array.init(self.allocator);
        defer params_array.deinit();
        
        switch (@typeInfo(@TypeOf(params))) {
            .@"struct" => {
                inline for (@typeInfo(@TypeOf(params)).struct.fields) |field| {
                    const value = @field(params, field.name);
                    try params_array.append(json.Value{ .string = value });
                }
            },
            else => {
                // Handle other cases
            },
        }
        
        try request_obj.put("params", json.Value{ .array = params_array });
        
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        try json.stringify(json.Value{ .object = request_obj }, .{}, result.writer());
        
        // Add API key if present
        if (self.config.api_key) |key| {
            var with_key = std.ArrayList(u8).init(self.allocator);
            defer with_key.deinit();
            
            try with_key.appendSlice(result.items);
            try with_key.writer().print("&api_key={s}", .{key});
            return with_key.toOwnedSlice();
        }
        
        return result.toOwnedSlice();
    }
    
    fn parseStackItem(self: *TonRpcClient, item: json.Value) !RunStackItem {
        _ = self;
        const type_str = item.object.get("type").?.string;
        const value = item.object.get("value").?;
        
        if (std.mem.eql(u8, type_str, "num")) {
            const int_value = try std.fmt.parseInt(u256, value.string, 10);
            return RunStackItem{
                .type = .int,
                .value = .{ .int = int_value },
            };
        } else if (std.mem.eql(u8, type_str, "cell")) {
            // Parse cell from BOC
            return RunStackItem{
                .type = .cell,
                .value = .{ .cell = try cell.Cell.create(self.allocator, &[_]u8{}) },
            };
        } else if (std.mem.eql(u8, type_str, "slice")) {
            return RunStackItem{
                .type = .slice,
                .value = .{ .slice = try self.allocator.dupe(u8, value.string) },
            };
        } else {
            return RunStackItem{
                .type = .null,
                .value = .{ .int = 0 },
            };
        }
    }
};

// Base64 helper
fn base64Encode(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    var result = try alloc.alloc(u8, encoded_len);
    _ = encoder.encode(result, data);
    return result;
}

// ============================================================
// Tests
// ============================================================

test "RPC client config" {
    const config = RpcConfig{
        .http_url = "https://toncenter.com/api/v2/",
        .api_key = "test_key",
    };
    
    try std.testing.expectEqualStrings(config.http_url, "https://toncenter.com/api/v2/");
}