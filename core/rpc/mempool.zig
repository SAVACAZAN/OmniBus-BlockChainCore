// Mempool JSON-RPC handlers — pending TX pool queries + fee estimation.
//
// Bitcoin-Core analogues live in `src/rpc/mempool.cpp`. These methods
// inspect the pending-TX pool (`ctx.mempool` if attached, else the
// in-blockchain fallback `ctx.bc.mempool`), report fee suggestions, and
// expose live performance metrics from `benchmark.Metrics`. They never
// mutate the pool — that goes through `sendtransaction` / `sendrawtransaction`
// in rpc/wallet.zig.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const mempool_mod = @import("../mempool.zig");
const blockchain_mod = @import("../blockchain.zig");

const ServerCtx = rpc.ServerCtx;

pub fn handleGetMempoolSize(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, ctx.bc.mempool.items.len });
}

/// getmempoolinfo — mempool stats (matches Bitcoin RPC).
pub fn handleMempoolInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    ctx.bc.mutex.lock();
    const size: u64 = @intCast(ctx.bc.mempool.items.len);
    var bytes: u64 = 0;
    for (ctx.bc.mempool.items) |tx| {
        bytes += rpc.estimateTxBytes(tx.scheme);
    }
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"bytes\":{d}}}}}",
        .{ id, size, bytes },
    );
}

// External mempool struct (ctx.mempool) has its own internal sync; only the bc.mempool
// fallback needs the lock here.
pub fn handleMpStats(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.mempool) |m| {
        return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"maxTx\":{d},\"maxBytes\":{d},\"bytes\":{d}}}}}", .{ id, m.size(), mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES, m.bytes() });
    }
    ctx.bc.mutex.lock();
    const mp_len = ctx.bc.mempool.items.len;
    var mp_bytes: u64 = 0;
    for (ctx.bc.mempool.items) |tx| mp_bytes += rpc.estimateTxBytes(tx.scheme);
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"size\":{d},\"maxTx\":{d},\"maxBytes\":{d},\"bytes\":{d}}}}}", .{ id, mp_len, mempool_mod.MEMPOOL_MAX_TX, mempool_mod.MEMPOOL_MAX_BYTES, mp_bytes });
}

/// RPC "getpendingtxs" — returns all TXs currently in the mempool with scheme info.
/// Params: [limit]  (default 100, max 500)
/// Returns: { count, transactions: [{txid,from,to,amount,fee,scheme,nonce,timestamp}] }
pub fn handleGetPendingTxs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_limit = rpc.extractArrayNum(body, 0);
    const limit: usize = if (req_limit > 0 and req_limit <= 500) @intCast(req_limit) else 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const items = ctx.bc.mempool.items;
    const take = @min(limit, items.len);

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: usize = 0;
    // Return newest first (reverse order)
    var i: usize = if (items.len > 0) items.len - 1 else 0;
    while (n < take) : (n += 1) {
        const tx = items[i];
        const sep: []const u8 = if (n == 0) "" else ",";
        const kind = rpc.inferTxKind(tx);
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"kind\":\"{s}\",\"scheme\":\"{s}\",\"nonce\":{d},\"timestamp\":{d}}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee,
               kind, rpc.txSchemeLabel(tx.scheme), tx.nonce, tx.timestamp });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
        if (i == 0) break;
        i -= 1;
    }
    defer alloc.free(entries);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"transactions\":[{s}]}}}}",
        .{ id, n, entries });
}

pub fn handleEstimateFee(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Use mempool median fee if available, else fall back to TX_MIN_FEE_SAT
    const suggested_fee: u64 = if (ctx.mempool) |m| m.medianFee() else mempool_mod.TX_MIN_FEE_SAT;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"feeSAT\":{d},\"minFeeSAT\":{d},\"burnPct\":{d}}}}}",
        .{ id, suggested_fee, mempool_mod.TX_MIN_FEE_SAT, blockchain_mod.FEE_BURN_PCT });
}

/// RPC "getperformance" — returns live performance metrics.
/// Usage: {"method":"getperformance","id":1}
pub fn handleGetPerformance(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.metrics) |m| {
        const uptime = m.uptimeSeconds();
        const bpm = m.blocksPerMinute();
        const current_tps = m.currentTps();
        const avg_bt = m.avgBlockTimeMs();
        const mp_throughput: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uptime_seconds\":{d},\"blocks_mined\":{d},\"blocks_per_minute\":{d},\"txs_processed\":{d},\"tps_current\":{d},\"mempool_throughput\":{d},\"avg_block_time_ms\":{d},\"peak_tps\":{d},\"rpc_requests_total\":{d},\"p2p_messages_total\":{d},\"hashrate\":{d}}}}}",
            .{ id, uptime, m.blocks_mined, bpm, m.txs_processed, current_tps, mp_throughput, avg_bt, m.peak_tps, m.rpc_requests, m.p2p_messages, m.hashrate });
    }
    // No metrics attached — return zeros with uptime from block count estimate
    const block_count = ctx.bc.getBlockCount();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"uptime_seconds\":0,\"blocks_mined\":{d},\"blocks_per_minute\":0,\"txs_processed\":0,\"tps_current\":0,\"mempool_throughput\":{d},\"avg_block_time_ms\":0,\"peak_tps\":0,\"rpc_requests_total\":0,\"p2p_messages_total\":0,\"hashrate\":0}}}}",
        .{ id, block_count, ctx.bc.mempool.items.len });
}
