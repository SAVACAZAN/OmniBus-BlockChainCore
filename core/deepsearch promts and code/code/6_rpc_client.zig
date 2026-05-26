//! Solana RPC Client for wallet

const std = @import("std");
const allocator = std.mem.Allocator;
const http = std.http;
const json = std.json;
const address = @import("address.zig");
const tx_builder = @import("tx_builder.zig");

// ============================================================
// RPC Types
// ============================================================

pub const Commitment = enum {
    processed,  // After basic processing
    confirmed,  // After confirmation (1 vote)
    finalized,  // After finalization (32 votes)
    
    pub fn toString(self: Commitment) []const u8 {
        return switch (self) {
            .processed => "processed",
            .confirmed => "confirmed",
            .finalized => "finalized",
        };
    }
};

pub const RpcConfig = struct {
    url: []const u8,
    commitment: Commitment = .finalized,
    timeout_ms: u32 = 30000,
};

pub const AccountInfo = struct {
    lamports: u64,
    owner: address.SolanaAddress,
    data: []u8,
    executable: bool,
    rent_epoch: u64,
    
    pub fn deinit(self: *AccountInfo) void {
        allocator.free(self.data);
    }
};

pub const TokenAccountInfo = struct {
    mint: address.SolanaAddress,
    owner: address.SolanaAddress,
    amount: u64,
    decimals: u8,
    is_native: bool,
};

pub const TransactionStatus = struct {
    slot: u64,
    confirmations: u64,
    err: ?[]const u8,
    status: Status,
    
    pub const Status = enum {
        processed,
        confirmed,
        finalized,
        failed,
    };
};

pub const BalanceResult = struct {
    lamports: u64,
    tokens: std.ArrayList(TokenBalance),
    
    pub fn deinit(self: *BalanceResult) void {
        for (self.tokens.items) |*tb| {
            tb.deinit();
        }
        self.tokens.deinit();
    }
};

pub const TokenBalance = struct {
    mint: address.SolanaAddress,
    amount: u64,
    decimals: u8,
    
    pub fn deinit(self: *TokenBalance) void {
        // No heap allocations to free
    }
};

// ============================================================
// RPC Client
// ============================================================

pub const SolanaRpcClient = struct {
    allocator: Allocator,
    config: RpcConfig,
    client: http.Client,
    next_id: u32,
    
    pub fn init(allocator: Allocator, config: RpcConfig) !SolanaRpcClient {
        return .{
            .allocator = allocator,
            .config = config,
            .client = http.Client{ .allocator = allocator },
            .next_id = 1,
        };
    }
    
    pub fn deinit(self: *SolanaRpcClient) void {
        self.client.deinit();
    }
    
    /// Get account info
    pub fn getAccountInfo(self: *SolanaRpcClient, pubkey: address.SolanaAddress) !AccountInfo {
        const params = [_]json.Value{
            .{ .string = try address.pubkeyToAddress(pubkey) },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getAccountInfo", &params);
        defer response.deinit();
        
        if (response.value == .null) {
            return error.AccountNotFound;
        }
        
        const result = response.value.object.get("result").?;
        const value = result.object.get("value").?;
        
        if (value == .null) {
            return error.AccountNotFound;
        }
        
        const obj = value.object;
        
        const lamports = @as(u64, @intCast(obj.get("lamports").?.integer));
        
        const owner_str = obj.get("owner").?.string;
        var owner: address.SolanaAddress = undefined;
        _ = try std.fmt.hexToBytes(&owner, owner_str);
        
        const data = obj.get("data").?.array;
        const data_bytes = try base64Decode(self.allocator, data.items[0].string);
        defer self.allocator.free(data_bytes);
        
        const executable = obj.get("executable").?.bool;
        const rent_epoch = @as(u64, @intCast(obj.get("rentEpoch").?.integer));
        
        return AccountInfo{
            .lamports = lamports,
            .owner = owner,
            .data = data_bytes,
            .executable = executable,
            .rent_epoch = rent_epoch,
        };
    }
    
    /// Get balance in lamports
    pub fn getBalance(self: *SolanaRpcClient, pubkey: address.SolanaAddress) !u64 {
        const params = [_]json.Value{
            .{ .string = try address.pubkeyToAddress(pubkey) },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getBalance", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const value = result.object.get("value").?;
        
        return @as(u64, @intCast(value.integer));
    }
    
    /// Get token accounts by owner
    pub fn getTokenAccounts(self: *SolanaRpcClient, owner: address.SolanaAddress) ![]TokenAccountInfo {
        const params = [_]json.Value{
            .{ .string = try address.pubkeyToAddress(owner) },
            .{ .object = json.ObjectMap.init(self.allocator) },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getTokenAccountsByOwner", &params);
        defer response.deinit();
        
        var accounts = std.ArrayList(TokenAccountInfo).init(self.allocator);
        errdefer {
            for (accounts.items) |*acc| {
                acc.deinit();
            }
            accounts.deinit();
        }
        
        const result = response.value.object.get("result").?;
        const value = result.object.get("value").?;
        
        if (value == .array) {
            const arr = value.array;
            for (arr.items) |item| {
                const account_obj = item.object.get("account").?.object;
                const data = account_obj.get("data").?.object;
                const parsed = data.get("parsed").?.object;
                const info = parsed.get("info").?.object;
                
                const mint_str = info.get("mint").?.string;
                var mint: address.SolanaAddress = undefined;
                _ = try std.fmt.hexToBytes(&mint, mint_str);
                
                const owner_str = info.get("owner").?.string;
                var owner_addr: address.SolanaAddress = undefined;
                _ = try std.fmt.hexToBytes(&owner_addr, owner_str);
                
                const amount = try std.fmt.parseInt(u64, info.get("tokenAmount").?.object.get("amount").?.string, 10);
                const decimals = @as(u8, @intCast(info.get("tokenAmount").?.object.get("decimals").?.integer));
                const is_native = info.get("isNative").?.bool;
                
                try accounts.append(TokenAccountInfo{
                    .mint = mint,
                    .owner = owner_addr,
                    .amount = amount,
                    .decimals = decimals,
                    .is_native = is_native,
                });
            }
        }
        
        return accounts.toOwnedSlice();
    }
    
    /// Send transaction
    pub fn sendTransaction(self: *SolanaRpcClient, tx: *tx_builder.VersionedTransaction) ![]u8 {
        const serialized = try tx.serialize();
        defer self.allocator.free(serialized);
        
        const encoded = try base64Encode(self.allocator, serialized);
        defer self.allocator.free(encoded);
        
        const params = [_]json.Value{
            .{ .string = encoded },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("sendTransaction", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        return self.allocator.dupe(u8, result.string);
    }
    
    /// Get latest blockhash
    pub fn getLatestBlockhash(self: *SolanaRpcClient) ![32]u8 {
        const params = [_]json.Value{
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getLatestBlockhash", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const value = result.object.get("value").?.object;
        const blockhash_str = value.get("blockhash").?.string;
        
        var blockhash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&blockhash, blockhash_str);
        
        return blockhash;
    }
    
    /// Get transaction status
    pub fn getSignatureStatus(self: *SolanaRpcClient, signature: []const u8) !TransactionStatus {
        const params = [_]json.Value{
            .{ .array = &.{.string = signature} },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getSignatureStatuses", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const value = result.object.get("value").?.array;
        
        if (value.items.len == 0 or value.items[0] == .null) {
            return error.TransactionNotFound;
        }
        
        const status_obj = value.items[0].object;
        const slot = @as(u64, @intCast(status_obj.get("slot").?.integer));
        const confirmations = @as(u64, @intCast(status_obj.get("confirmations").?.integer));
        
        const err_value = status_obj.get("err");
        const err = if (err_value != null and err_value.? != .null) err_value.?.string else null;
        
        const status = if (err != null) .failed else if (confirmations >= 32) .finalized else if (confirmations >= 1) .confirmed else .processed;
        
        return TransactionStatus{
            .slot = slot,
            .confirmations = confirmations,
            .err = err,
            .status = status,
        };
    }
    
    /// Get token supply
    pub fn getTokenSupply(self: *SolanaRpcClient, mint: address.SolanaAddress) !u64 {
        const params = [_]json.Value{
            .{ .string = try address.pubkeyToAddress(mint) },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getTokenSupply", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        const value = result.object.get("value").?.object;
        const amount = value.get("amount").?.string;
        
        return try std.fmt.parseInt(u64, amount, 10);
    }
    
    /// Request airdrop (testnet/devnet only)
    pub fn requestAirdrop(self: *SolanaRpcClient, pubkey: address.SolanaAddress, lamports: u64) ![]u8 {
        const params = [_]json.Value{
            .{ .string = try address.pubkeyToAddress(pubkey) },
            .{ .integer = @as(i64, @intCast(lamports)) },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("requestAirdrop", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        return self.allocator.dupe(u8, result.string);
    }
    
    /// Get minimum balance for rent exemption
    pub fn getMinimumBalanceForRentExemption(self: *SolanaRpcClient, data_size: usize) !u64 {
        const params = [_]json.Value{
            .{ .integer = @as(i64, @intCast(data_size)) },
            .{ .object = try self.commitmentObject() },
        };
        
        const response = try self.call("getMinimumBalanceForRentExemption", &params);
        defer response.deinit();
        
        const result = response.value.object.get("result").?;
        return @as(u64, @intCast(result.integer));
    }
    
    // ============================================================
    // Private Methods
    // ============================================================
    
    fn call(self: *SolanaRpcClient, method: []const u8, params: []const json.Value) !json.Parsed(json.Value) {
        const id = self.next_id;
        self.next_id += 1;
        
        const request_body = try self.buildRequest(method, params, id);
        defer self.allocator.free(request_body);
        
        var uri = try std.Uri.parse(self.config.url);
        var request = try self.client.open(.POST, uri, .{});
        defer request.deinit();
        
        request.transfer_encoding = .{ .content_length = request_body.len };
        request.headers.content_type = .json;
        
        try request.send();
        
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.appendSlice(request_body);
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
    
    fn buildRequest(self: *SolanaRpcClient, method: []const u8, params: []const json.Value, id: u32) ![]u8 {
        var params_array = json.Array.init(self.allocator);
        defer params_array.deinit();
        
        for (params) |p| {
            try params_array.append(p);
        }
        
        var request_obj = json.ObjectMap.init(self.allocator);
        defer request_obj.deinit();
        
        try request_obj.put("jsonrpc", json.Value{ .string = "2.0" });
        try request_obj.put("method", json.Value{ .string = method });
        try request_obj.put("params", json.Value{ .array = params_array });
        try request_obj.put("id", json.Value{ .integer = id });
        
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        try json.stringify(json.Value{ .object = request_obj }, .{}, result.writer());
        
        return result.toOwnedSlice();
    }
    
    fn commitmentObject(self: *SolanaRpcClient) !json.ObjectMap {
        var obj = json.ObjectMap.init(self.allocator);
        try obj.put("commitment", json.Value{ .string = self.config.commitment.toString() });
        return obj;
    }
};

// Base64 helpers (simplified)
fn base64Encode(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(data.len);
    var result = try alloc.alloc(u8, encoded_len);
    _ = encoder.encode(result, data);
    return result;
}

fn base64Decode(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(data);
    var result = try alloc.alloc(u8, decoded_len);
    try decoder.decode(result, data);
    return result;
}

// ============================================================
// Tests
// ============================================================

test "RPC client config" {
    const config = RpcConfig{
        .url = "https://api.mainnet-beta.solana.com",
        .commitment = .finalized,
    };
    
    try std.testing.expectEqualStrings(config.url, "https://api.mainnet-beta.solana.com");
    try std.testing.expect(config.commitment == .finalized);
}