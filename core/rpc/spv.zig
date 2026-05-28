// spv.zig — SPV light-client RPC handlers extracted from rpc_server.zig.
const std = @import("std");
const rpc = @import("../rpc_server.zig");
const spv_btc_mod = @import("../spv_btc.zig");
const spv_eth_mod = @import("../spv_eth.zig");
const ServerCtx = rpc.ServerCtx;

pub fn handleSpvBtcVerifyTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    rpc.ensureOracleLoaded();

    const txh_str = rpc.extractStr(body, "tx_hash") orelse
        return rpc.errorJson(-32602, "Missing param: tx_hash", id, ctx.allocator);
    const root_str = rpc.extractStr(body, "merkle_root") orelse
        return rpc.errorJson(-32602, "Missing param: merkle_root", id, ctx.allocator);
    const path_str = rpc.extractStr(body, "merkle_path") orelse "";
    const idx_str = rpc.extractStr(body, "indices") orelse "";

    const txh = rpc.parseHex32Spv(txh_str) orelse
        return rpc.errorJson(-32602, "Bad tx_hash", id, ctx.allocator);
    const root = rpc.parseHex32Spv(root_str) orelse
        return rpc.errorJson(-32602, "Bad merkle_root", id, ctx.allocator);

    // merkle_path is a concatenated hex string of 32-byte siblings.
    // indices is a string of '0'/'1' chars, one per level.
    if (path_str.len % 64 != 0) {
        return rpc.errorJson(-32602, "merkle_path must be multiples of 64 hex chars", id, ctx.allocator);
    }
    const levels = path_str.len / 64;
    if (levels != idx_str.len) {
        return rpc.errorJson(-32602, "merkle_path/indices length mismatch", id, ctx.allocator);
    }
    if (levels > 64) {
        return rpc.errorJson(-32602, "Too many levels (>64)", id, ctx.allocator);
    }

    var path_buf: [64][32]u8 = undefined;
    var idx_buf: [64]u1 = undefined;
    var i: usize = 0;
    while (i < levels) : (i += 1) {
        const seg = path_str[i * 64 .. (i + 1) * 64];
        path_buf[i] = rpc.parseHex32Spv(seg) orelse
            return rpc.errorJson(-32602, "Bad merkle_path segment", id, ctx.allocator);
        idx_buf[i] = if (idx_str[i] == '1') @as(u1, 1) else @as(u1, 0);
    }

    const ok = spv_btc_mod.verifyMerkleProof(txh, path_buf[0..levels], idx_buf[0..levels], root);
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"valid\":{s}}}}}",
        .{ id, if (ok) "true" else "false" });
}

pub fn handleSpvEthVerifyEvent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    rpc.ensureOracleLoaded();
    // Full PMT verification path — caller supplies the trie key
    // (RLP-encoded tx index), the receipt RLP, and the proof nodes
    // (pipe-separated hex). receipts_root is read from the recorded
    // ETH anchor for the requested chain_id.
    const cid_str = rpc.extractStr(body, "chain_id") orelse "1";
    const cid = std.fmt.parseInt(u64, cid_str, 10) catch
        return rpc.errorJson(-32602, "Bad chain_id", id, ctx.allocator);

    rpc.g_xchain_oracle_mutex.lock();
    const anchor_opt = rpc.g_xchain_oracle.latestEth(cid);
    rpc.g_xchain_oracle_mutex.unlock();
    const anchor = anchor_opt orelse
        return rpc.errorJson(-32030, "No anchor recorded for chain_id", id, ctx.allocator);

    const tx_index_hex = rpc.extractStr(body, "tx_index_rlp_hex") orelse
        return rpc.errorJson(-32602, "Missing tx_index_rlp_hex", id, ctx.allocator);
    const receipt_hex = rpc.extractStr(body, "receipt_rlp_hex") orelse
        return rpc.errorJson(-32602, "Missing receipt_rlp_hex", id, ctx.allocator);
    const proof_hex = rpc.extractStr(body, "receipt_proof_hex") orelse
        return rpc.errorJson(-32602, "Missing receipt_proof_hex", id, ctx.allocator);

    const alloc = ctx.allocator;
    const key = rpc.hexAlloc(alloc, tx_index_hex) orelse
        return rpc.errorJson(-32602, "Bad tx_index_rlp_hex", id, alloc);
    defer alloc.free(key);
    const value = rpc.hexAlloc(alloc, receipt_hex) orelse
        return rpc.errorJson(-32602, "Bad receipt_rlp_hex", id, alloc);
    defer alloc.free(value);

    var nodes_storage: [64][]u8 = undefined;
    var node_slices: [64][]const u8 = undefined;
    var n: usize = 0;
    defer {
        var k: usize = 0;
        while (k < n) : (k += 1) alloc.free(nodes_storage[k]);
    }
    var it = std.mem.splitScalar(u8, proof_hex, '|');
    while (it.next()) |part| {
        if (n >= 64) return rpc.errorJson(-32602, "Too many proof nodes", id, alloc);
        const decoded = rpc.hexAlloc(alloc, part) orelse
            return rpc.errorJson(-32602, "Bad receipt_proof_hex element", id, alloc);
        nodes_storage[n] = decoded;
        node_slices[n] = decoded;
        n += 1;
    }

    const ok = spv_eth_mod.verifyReceiptAtIndex(
        anchor.receipts_root, key, value, node_slices[0..n],
    );
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"verified\":{s},\"chain_id\":{d},\"block_number\":{d}}}}}",
        .{ id, if (ok) "true" else "false", cid, anchor.block_number });
}
