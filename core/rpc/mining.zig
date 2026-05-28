// Mining JSON-RPC handlers — miner registration, pool/miner stats.
//
// Bitcoin-Core analogues live in `src/rpc/mining.cpp`. These methods manage
// the in-memory miner registry (used by the bootstrap/anti-sybil layer) and
// expose live mining stats. `registerminer` mutates registry state under
// `ctx.reg_mutex`; the read-only methods snapshot `ctx.bc.mutex` then format
// outside the lock to avoid blocking the mining loop.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const bootstrap = @import("../bootstrap.zig");
const main_mod = @import("../main.zig");

const ServerCtx = rpc.ServerCtx;

pub fn handleRegMiner(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const nid = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "node_id") orelse "unknown";
    // F8: Optional mnemonic (3rd param) — if provided, derive real key pair
    const mnemonic = rpc.extractArrayStr(body, 2) orelse rpc.extractStr(body, "mnemonic");
    const h = ctx.bc.getBlockCount();

    // Salveaza minerul in registru (daca nu exista deja — unic pe address SI node_id)
    ctx.reg_mutex.lock();
    defer ctx.reg_mutex.unlock();
    var already = false;
    for (ctx.registered_miners[0..ctx.registered_miner_count]) |*m| {
        const same_addr = std.mem.eql(u8, m.address[0..m.address_len], addr);
        const same_nid = std.mem.eql(u8, m.node_id[0..m.node_id_len], nid);
        if (same_addr or same_nid) { already = true; break; }
    }
    if (!already and ctx.registered_miner_count < rpc.MAX_REGISTERED_MINERS) {
        var m = &ctx.registered_miners[ctx.registered_miner_count];
        m.* = .{};
        const alen = @min(addr.len, 64);
        @memcpy(m.address[0..alen], addr[0..alen]);
        m.address_len = @intCast(alen);
        const nlen = @min(nid.len, 32);
        @memcpy(m.node_id[0..nlen], nid[0..nlen]);
        m.node_id_len = @intCast(nlen);
        m.registered_at = std.time.timestamp();
        ctx.registered_miner_count += 1;
        // Notify bootstrap system
        bootstrap.BootstrapNode.registered_miner_count = ctx.registered_miner_count;

        // F8: Register in MinerWalletPool with real key pair
        var has_wallet = false;
        if (mnemonic) |mnem| {
            if (main_mod.g_miner_pool.registerWithMnemonic(addr, mnem, alloc)) |ok| {
                has_wallet = ok;
            } else |_| {}
        }
        if (!has_wallet) {
            // Fallback: register with random key pair
            main_mod.g_miner_pool.register(addr);
            has_wallet = true;
        }

        // F8: Register miner's pubkey in blockchain for TX signature verification
        if (main_mod.g_miner_pool.findByAddress(addr)) |mw| {
            ctx.bc.registerPubkey(addr, mw.getPubkeyHex()) catch {};
        }

        std.debug.print("[RPC] Miner registered: {s} ({s}) — total: {d}/{d} | pool: {d} | wallet: {}\n",
            .{ addr, nid, ctx.registered_miner_count, bootstrap.BootstrapNode.MIN_MINERS_FOR_MINING,
               main_mod.g_miner_pool.count, has_wallet });
    }

    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"registered\",\"miner\":\"{s}\",\"node_id\":\"{s}\",\"blockHeight\":{d},\"totalMiners\":{d}}}}}", .{ id, addr, nid, h, ctx.registered_miner_count });
}

// SEGFAULT-FIX [scan-2026-04-25]: snapshot scalars under bc.mutex, then format outside.
// Mempool ArrayList is mutated by mining (drains into block) and addTransaction —
// reading items.len concurrently with realloc/clear is a torn read.
pub fn handlePoolStats(ctx: *ServerCtx, id: u64) ![]u8 {
    ctx.bc.mutex.lock();
    const h = ctx.bc.getBlockCountUnlocked();
    const mp_len = ctx.bc.mempool.items.len;
    const diff = ctx.bc.difficulty;
    ctx.bc.mutex.unlock();
    const r = blockchain_mod.blockRewardAt(h);
    return std.fmt.allocPrint(ctx.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blockHeight\":{d},\"blockRewardSAT\":{d},\"blockRewardOMNI\":{d},\"mempoolSize\":{d},\"difficulty\":{d},\"nodeAddress\":\"{s}\"}}}}", .{ id, h, r, r / 1_000_000_000, mp_len, diff, ctx.wallet.address });
}

pub fn handleMinerSt(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Lock blockchain pentru toata durata — previne realloc pe chain.items
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Colectam adrese unice — max 64 (limitat pentru stabilitate)
    const MinerEntry = struct { addr: [64]u8, addr_len: u8, blocks: u32, reward: u64 };
    const MAX_DISPLAY: usize = 64;
    var list: [MAX_DISPLAY]MinerEntry = undefined;
    var count: usize = 0;

    // Helper: cauta daca adresa exista deja
    const findOrAdd = struct {
        fn call(l: []MinerEntry, c: *usize, addr: []const u8) *MinerEntry {
            for (l[0..c.*]) |*e| {
                if (e.addr_len == addr.len and std.mem.eql(u8, e.addr[0..e.addr_len], addr)) return e;
            }
            if (c.* >= l.len) return &l[0]; // overflow guard
            var e = &l[c.*];
            e.* = .{ .addr = undefined, .addr_len = @intCast(@min(addr.len, 64)), .blocks = 0, .reward = 0 };
            @memcpy(e.addr[0..e.addr_len], addr[0..e.addr_len]);
            c.* += 1;
            return e;
        }
    }.call;

    // 1. Seed node (self) — mereu primul
    _ = findOrAdd(&list, &count, ctx.wallet.address);

    // 2. Mineri inregistrati via RPC
    ctx.reg_mutex.lock();
    const reg_count = @min(ctx.registered_miner_count, MAX_DISPLAY - 1);
    var reg_addrs: [64][64]u8 = undefined;
    var reg_lens: [64]u8 = undefined;
    for (0..reg_count) |i| {
        const rm = ctx.registered_miners[i];
        reg_addrs[i] = rm.address;
        reg_lens[i] = rm.address_len;
    }
    ctx.reg_mutex.unlock();
    for (0..reg_count) |i| {
        if (reg_lens[i] > 0) _ = findOrAdd(&list, &count, reg_addrs[i][0..reg_lens[i]]);
    }

    // 3. Stats din blocuri minate (bc.mutex deja locked la inceputul functiei)
    for (ctx.bc.chain.items) |blk| {
        if (blk.miner_address.len == 0) continue;
        var e = findOrAdd(&list, &count, blk.miner_address);
        e.blocks += 1;
        e.reward += blk.reward_sat;
    }

    // Serializare JSON — buffer fix 32KB (zero alloc in loop)
    var buf: [32768]u8 = undefined;
    var pos: usize = 0;
    // total_fees_collected is the cumulative network/exchange fees paid to
    // miners since process start (see Blockchain.total_miner_exchange_fees).
    // pending_miner_fees is the sat amount accumulated since the last block
    // and earmarked for the next block's miner.
    const header = std.fmt.bufPrint(
        buf[0..],
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"totalMiners\":{d},\"chainHeight\":{d}," ++
        "\"totalFeesCollected\":{d},\"pendingMinerFees\":{d}," ++
        "\"miners\":[",
        .{
            id, count, ctx.bc.getBlockCountUnlocked() -| 1,
            ctx.bc.total_miner_exchange_fees, ctx.bc.pending_miner_fees,
        },
    ) catch return rpc.errorJson(-32000, "Buffer overflow", id, alloc);
    pos = header.len;
    for (list[0..count], 0..) |e, i| {
        const addr = e.addr[0..e.addr_len];
        const bal = ctx.bc.getAddressBalance(addr);
        const sep: []const u8 = if (i == 0) "" else ",";
        const entry = std.fmt.bufPrint(buf[pos..], "{s}{{\"miner\":\"{s}\",\"blocksMined\":{d},\"totalRewardSAT\":{d},\"currentBalanceSAT\":{d}}}", .{ sep, addr, e.blocks, e.reward, bal }) catch break;
        pos += entry.len;
    }
    const footer = std.fmt.bufPrint(buf[pos..], "]}}}}", .{}) catch return rpc.errorJson(-32000, "Buffer overflow", id, alloc);
    pos += footer.len;
    return alloc.dupe(u8, buf[0..pos]);
}

pub fn handleMinerInf(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const h = ctx.bc.getBlockCount(); const d = ctx.bc.difficulty;
    const ma = ctx.wallet.address; const bal = ctx.wallet.getBalance();
    var bm: u32 = 0;
    for (ctx.bc.chain.items) |blk| { if (std.mem.eql(u8, blk.miner_address, ma)) bm += 1; }
    const st: []const u8 = if (ctx.is_idle) "idle" else "active";
    const rs: []const u8 = if (ctx.is_idle) "duplicate_ip_detected" else "";
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"status\":\"{s}\",\"reason\":\"{s}\",\"miner\":\"{s}\"," ++
        "\"blocksMined\":{d},\"balance\":{d},\"height\":{d},\"difficulty\":{d}," ++
        "\"totalFeesCollected\":{d},\"pendingMinerFees\":{d}," ++
        "\"routeFeesToMiner\":{}}}}}",
        .{
            id, st, rs, ma, bm, bal, h, d,
            ctx.bc.total_miner_exchange_fees,
            ctx.bc.pending_miner_fees,
            ctx.bc.consensus_params.route_fees_to_miner,
        });
}

/// getmininginfo — mining stats: blocks (height), difficulty, hashrate, mempool, chain.
pub fn handleGetMiningInfo(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const blocks = ctx.bc.getBlockCount();
    const difficulty = ctx.bc.difficulty;
    const mp_size: u64 = if (ctx.mempool) |mp| @intCast(mp.size()) else @intCast(ctx.bc.mempool.items.len);
    // hashrate: from metrics if attached, otherwise hardcoded placeholder.
    // TODO: actual measurement when metrics not attached.
    const hashrate: u64 = if (ctx.metrics) |m| m.hashrate else 1000;
    const reward = blockchain_mod.blockRewardAt(blocks);
    const chain_label: []const u8 = switch (ctx.chain_id) {
        1 => "omnibus-mainnet",
        2 => "omnibus-testnet",
        3 => "omnibus-devnet",
        4 => "omnibus-regtest",
        else => "omnibus-unknown",
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"blocks\":{d},\"difficulty\":{d},\"networkhashps\":{d},\"hashrate\":{d},\"pooledtx\":{d},\"chain\":\"{s}\",\"currentblockreward\":{d}}}}}",
        .{ id, blocks, difficulty, hashrate, hashrate, mp_size, chain_label, reward },
    );
}
