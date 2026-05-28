// Chain-state JSON-RPC handlers — block / chain queries.
//
// Bitcoin-Core analogues live in `src/rpc/blockchain.cpp`. These methods
// read chain state (tip, blocks, headers, Merkle proofs, difficulty) and
// never mutate it. All take `*ServerCtx` and hold `ctx.bc.mutex` only as
// long as needed; large outputs (block lists, transaction arrays) are
// built into heap-allocated buffers so the lock is released before the
// final JSON encode.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const block_mod = @import("../block.zig");
const blockchain_mod = @import("../blockchain.zig");
const validator_mod = @import("../validator_registry.zig");

const ServerCtx = rpc.ServerCtx;

pub fn handleGetBlockCount(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, ctx.bc.getBlockCount() });
}

// SEGFAULT-FIX [scan-2026-04-25]: use snapshot — hash is copied into snap.hash_buf
// before bc.mutex is released, so allocPrint formats stable bytes (no UAF on
// chain-owned hash slice when mining replaces the tip).
pub fn handleGetLatestBlock(ctx: *ServerCtx, id: u64) ![]u8 {
    var snap = ctx.bc.getLatestBlockSnapshot();
    defer snap.deinit(ctx.allocator);
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"index\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"nonce\":{d},\"txCount\":{d}}}}}",
        .{ id, snap.height, snap.timestamp, snap.hash(), snap.prevHash(), snap.nonce, snap.tx_count });
}

/// RPC "getchainmetrics" — high-level dashboard stats.
///
/// Aggregates everything an explorer dashboard would normally show on top:
///   - chain height + tip hash
///   - total supply (sum of all positive balances)
///   - total addresses with balance > 0
///   - validator count (balance ≥ MIN_VALIDATOR_BALANCE)
///   - validator-set size (active rotation participants)
///   - block count, mempool size, peer count
///   - emission stats (current reward, halving interval, max supply)
pub fn handleChainMetrics(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Address + supply tally from UTXO set (PHASE-B source of truth).
    var addresses_with_balance: u64 = 0;
    var validators: u64 = 0;
    var total_supply: u64 = 0;
    ctx.bc.utxo_set.lock.lockShared();
    defer ctx.bc.utxo_set.lock.unlockShared();
    var ait = ctx.bc.utxo_set.address_index.iterator();
    while (ait.next()) |kv| {
        _ = kv.key_ptr.*;
        // Inline tally — re-entering getBalance() would deadlock on the same RwLock.
        const list = kv.value_ptr.*;
        var bal: u64 = 0;
        for (list.items) |op| {
            if (ctx.bc.utxo_set.utxos.get(op)) |u| bal += u.amount;
        }
        if (bal == 0) continue;
        addresses_with_balance += 1;
        total_supply += bal;
        if (bal >= validator_mod.MIN_VALIDATOR_BALANCE) validators += 1;
    }

    const height: u64 = @intCast(ctx.bc.chain.items.len);
    const tip_hash: []const u8 = if (height > 0) ctx.bc.chain.items[height - 1].hash else "";
    const validator_set_size = ctx.bc.validator_set.items.len;
    const mempool_size: usize = if (ctx.mempool) |mp| mp.size() else 0;
    const peer_count: usize = if (ctx.p2p) |p| p.peers.items.len else 0;

    // Current block reward (uses blockchain.zig blockRewardAt — handles halvings).
    const current_reward = blockchain_mod.blockRewardAt(@intCast(height));

    // Latest block quick stats (tx count + fees) for dashboard — avoids extra getblock call.
    var latest_tx_count: usize = 0;
    var latest_fees: u64 = 0;
    var latest_timestamp: i64 = 0;
    if (height > 0) {
        const tip = ctx.bc.chain.items[height - 1];
        latest_tx_count = tip.transactions.items.len;
        latest_timestamp = tip.timestamp;
        for (tip.transactions.items) |tx| {
            if (tx.fee > 0) latest_fees += @as(u64, @intCast(tx.fee));
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"height\":{d}," ++
            "\"tipHash\":\"{s}\"," ++
            "\"totalSupply\":{d}," ++
            "\"addressesWithBalance\":{d}," ++
            "\"validators\":{d}," ++
            "\"validatorSetSize\":{d}," ++
            "\"minValidatorBalance\":{d}," ++
            "\"mempoolSize\":{d}," ++
            "\"peerCount\":{d}," ++
            "\"currentBlockReward\":{d}," ++
            "\"latestBlockTxCount\":{d}," ++
            "\"latestBlockFees\":{d}," ++
            "\"latestBlockTimestamp\":{d}," ++
            "\"satPerOmni\":1000000000" ++
            "}}}}",
        .{
            id, height, tip_hash, total_supply, addresses_with_balance,
            validators, validator_set_size, validator_mod.MIN_VALIDATOR_BALANCE,
            mempool_size, peer_count, current_reward,
            latest_tx_count, latest_fees, latest_timestamp,
        });
}

pub fn handleGetBlk(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h_str = rpc.extractArrayStr(body, 0);

    // Try parse as integer height first; if string is non-numeric and long enough, treat as hash
    var blk_opt: ?block_mod.Block = null;
    if (h_str) |s| {
        if (std.fmt.parseInt(u32, s, 10)) |height| {
            blk_opt = ctx.bc.getBlock(height);
        } else |_| {
            // Bitcoin-standard: getblock(hash) — linear scan blocks for matching hash
            ctx.bc.mutex.lock();
            const block_count = ctx.bc.getBlockCountUnlocked();
            var bi: u32 = 0;
            while (bi < block_count) : (bi += 1) {
                const b = ctx.bc.getBlock(bi) orelse continue;
                if (std.mem.eql(u8, b.hash, s)) { blk_opt = b; break; }
            }
            ctx.bc.mutex.unlock();
            if (blk_opt == null) return rpc.errorJson(-5, "Block not found", id, alloc);
        }
    } else {
        const height: u32 = std.math.cast(u32, rpc.extractArrayNum(body, 0)) orelse 0;
        blk_opt = ctx.bc.getBlock(height);
    }

    const blk = blk_opt orelse return rpc.errorJson(-5, "Block not found", id, alloc);

    // Format merkle_root as hex (it's [32]u8)
    var mr_hex: [64]u8 = undefined;
    for (0..32) |i| {
        const b = blk.merkle_root[i];
        mr_hex[i * 2] = "0123456789abcdef"[b >> 4];
        mr_hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }

    // Approximate size: header (~80 bytes) + tx_count * avg_tx_bytes (~200)
    const tx_count = blk.transactions.items.len;
    const approx_size: u64 = 80 + @as(u64, @intCast(tx_count)) * 200;

    // Sum fees for all non-coinbase TXs in this block
    var total_fees: u64 = 0;
    for (blk.transactions.items) |tx| {
        if (tx.fee > 0) total_fees += @as(u64, @intCast(tx.fee));
    }

    // Build optional prices array. Strategy:
    //   1) FAST path — read the in-memory `block_prices` map (legacy 6-slot
    //      snapshot, populated at mining time). This avoids touching the
    //      block's [21]BlockPriceEntry array on every getblock call.
    //   2) FALLBACK — if the map has no entry for this height (e.g. after
    //      a node restart, since the map is in-memory only), read directly
    //      from `blk.prices` which is the authoritative on-chain copy
    //      committed via prices_root in the block hash.
    //   In both cases empty/zero entries are skipped.
    var prices_buf: [4096]u8 = undefined;
    var prices_len: usize = 0;
    {
        var pos: usize = 0;
        const open = std.fmt.bufPrint(prices_buf[pos..], "[", .{}) catch {
            return rpc.errorJson(-32603, "buf overflow", id, alloc);
        };
        pos += open.len;
        var written: usize = 0;
        if (ctx.bc.getBlockPrices(blk.index)) |entries| {
            // Fast path: legacy in-memory cache (6 slots).
            for (entries) |e| {
                if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
                if (written > 0) { prices_buf[pos] = ','; pos += 1; }
                const ex = e.exchange[0..e.exchange_len];
                const pr = e.pair[0..e.pair_len];
                const item = std.fmt.bufPrint(prices_buf[pos..],
                    "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                    .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
                ) catch break;
                pos += item.len;
                written += 1;
            }
        } else {
            // Fallback path: read directly from on-chain block (21 slots).
            for (blk.prices) |e| {
                if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
                if (written > 0) { prices_buf[pos] = ','; pos += 1; }
                const ex = e.exchange[0..e.exchange_len];
                const pr = e.pair[0..e.pair_len];
                const item = std.fmt.bufPrint(prices_buf[pos..],
                    "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                    .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
                ) catch break;
                pos += item.len;
                written += 1;
            }
        }
        const close = std.fmt.bufPrint(prices_buf[pos..], "]", .{}) catch {
            return rpc.errorJson(-32603, "buf overflow", id, alloc);
        };
        pos += close.len;
        prices_len = pos;
    }

    // Hex-encode prices_root (32 bytes -> 64 lowercase hex chars). All-zero
    // is the canonical "no prices" sentinel — clients should still treat
    // pricesValidated=true on an all-zero root as "nothing to verify".
    var pr_hex: [64]u8 = undefined;
    for (0..32) |i| {
        const b = blk.prices_root[i];
        pr_hex[i * 2] = "0123456789abcdef"[b >> 4];
        pr_hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }
    const prices_validated = blk.validatePrices();

    // Build transactions array: array of txid strings so BlockPage can
    // load individual TX details via gettransaction.
    var tx_arr: []u8 = try alloc.dupe(u8, "");
    for (blk.transactions.items, 0..) |tx, ti| {
        const sep: []const u8 = if (ti == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc, "{s}\"{s}\"", .{ sep, tx.hash });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ tx_arr, e });
        alloc.free(tx_arr); alloc.free(e); tx_arr = m;
    }
    defer alloc.free(tx_arr);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"hash\":\"{s}\",\"height\":{d},\"timestamp\":{d},\"previousHash\":\"{s}\",\"merkleRoot\":\"{s}\",\"difficulty\":{d},\"nonce\":{d},\"txCount\":{d},\"size\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d},\"totalFees\":{d},\"transactions\":[{s}],\"prices\":{s},\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}}}",
        .{ id, blk.hash, blk.index, blk.timestamp, blk.previous_hash, mr_hex, ctx.bc.difficulty, blk.nonce, tx_count, approx_size, blk.miner_address, blk.reward_sat, total_fees, tx_arr, prices_buf[0..prices_len], pr_hex, if (prices_validated) "true" else "false" });
}

pub fn handleGetBlks(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, rpc.extractArrayNum(body, 0)) orelse 0;
    const rc = rpc.extractArrayNum(body, 1);
    const mc: u32 = if (rc == 0 or rc > 100) 100 else std.math.cast(u32, rc) orelse 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: u32 = 0;
    var h: u32 = from;
    while (n < mc) : ({ h += 1; n += 1; }) {
        const blk = ctx.bc.getBlock(h) orelse break;
        const sep: []const u8 = if (n == 0) "" else ",";
        var blk_fees: u64 = 0;
        for (blk.transactions.items) |tx| { if (tx.fee > 0) blk_fees += @as(u64, @intCast(tx.fee)); }
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"height\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"nonce\":{d},\"txCount\":{d},\"miner\":\"{s}\",\"rewardSAT\":{d},\"totalFees\":{d},\"difficulty\":{d}}}", .{ sep, blk.index, blk.timestamp, blk.hash, blk.nonce, blk.transactions.items.len, blk.miner_address, blk.reward_sat, blk_fees, ctx.bc.difficulty });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":{d},\"count\":{d},\"blocks\":[{s}]}}}}", .{ id, from, n, entries });
}

/// RPC "getheaders" — returns block headers for light client sync.
/// Usage: {"method":"getheaders","params":[from_height, count],"id":1}
/// Returns array of block headers (without transaction data).
/// Max 2000 headers per request (like Bitcoin's getheaders).
pub fn handleGetHeaders(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, rpc.extractArrayNum(body, 0)) orelse 0;
    const req_count = rpc.extractArrayNum(body, 1);
    const max_headers: u32 = 2000;
    const count: u32 = if (req_count == 0 or req_count > max_headers) max_headers else std.math.cast(u32, req_count) orelse max_headers;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var entries: []u8 = try alloc.dupe(u8, "");
    var n: u32 = 0;
    var h: u32 = from;
    while (n < count) : ({ h += 1; n += 1; }) {
        const blk = ctx.bc.getBlock(h) orelse break;
        const sep: []const u8 = if (n == 0) "" else ",";

        // Format merkle_root and hash as hex strings
        var mr_hex: [64]u8 = undefined;
        var hash_hex: [64]u8 = undefined;
        var prev_hex: [64]u8 = undefined;
        for (0..32) |i| {
            const mr_byte = blk.merkle_root[i];
            mr_hex[i * 2] = "0123456789abcdef"[mr_byte >> 4];
            mr_hex[i * 2 + 1] = "0123456789abcdef"[mr_byte & 0x0f];
        }
        // Block hash and previous_hash are slices (string hex), not [32]u8
        // We return them as-is since they are already hex strings from the block
        _ = &hash_hex;
        _ = &prev_hex;

        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"height\":{d},\"timestamp\":{d},\"hash\":\"{s}\",\"previousHash\":\"{s}\",\"merkleRoot\":\"{s}\",\"nonce\":{d},\"difficulty\":{d},\"txCount\":{d}}}",
            .{ sep, blk.index, blk.timestamp, blk.hash, blk.previous_hash, mr_hex, blk.nonce, ctx.bc.difficulty, blk.transactions.items.len });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":{d},\"count\":{d},\"headers\":[{s}]}}}}",
        .{ id, from, n, entries });
}

/// RPC "getmerkleproof" — returns a Merkle inclusion proof for a TX.
/// Usage: {"method":"getmerkleproof","params":["tx_hash_hex"],"id":1}
/// Searches all blocks for the TX, then generates the Merkle proof.
/// Returns proof_hashes and directions for SPV verification.
pub fn handleGetMerkleProof(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tx_hash_str = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "txid") orelse
        return rpc.errorJson(-32602, "Missing param: txid (tx hash hex)", id, alloc);

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Search blocks for the TX
    const block_count = ctx.bc.getBlockCountUnlocked();
    var found_block_idx: ?u32 = null;
    var found_tx_idx: ?usize = null;

    var bi: u32 = 0;
    while (bi < block_count) : (bi += 1) {
        const blk = ctx.bc.getBlock(bi) orelse continue;
        for (blk.transactions.items, 0..) |tx, ti| {
            if (std.mem.eql(u8, tx.hash, tx_hash_str)) {
                found_block_idx = bi;
                found_tx_idx = ti;
                break;
            }
        }
        if (found_block_idx != null) break;
    }

    const blk_idx = found_block_idx orelse return rpc.errorJson(-32602, "TX not found in any block", id, alloc);
    const tx_idx = found_tx_idx.?;

    const blk = ctx.bc.getBlock(blk_idx).?;
    const proof_opt = blk.generateMerkleProof(tx_idx);
    if (proof_opt == null) return rpc.errorJson(-32000, "Failed to generate proof", id, alloc);
    const proof = proof_opt.?;

    // Serialize proof hashes as hex
    var proof_entries: []u8 = try alloc.dupe(u8, "");
    for (0..proof.depth) |i| {
        const sep: []const u8 = if (i == 0) "" else ",";
        var hex: [64]u8 = undefined;
        for (0..32) |j| {
            const b = proof.proof_hashes[i][j];
            hex[j * 2] = "0123456789abcdef"[b >> 4];
            hex[j * 2 + 1] = "0123456789abcdef"[b & 0x0f];
        }
        const dir_str: []const u8 = if (proof.directions[i]) "right" else "left";
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"hash\":\"{s}\",\"direction\":\"{s}\"}}", .{ sep, hex, dir_str });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ proof_entries, e });
        alloc.free(proof_entries); alloc.free(e); proof_entries = m;
    }
    defer alloc.free(proof_entries);

    // Merkle root hex
    var root_hex: [64]u8 = undefined;
    for (0..32) |i| {
        const b = proof.merkle_root[i];
        root_hex[i * 2] = "0123456789abcdef"[b >> 4];
        root_hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"blockHeight\":{d},\"txIndex\":{d},\"merkleRoot\":\"{s}\",\"proofDepth\":{d},\"proof\":[{s}]}}}}",
        .{ id, tx_hash_str, blk_idx, tx_idx, root_hex, proof.depth, proof_entries });
}

/// getblockchaininfo — comprehensive node status (matches Bitcoin RPC).
pub fn handleBlockchainInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const block_count = ctx.bc.getBlockCount();
    const difficulty = ctx.bc.difficulty;
    const mp_size: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
    const peer_count: u64 = if (ctx.p2p) |p| @intCast(p.peers.items.len) else 0;
    const chain_label: []const u8 = switch (ctx.chain_id) {
        1 => "omnibus-mainnet",
        2 => "omnibus-testnet",
        3 => "omnibus-devnet",
        4 => "omnibus-regtest",
        else => "omnibus-unknown",
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blocks\":{d},\"difficulty\":{d},\"chain\":\"{s}\",\"mempool_size\":{d},\"peers\":{d},\"version\":\"0.3.0\",\"subversion\":\"OmniBus-PoUW\"}}}}",
        .{ id, block_count, difficulty, chain_label, mp_size, peer_count },
    );
}

// SEGFAULT-FIX [scan-2026-04-25]: use snapshot — hash is copied into snap.hash_buf
// before bc.mutex is released, so allocPrint formats stable bytes (no UAF on
// chain-owned hash slice when mining replaces the tip).
pub fn handleGetBestBlockHash(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var snap = ctx.bc.getLatestBlockSnapshot();
    defer snap.deinit(alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, snap.hash() },
    );
}

/// getdifficulty — returns current network difficulty as a number.
pub fn handleGetDifficulty(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{d}}}",
        .{ id, ctx.bc.difficulty },
    );
}

/// getblockhash — params [height: int], returns hash of block at given height.
/// Error -8 (Bitcoin standard) if out of range.
pub fn handleGetBlockHash(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Accept either ["123"] (string) or [123] (number)
    const h_str = rpc.extractArrayStr(body, 0);
    const height: u32 = if (h_str) |s|
        std.fmt.parseInt(u32, s, 10) catch return rpc.errorJson(-8, "Block height out of range", id, alloc)
    else
        std.math.cast(u32, rpc.extractArrayNum(body, 0)) orelse return rpc.errorJson(-8, "Block height out of range", id, alloc);

    const block_count = ctx.bc.getBlockCount();
    if (height >= block_count) return rpc.errorJson(-8, "Block height out of range", id, alloc);

    const blk = ctx.bc.getBlock(height) orelse return rpc.errorJson(-8, "Block height out of range", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":\"{s}\"}}",
        .{ id, blk.hash },
    );
}
