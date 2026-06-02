// Ethereum-compatible JSON-RPC handlers (eth_*, net_version).
//
// This module exists so wallets/libs that speak the de-facto Ethereum
// JSON-RPC (ethers.js, web3.js, MetaMask) can detect the chain and run
// pre-flight checks (chain id, gas price, balance, receipts) against an
// OmniBus node. None of these methods alter OmniBus consensus — they
// adapt OmniBus state to EIP-1474 wire format. Native (canonical) flows
// continue to use the lowercase `sendrawtransaction` / `sendTransaction`
// RPCs from rpc/wallet.zig.
//
// Layout note: handlers were extracted from `rpc_server.zig` as part of
// the Bitcoin-Core-style RPC split (see `core/rpc/README.md`). The
// dispatcher in `rpc_server.zig` routes `eth_*` method names to the
// `handle*` functions here. Shared types (ServerCtx) and JSON helpers
// (extractStr, errorJson, extractArrayStr, extractParamObjectField,
// extractParamObjectU64, extractStringFromArrayParams) are re-exported
// from `rpc_server.zig` to keep this slice surgical.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const evm_executor = @import("../evm_executor.zig");
const evm_mod = @import("../evm/mod.zig");

const ServerCtx = rpc.ServerCtx;

// ---------------------------------------------------------------------------
// Hex parsing helpers
// ---------------------------------------------------------------------------

/// Strip optional "0x"/"0X" prefix and parse hex address into [20]u8.
/// Returns ZERO_ADDRESS on malformed input.
fn parseAddress(hex: []const u8) evm_mod.Address {
    var addr: evm_mod.Address = [_]u8{0} ** 20;
    const s = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X'))
        hex[2..] else hex;
    if (s.len != 40) return addr;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const hi = hexNibble(s[i * 2]) catch return addr;
        const lo = hexNibble(s[i * 2 + 1]) catch return addr;
        addr[i] = (hi << 4) | lo;
    }
    return addr;
}

/// Parse hex calldata (with optional "0x" prefix) into an alloc-owned slice.
fn parseHexData(alloc: std.mem.Allocator, hex: []const u8) ![]u8 {
    const s = if (hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X'))
        hex[2..] else hex;
    if (s.len == 0) return alloc.dupe(u8, &.{});
    if (s.len % 2 != 0) return error.InvalidHex;
    const out = try alloc.alloc(u8, s.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexNibble(s[i * 2]);
        const lo = try hexNibble(s[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

/// Hex-encode a byte slice with "0x" prefix into an alloc-owned string.
fn toHexData(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return alloc.dupe(u8, "0x");
    const out = try alloc.alloc(u8, 2 + data.len * 2);
    out[0] = '0'; out[1] = 'x';
    const hex = "0123456789abcdef";
    for (data, 0..) |b, i| {
        out[2 + i * 2] = hex[b >> 4];
        out[2 + i * 2 + 1] = hex[b & 0xF];
    }
    return out;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

/// eth_call — view function call. Params: `[{from?,to,data,value?,gas?}, "latest"]`.
pub fn handleEthCall(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to_hex = rpc.extractParamObjectField(body, "to") orelse
        return rpc.errorJson(-32602, "eth_call: missing 'to'", id, alloc);
    const from_hex = rpc.extractParamObjectField(body, "from") orelse
        "0x0000000000000000000000000000000000000000";
    const data_hex = rpc.extractParamObjectField(body, "data") orelse "0x";
    const value = rpc.extractParamObjectU64(body, "value");
    const gas = blk: {
        const g = rpc.extractParamObjectU64(body, "gas");
        if (g == 0) break :blk @as(u64, 30_000_000);
        break :blk g;
    };

    // Use native Zig EVM if available
    if (ctx.evm_state) |evm_state| {
        const calldata = parseHexData(alloc, data_hex) catch
            return rpc.errorJson(-32602, "eth_call: invalid hex data", id, alloc);
        defer alloc.free(calldata);

        const to_addr = parseAddress(to_hex);
        const from_addr = parseAddress(from_hex);

        const tx_input = evm_mod.TxInput{
            .from = from_addr,
            .to = to_addr,
            .value = value,
            .data = calldata,
            .gas_limit = gas,
            .nonce = 0,
        };

        const result = evm_mod.execute_call(evm_state, &tx_input, alloc) catch |err| {
            const msg = switch (err) {
                error.OutOfMemory => "out of memory",
                else => "evm call failed",
            };
            return rpc.errorJson(-32603, msg, id, alloc);
        };
        defer alloc.free(result.output);

        if (result.status == .revert) {
            const out_hex = toHexData(alloc, result.output) catch
                return rpc.errorJson(-32603, "out of memory", id, alloc);
            defer alloc.free(out_hex);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32015,\"message\":\"execution reverted\",\"data\":\"{s}\"}}}}",
                .{ id, out_hex });
        }

        const out_hex = toHexData(alloc, result.output) catch
            return rpc.errorJson(-32603, "out of memory", id, alloc);
        defer alloc.free(out_hex);

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
            .{ id, out_hex });
    }

    // Fallback: FFI Rust staticlib
    var result = evm_executor.call(alloc, to_hex, from_hex, data_hex, value, gas) catch |err| {
        const msg = switch (err) {
            error.Reverted => "execution reverted",
            error.OutOfMemory => "out of memory",
            else => "evm call failed",
        };
        return rpc.errorJson(-32603, msg, id, alloc);
    };
    defer result.deinit(alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, result.return_data });
}

/// eth_sendRawTransaction — accept signed RLP-encoded TX hex.
///
/// OmniBus chain does not yet decode RLP-signed Ethereum TXs. Returning
/// a fake hash would mislead wallets into thinking the transfer succeeded
/// when it did not — explicit rejection is safer. Native TXs use the
/// `sendrawtransaction` (lowercase) and `sendTransaction` RPCs.
pub fn handleEthSendRawTransaction(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return rpc.errorJson(
        -32004,
        "eth_sendRawTransaction not supported on OmniBus chain — use sendrawtransaction (native TX format)",
        id,
        ctx.allocator,
    );
}

/// eth_getCode — return deployed bytecode at address.
pub fn handleEthGetCode(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr_hex = rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "eth_getCode: missing address", id, alloc);

    // Use native Zig EVM state if available
    if (ctx.evm_state) |evm_state| {
        const addr = parseAddress(addr_hex);
        const code_bytes = if (evm_state.getAccountConst(addr)) |acc| acc.code else &.{};
        if (code_bytes.len == 0) {
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x\"}}", .{id});
        }
        const code_hex = try toHexData(alloc, code_bytes);
        defer alloc.free(code_hex);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
            .{ id, code_hex });
    }

    // Fallback: FFI Rust staticlib
    const code = evm_executor.getCode(alloc, addr_hex) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            else => "evm getCode failed",
        };
        return rpc.errorJson(-32603, msg, id, alloc);
    };
    defer alloc.free(code);

    if (code.len == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x\"}}", .{id});
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, code });
}

/// eth_estimateGas — gas estimation. Params: `[{from?,to,data,value?}]`.
pub fn handleEthEstimateGas(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to_hex = rpc.extractParamObjectField(body, "to") orelse
        return rpc.errorJson(-32602, "eth_estimateGas: missing 'to'", id, alloc);
    const from_hex = rpc.extractParamObjectField(body, "from") orelse
        "0x0000000000000000000000000000000000000000";
    const data_hex = rpc.extractParamObjectField(body, "data") orelse "0x";
    const value = rpc.extractParamObjectU64(body, "value");

    // Use native Zig EVM if available
    if (ctx.evm_state) |evm_state| {
        const calldata = parseHexData(alloc, data_hex) catch
            return rpc.errorJson(-32602, "eth_estimateGas: invalid hex data", id, alloc);
        defer alloc.free(calldata);

        const tx_input = evm_mod.TxInput{
            .from = parseAddress(from_hex),
            .to = parseAddress(to_hex),
            .value = value,
            .data = calldata,
            .gas_limit = 30_000_000,
            .nonce = 0,
        };

        const result = evm_mod.execute_call(evm_state, &tx_input, alloc) catch |err| {
            const msg = switch (err) {
                error.OutOfMemory => "out of memory",
                else => "evm estimateGas failed",
            };
            return rpc.errorJson(-32603, msg, id, alloc);
        };
        defer alloc.free(result.output);

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
            .{ id, result.gas_used });
    }

    // Fallback: FFI Rust staticlib
    const gas = evm_executor.estimateGas(alloc, from_hex, to_hex, data_hex, value) catch |err| {
        const msg = switch (err) {
            error.OutOfMemory => "out of memory",
            else => "evm estimateGas failed",
        };
        return rpc.errorJson(-32603, msg, id, alloc);
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
        .{ id, gas });
}

/// eth_chainId — return chain id as a hex string (per EIP-695).
pub fn handleEthChainId(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
        .{ id, ctx.chain_id });
}

/// eth_blockNumber — return current chain tip as hex (EIP-695 standard).
/// Required by ethers.js for any tx flow (deploy, send, query logs).
pub fn handleEthBlockNumber(ctx: *ServerCtx, id: u64) ![]u8 {
    const tip = ctx.bc.getBlockCount();
    const height: u64 = if (tip == 0) 0 else tip - 1;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x{x}\"}}",
        .{ id, height });
}

/// eth_getBalance — return account balance in wei as hex.
///
/// EVM addresses (last 20 bytes of keccak256(pubkey)) and OmniBus
/// addresses (bech32(hash160(pubkey))) derive differently, so there is no
/// bidirectional mapping. Wallets that want OmniBus balances should use
/// the native `getaddressbalance` RPC. Returning 0 here keeps ethers.js
/// pre-flight checks happy without lying about funds.
pub fn handleEthGetBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr_hex = rpc.extractStringFromArrayParams(body, 0) orelse
        return rpc.errorJson(-32602, "eth_getBalance: missing address", id, alloc);
    const addr_no_0x = if (addr_hex.len >= 2 and addr_hex[0] == '0' and (addr_hex[1] == 'x' or addr_hex[1] == 'X'))
        addr_hex[2..]
    else
        addr_hex;
    if (addr_no_0x.len != 40) {
        return rpc.errorJson(-32602, "eth_getBalance: address must be 20 bytes hex", id, alloc);
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x0\"}}",
        .{id});
}

/// eth_getTransactionCount — return account nonce as hex.
/// Params: `[address, "latest"]`. We track no nonces at the EVM-account level;
/// return 0 so ethers.js can submit txs (which then go through
/// eth_sendRawTransaction signed).
pub fn handleEthGetTransactionCount(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x0\"}}",
        .{id});
}

/// eth_gasPrice — return a fixed gas price in wei (1 gwei = 0x3b9aca00).
/// No fee market yet — flat-rate is fine for testnets/regtest.
pub fn handleEthGasPrice(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"0x3b9aca00\"}}",
        .{id});
}

/// net_version — legacy network identifier (decimal, not hex).
/// Many wallets/libs still use this alongside eth_chainId.
pub fn handleNetVersion(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{d}\"}}",
        .{ id, ctx.chain_id });
}

/// eth_getLogs — return matching logs. Params: `[{address, topics, fromBlock, toBlock}]`.
/// Chain does not run EVM bytecode, so contract event logs do not exist.
/// Returns an empty array (valid result for any filter) — clients get a
/// well-formed response instead of an error.
pub fn handleEthGetLogs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
        .{id});
}

/// eth_getTransactionReceipt — receipt for a tx hash.
/// Looks up the TX in the OmniBus chain (mined blocks only — pending TXs
/// have no receipt in Ethereum semantics) and returns an EIP-1474 receipt
/// shaped for ethers.js/web3 compatibility. status=0x1 for any TX that
/// reached a block (OmniBus has no TX-level revert semantics yet).
pub fn handleEthGetTransactionReceipt(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tx_hash_raw = rpc.extractStringFromArrayParams(body, 0) orelse
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});

    var tx_hash = tx_hash_raw;
    if (tx_hash.len >= 2 and tx_hash[0] == '0' and (tx_hash[1] == 'x' or tx_hash[1] == 'X'))
        tx_hash = tx_hash[2..];

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse {
        // Fallback: linear scan (TX not yet indexed)
        for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, tx_hash)) {
                    return ethReceiptJson(alloc, id, tx.hash, blk.hash, @intCast(blk.index), tx.from_address, tx.to_address);
                }
            }
        }
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    };

    if (block_height >= ctx.bc.chain.items.len) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    }
    const blk = ctx.bc.chain.items[block_height];
    for (blk.transactions.items) |tx| {
        if (std.mem.eql(u8, tx.hash, tx_hash)) {
            return ethReceiptJson(alloc, id, tx.hash, blk.hash, block_height, tx.from_address, tx.to_address);
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
}

/// Render an EIP-1474 receipt JSON. Address fields are ob-bech32, which
/// is non-standard for Ethereum tooling — clients that need 0x addresses
/// should resolve them via a separate name service. Logs always empty
/// because chain doesn't run EVM bytecode.
fn ethReceiptJson(
    alloc: std.mem.Allocator,
    id: u64,
    tx_hash: []const u8,
    block_hash: []const u8,
    block_height: u64,
    from: []const u8,
    to: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"transactionHash\":\"0x{s}\",\"transactionIndex\":\"0x0\"," ++
            "\"blockHash\":\"0x{s}\",\"blockNumber\":\"0x{x}\"," ++
            "\"from\":\"{s}\",\"to\":\"{s}\"," ++
            "\"cumulativeGasUsed\":\"0x5208\",\"gasUsed\":\"0x5208\"," ++
            "\"contractAddress\":null,\"logs\":[],\"logsBloom\":\"0x" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"status\":\"0x1\",\"type\":\"0x0\",\"effectiveGasPrice\":\"0x0\"" ++
        "}}}}",
        .{ id, tx_hash, block_hash, block_height, from, to });
}

/// eth_getBlockByNumber — block by tag/hex. V1 minimal: returns block info
/// in EIP-1474 shape with hashed-out fields. Sufficient for chain detect.
pub fn handleEthGetBlockByNumber(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    _ = body;
    const tip = ctx.bc.getBlockCount();
    const height: u64 = if (tip == 0) 0 else tip - 1;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"number\":\"0x{x}\",\"hash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"parentHash\":\"0x0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"timestamp\":\"0x0\",\"transactions\":[],\"gasLimit\":\"0x1c9c380\",\"gasUsed\":\"0x0\"," ++
            "\"miner\":\"0x0000000000000000000000000000000000000000\",\"difficulty\":\"0x{x}\"," ++
            "\"baseFeePerGas\":\"0x0\",\"extraData\":\"0x\"" ++
        "}}}}",
        .{ id, height, ctx.bc.difficulty });
}
