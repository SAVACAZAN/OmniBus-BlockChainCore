// General wallet JSON-RPC handlers — balance, send TX, nonce, history,
// faucet, rich list, multisig.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const wallet_mod = @import("../wallet.zig");
const transaction_mod = @import("../transaction.zig");
const tx_payload_mod = @import("../tx_payload.zig");
const mempool_mod = @import("../mempool.zig");
const multisig_mod = @import("../multisig.zig");
const faucet_mod = @import("../faucet.zig");
const miner_wallet_mod = @import("../miner_wallet.zig");
const isolated_wallet_mod = @import("../isolated_wallet.zig");
const main_mod = @import("../main.zig");

// Additional imports required by extracted handlers (referenced via these
// module aliases in the original rpc_server.zig body, no rewrite specified).
const hex_utils = @import("../hex_utils.zig");
const staking_mod = @import("../staking.zig");
const registrar_mod = @import("../registrar_addresses.zig");
const secp256k1_mod = @import("../secp256k1.zig");

const ServerCtx = rpc.ServerCtx;

const Wallet = wallet_mod.Wallet;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const MultisigWallet = multisig_mod.MultisigWallet;

pub fn handleGetBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_addr = rpc.extractArrayStr(body, 0) orelse
                     rpc.extractStr(body, "address") orelse
                     ctx.wallet.address;
    // Lock blockchain mutex — prevents segfault from concurrent hashmap resize
    // during mining (creditBalance → put can realloc while we read).
    // Use getBlockCountUnlocked while we already hold the mutex — calling
    // getBlockCount here would re-lock and panic (non-reentrant Mutex).
    ctx.bc.mutex.lock();
    const bal_sat = ctx.bc.getAddressBalance(req_addr);
    const height  = ctx.bc.getBlockCountUnlocked();
    ctx.bc.mutex.unlock();
    const bal_omni = bal_sat / 1_000_000_000;
    const bal_frac = bal_sat % 1_000_000_000;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":\"{d}.{d:0>9}\",\"confirmed\":{d},\"unconfirmed\":0,\"utxos\":[],\"transactions\":[],\"txCount\":0,\"nodeHeight\":{d}}}}}",
        .{ id, req_addr, bal_sat, bal_omni, bal_frac, bal_sat, height });
}

/// RPC "getwalletsummary" — single-call wallet snapshot for an address.
///
/// Returns one JSON object aggregating everything the user / CLI / SDK / UI
/// needs to display "where IS my money?": on-chain balance, total staked,
/// per-stake breakdown, OMNI locked in active sell orders, derived available,
/// and current block height. Lets a CLI user (no frontend) verify locks
/// without making 4 separate RPC calls.
///
/// Usage:
///   {"method":"getwalletsummary","params":["ob1q..."],"id":1}
///   {"method":"getwalletsummary","params":{"address":"ob1q..."},"id":1}
///
/// Returns: { address, height, wallet_sat, staked_sat, in_orders_sat,
///            available_sat, stakes:[{id, amount_sat, status, ...}],
///            open_sell_orders:[{pair_id, remaining_sat, price_micro_usd}] }
pub fn handleGetWalletSummary(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_addr = rpc.extractArrayStr(body, 0) orelse
                     rpc.extractStr(body, "address") orelse
                     ctx.wallet.address;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    // Single lock over the whole snapshot — guarantees the four numbers
    // (wallet / staked / orders / height) all come from the same chain
    // state. Without this, a mining round between calls could shift them.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const wallet_sat = ctx.bc.getAddressBalance(req_addr);
    const height     = ctx.bc.getBlockCountUnlocked();

    var staked_sat: u64 = 0;
    if (ctx.bc.stake_amounts.get(req_addr)) |amt| {
        staked_sat = amt;
    }

    // Walk active sell orders for this trader to compute in_orders_sat (OMNI
    // reserved by resting sells). Buy orders reserve quote-asset (USDC/etc),
    // not OMNI, so we don't count them here. Same scan pattern as
    // handleExchangeGetUserOrders — kept tolerant of paper mode being off.
    var in_orders_sat: u64 = 0;
    var open_orders_json = std.array_list.Managed(u8).init(alloc);
    defer open_orders_json.deinit();
    const oow = open_orders_json.writer();
    var first_order = true;

    const engine_opt = rpc.pickEngine(ctx, false);
    if (engine_opt) |engine| {
        ctx.exchange_mutex.lock();
        defer ctx.exchange_mutex.unlock();
        inline for (.{ "bids", "asks" }) |which| {
            const count = if (comptime std.mem.eql(u8, which, "bids")) engine.bid_count else engine.ask_count;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const o = if (comptime std.mem.eql(u8, which, "bids")) engine.bids[i] else engine.asks[i];
                if (!std.mem.eql(u8, o.getTraderAddress(), req_addr)) continue;
                const status_active = (o.status == .active) or (o.status == .partial);
                if (!status_active) continue;
                const is_sell = (comptime std.mem.eql(u8, which, "asks"));
                const remaining = o.remainingSat();
                if (is_sell) in_orders_sat += remaining;
                if (!first_order) try oow.writeAll(",");
                first_order = false;
                try oow.print(
                    "{{\"order_id\":{d},\"pair_id\":{d},\"side\":\"{s}\",\"remaining_sat\":{d},\"price_micro_usd\":{d}}}",
                    .{ o.order_id, o.pair_id, if (is_sell) "sell" else "buy", remaining, o.price_micro_usd },
                );
            }
        }
    }

    const reserved_sat: u64 = staked_sat + in_orders_sat;
    const available_sat: u64 = if (wallet_sat > reserved_sat) wallet_sat - reserved_sat else 0;

    const wallet_omni  = wallet_sat / 1_000_000_000;
    const wallet_frac  = wallet_sat % 1_000_000_000;
    const staked_omni  = staked_sat / 1_000_000_000;
    const staked_frac  = staked_sat % 1_000_000_000;
    const avail_omni   = available_sat / 1_000_000_000;
    const avail_frac   = available_sat % 1_000_000_000;
    const orders_omni  = in_orders_sat / 1_000_000_000;
    const orders_frac  = in_orders_sat % 1_000_000_000;

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"height\":{d},\"wallet_sat\":{d},\"wallet_omni\":\"{d}.{d:0>9}\",\"staked_sat\":{d},\"staked_omni\":\"{d}.{d:0>9}\",\"in_orders_sat\":{d},\"in_orders_omni\":\"{d}.{d:0>9}\",\"available_sat\":{d},\"available_omni\":\"{d}.{d:0>9}\",\"stakes\":[",
        .{
            id, req_addr, height,
            wallet_sat,  wallet_omni,  wallet_frac,
            staked_sat,  staked_omni,  staked_frac,
            in_orders_sat, orders_omni, orders_frac,
            available_sat, avail_omni,  avail_frac,
        },
    );

    if (staked_sat > 0) {
        // Real lock metadata from stake_meta (populated by
        // applyOpReturnRoles when "stake:<amt>[:<lock_blocks>]" lands).
        // Legacy stakes from older chain.dat fall back to zeros.
        var started_at: u64 = 0;
        var lock_blk: u64 = 0;
        if (ctx.bc.stake_meta.get(req_addr)) |meta| {
            started_at = meta.started_at_block;
            lock_blk = meta.lock_blocks;
        }
        const days_locked: u64 = lock_blk / 86_400;
        try w.print(
            "{{\"id\":0,\"amount_sat\":{d},\"lock_blocks\":{d},\"started_at_block\":{d},\"days_locked\":{d},\"status\":\"active\"}}",
            .{ staked_sat, lock_blk, started_at, days_locked },
        );
    }

    try w.writeAll("],\"open_sell_orders\":[");
    try w.writeAll(open_orders_json.items);
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

/// RPC "listunspent" — list all unspent transaction outputs (UTXOs) for an address.
///
/// Required by wallets to build wire-v2 transactions with explicit UTXO refs
/// (`inputs[]`/`outputs[]`). Without this, wallets fall back to balance-only wire-v1.
///
/// Walks `bc.utxo_set.address_index` for the given address, then dereferences each
/// outpoint key ("tx_hash:vout") into the `bc.utxo_set.utxos` map.
///
/// Usage:
///   {"method":"listunspent","params":["ob1q..."],"id":1}
///   {"method":"listunspent","params":{"address":"ob1q..."},"id":1}
///
/// Returns: {address, total, count, utxos:[{tx_hash, output_index, amount,
///          block_height, is_coinbase, is_spent:false}]}
pub fn handleListUnspent(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_addr = rpc.extractArrayStr(body, 0) orelse
                     rpc.extractStr(body, "address") orelse
                     return rpc.errorJson(-32602, "address required", id, alloc);

    if (req_addr.len == 0) return rpc.errorJson(-32602, "address must be non-empty", id, alloc);

    // Lock blockchain mutex — UTXO set may be mutated by mining/sync threads.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var json = std.array_list.Managed(u8).init(alloc);
    errdefer json.deinit();
    var w = json.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"utxos\":[",
        .{ id, req_addr },
    );

    var total: u64 = 0;
    var count: usize = 0;

    // Lock UTXOSet for the whole walk — see utxo.zig RwLock note.
    ctx.bc.utxo_set.lock.lockShared();
    defer ctx.bc.utxo_set.lock.unlockShared();

    if (ctx.bc.utxo_set.address_index.get(req_addr)) |list| {
        for (list.items) |outpoint_key| {
            const utxo = ctx.bc.utxo_set.utxos.get(outpoint_key) orelse continue;
            if (count > 0) try w.writeAll(",");
            try w.print(
                "{{\"tx_hash\":\"{s}\",\"output_index\":{d},\"amount\":{d}," ++
                "\"block_height\":{d},\"is_coinbase\":{},\"is_spent\":false}}",
                .{ utxo.tx_hash, utxo.output_index, utxo.amount, utxo.block_height, utxo.is_coinbase },
            );
            total += utxo.amount;
            count += 1;
        }
    }

    try w.print("],\"total\":{d},\"count\":{d}}}}}", .{ total, count });
    return json.toOwnedSlice();
}

// SEGFAULT-FIX [scan-2026-04-25]: use getLatestBlockSnapshot() — locks bc.mutex,
// copies fields into stable buffers, unlocks. allocPrint runs after the lock is
// released, on data that no longer aliases chain memory. Eliminates UAF on
// blk.hash / blk.previous_hash / blk.transactions.items when mining concurrently
// reallocs/swaps the chain.
pub fn handleGetStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"running\",\"blockCount\":{d},\"mempoolSize\":{d},\"address\":\"{s}\",\"balance\":{d}}}}}",
        .{ id, ctx.bc.getBlockCount(), ctx.bc.mempool.items.len, ctx.wallet.address, ctx.wallet.getBalance() });
}

/// RPC "getnonce" — returns the next expected nonce for an address.
/// Considers both confirmed chain nonces and pending mempool TXs.
/// Usage: {"method":"getnonce","params":["ob1qcx2p306xpf3c2gd6h4074kpux4tv2hnmx3ytuq"],"id":1}
/// Response: {"result":{"address":"...","nonce":N,"chainNonce":M,"pendingCount":P}}
pub fn handleGetNonce(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    ctx.bc.mutex.lock();
    const chain_nonce = ctx.bc.getNextNonce(addr);
    const next_available = ctx.bc.getNextAvailableNonce(addr);
    ctx.bc.mutex.unlock();
    const pending = next_available - chain_nonce;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nonce\":{d},\"chainNonce\":{d},\"pendingCount\":{d}}}}}",
        .{ id, addr, next_available, chain_nonce, pending });
}

/// RPC "gettransaction" — returns a single TX by hash with confirmation count.
/// Searches mempool (pending, 0 confirmations) then mined blocks (confirmed).
/// Usage: {"method":"gettransaction","params":["tx_hash_hex"],"id":1}
pub fn handleGetTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tx_hash = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "txid") orelse
        return rpc.errorJson(-32602, "Missing param: txid", id, alloc);

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // 1. Check mempool (pending TXs — 0 confirmations)
    for (ctx.bc.mempool.items) |tx| {
        if (std.mem.eql(u8, tx.hash, tx_hash)) {
            const scheme_label = rpc.txSchemeLabel(tx.scheme);
            const op_ret = try rpc.jsonSanitize(alloc, if (tx.op_return.len > 0) tx.op_return else "");
            defer alloc.free(op_ret);
            const kind = rpc.inferTxKind(tx);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"nonce\":{d},\"timestamp\":{d},\"scheme\":\"{s}\",\"kind\":\"{s}\",\"op_return\":\"{s}\",\"confirmations\":0,\"blockHeight\":null,\"status\":\"pending\"}}}}",
                .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce, tx.timestamp, scheme_label, kind, op_ret });
        }
    }

    // 2. Check mined blocks via tx_block_height index
    if (ctx.bc.tx_block_height.get(tx_hash)) |block_height| {
        const confirmations = ctx.bc.getConfirmations(tx_hash) orelse 0;
        // Find the actual TX data in the block
        if (block_height < ctx.bc.chain.items.len) {
            const blk = ctx.bc.chain.items[block_height];
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, tx_hash)) {
                    const scheme_label = rpc.txSchemeLabel(tx.scheme);
                    const op_ret = try rpc.jsonSanitize(alloc, if (tx.op_return.len > 0) tx.op_return else "");
                    defer alloc.free(op_ret);
                    const kind = rpc.inferTxKind(tx);
                    return std.fmt.allocPrint(alloc,
                        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"nonce\":{d},\"timestamp\":{d},\"scheme\":\"{s}\",\"kind\":\"{s}\",\"op_return\":\"{s}\",\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
                        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce, tx.timestamp, scheme_label, kind, op_ret, confirmations, block_height });
                }
            }
        }
        // TX in index but not found in block (edge case) — return minimal info
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
            .{ id, tx_hash, confirmations, block_height });
    }

    // 3. Fallback: linear scan all blocks (for TXs not in index, e.g. restored from disk)
    for (ctx.bc.chain.items) |blk| {
        for (blk.transactions.items) |tx| {
            if (std.mem.eql(u8, tx.hash, tx_hash)) {
                const current_height: u64 = @intCast(ctx.bc.chain.items.len);
                const bh: u64 = @intCast(blk.index);
                const confirmations = if (current_height > bh) current_height - bh else 0;
                const scheme_label = rpc.txSchemeLabel(tx.scheme);
                const op_ret = try rpc.jsonSanitize(alloc, if (tx.op_return.len > 0) tx.op_return else "");
                defer alloc.free(op_ret);
                const kind = rpc.inferTxKind(tx);
                return std.fmt.allocPrint(alloc,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"nonce\":{d},\"timestamp\":{d},\"scheme\":\"{s}\",\"kind\":\"{s}\",\"op_return\":\"{s}\",\"confirmations\":{d},\"blockHeight\":{d},\"status\":\"confirmed\"}}}}",
                    .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce, tx.timestamp, scheme_label, kind, op_ret, confirmations, blk.index });
            }
        }
    }

    return rpc.errorJson(-32602, "Transaction not found", id, alloc);
}

pub fn handleSendTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const to_addr = rpc.extractStr(body, "to") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: to", id, alloc);
    const amount_sat = rpc.extractArrayNum(body, 1);
    if (amount_sat == 0) return rpc.errorJson(-32602, "Missing param: amount", id, alloc);
    // Optional fee param (3rd array element or "fee" field); default TX_MIN_FEE_SAT (1 SAT)
    const fee_raw = rpc.extractArrayNum(body, 2);
    const fee_from_str = if (rpc.extractStr(body, "fee")) |fs| std.fmt.parseInt(u64, fs, 10) catch @as(u64, 0) else @as(u64, 0);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else if (fee_from_str > 0) fee_from_str else mempool_mod.TX_MIN_FEE_SAT;
    // Optional locktime param (4th array element or "locktime" field); default 0 (immediate)
    const lt_raw = rpc.extractArrayNum(body, 3);
    const lt_from_str = if (rpc.extractStr(body, "locktime")) |ls| std.fmt.parseInt(u64, ls, 10) catch @as(u64, 0) else @as(u64, 0);
    const locktime: u64 = if (lt_raw > 0) lt_raw else lt_from_str;
    // Optional op_return param ("op_return" or "opreturn" field)
    const op_return = rpc.extractStr(body, "op_return") orelse rpc.extractStr(body, "opreturn") orelse "";
    // Optional script param: "p2pkh" = auto-generate P2PKH scripts, "none"/empty = legacy mode
    const script_type = rpc.extractStr(body, "script") orelse "";
    const tx_id = rpc.g_tx_counter.fetchAdd(1, .monotonic);
    // Nonce = next available (chain nonce + pending mempool TXs from this sender)
    const nonce = ctx.bc.getNextAvailableNonce(ctx.wallet.address);

    // If script type is "p2pkh" and we know the receiver's pubkey, use P2PKH scripts
    if (std.mem.eql(u8, script_type, "p2pkh")) {
        // Look up receiver's pubkey from registry
        if (ctx.bc.pubkey_registry.get(to_addr)) |receiver_pk_hex| {
            if (receiver_pk_hex.len == 66) {
                var receiver_pk: [33]u8 = undefined;
                hex_utils.hexToBytes(receiver_pk_hex, &receiver_pk) catch
                    return rpc.errorJson(-32000, "Invalid receiver pubkey in registry", id, alloc);
                var tx = ctx.wallet.createTransactionP2PKH(
                    to_addr, amount_sat, tx_id, nonce, fee_sat, locktime, op_return,
                    receiver_pk, alloc,
                ) catch return rpc.errorJson(-32000, "Sign error (P2PKH)", id, alloc);
                if (!tx.isValid()) return rpc.errorJson(-32000, "Invalid transaction", id, alloc);
                ctx.bc.registerPubkey(ctx.wallet.address, ctx.wallet.addresses[0].public_key_hex) catch {};
                ctx.bc.addTransaction(tx) catch return rpc.errorJson(-32000, "Mempool error", id, alloc);
                return std.fmt.allocPrint(alloc,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"script\":\"p2pkh\",\"status\":\"accepted\"}}}}",
                    .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime });
            }
        }
        // Receiver pubkey not known — fall through to legacy mode
    }

    var tx = ctx.wallet.createTransactionFull(to_addr, amount_sat, tx_id, nonce, fee_sat, locktime, op_return, alloc) catch
        return rpc.errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return rpc.errorJson(-32000, "Invalid transaction", id, alloc);
    // Inregistreaza pubkey-ul wallet-ului in blockchain (pentru verificare semnatura)
    ctx.bc.registerPubkey(ctx.wallet.address, ctx.wallet.addresses[0].public_key_hex) catch {};
    ctx.bc.addTransaction(tx) catch return rpc.errorJson(-32000, "Mempool error", id, alloc);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime });
}

/// RPC "sendopreturn" — create OP_RETURN TX with embedded data and amount=0.
/// Usage: {"method":"sendopreturn","params":["data_string", fee_sat],"id":1}
/// Or:    {"method":"sendopreturn","params":{"data":"data_string","fee":100},"id":1}
pub fn handleSendOpReturn(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const data = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "data") orelse
        return rpc.errorJson(-32602, "Missing param: data (OP_RETURN payload)", id, alloc);
    if (data.len == 0) return rpc.errorJson(-32602, "OP_RETURN data cannot be empty", id, alloc);
    if (data.len > transaction_mod.Transaction.MAX_OP_RETURN)
        return rpc.errorJson(-32602, "OP_RETURN data exceeds 80 bytes", id, alloc);

    const fee_raw = rpc.extractArrayNum(body, 1);
    const fee_from_str = if (rpc.extractStr(body, "fee")) |fs| std.fmt.parseInt(u64, fs, 10) catch @as(u64, 0) else @as(u64, 0);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else if (fee_from_str > 0) fee_from_str else mempool_mod.TX_MIN_FEE_SAT;

    const tx_id = rpc.g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(ctx.wallet.address);
    // OP_RETURN TX: amount=0, to=self (data carrier, not a payment)
    var tx = ctx.wallet.createTransactionFull(ctx.wallet.address, 0, tx_id, nonce, fee_sat, 0, data, alloc) catch
        return rpc.errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return rpc.errorJson(-32000, "Invalid OP_RETURN transaction", id, alloc);
    ctx.bc.registerPubkey(ctx.wallet.address, ctx.wallet.addresses[0].public_key_hex) catch {};
    ctx.bc.addTransaction(tx) catch return rpc.errorJson(-32000, "Mempool error", id, alloc);
    {
        const opr_safe = try rpc.jsonSanitize(alloc, tx.op_return);
        defer alloc.free(opr_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"op_return\":\"{s}\",\"fee\":{d},\"status\":\"accepted\"}}}}",
            .{ id, tx.hash, tx.from_address, opr_safe, tx.fee });
    }
}

/// RPC "claimfaucet"
/// { "address": "ob1q...", "declaration_hash": "<sha256-64>",
///   "signature": "hex", "public_key": "hex", "nonce": N }
///
/// The client MUST:
///   1. Read faucet_mod.DECLARATION_TEXT
///   2. Compute SHA-256(DECLARATION_TEXT) → declaration_hash
///   3. Sign the TX hash with their private key
///   4. Submit this request
///
/// On success: TX is queued in mempool, 0.001 OMNI arrives after next block.
pub fn handleClaimFaucet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    rpc.ensureFaucetState(alloc);

    const recipient = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    if (recipient.len < 8 or recipient.len > 64)
        return rpc.errorJson(-32602, "Invalid address length", id, alloc);

    const decl_hash = rpc.extractStr(body, "declaration_hash") orelse
        return rpc.errorJson(-32602, "Missing param: declaration_hash — read the Declaration of Honesty", id, alloc);
    if (decl_hash.len != 64)
        return rpc.errorJson(-32602, "declaration_hash must be 64-char SHA-256 hex", id, alloc);

    // Verify the client hashed the correct declaration text.
    if (!std.mem.eql(u8, decl_hash, faucet_mod.DECLARATION_HASH))
        return rpc.errorJson(-32015,
            "declaration_hash mismatch — you must hash the exact OmniBus Declaration of Honesty v1",
            id, alloc);

    const sig    = rpc.extractStr(body, "signature")  orelse return rpc.errorJson(-32602, "Missing: signature",  id, alloc);
    const pubkey = rpc.extractStr(body, "public_key") orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce  = rpc.extractParamObjectU64(body, "nonce");

    // One-time per address.
    if (!g_faucet_addr_set.tryRecord(recipient)) {
        // Also check on-chain: if address already has balance it claimed before.
        const existing_bal = ctx.bc.getAddressBalance(recipient);
        if (existing_bal > 0 or g_faucet_addr_set.hasClaimed(recipient))
            return rpc.errorJson(-32011, "Address already received faucet funds", id, alloc);
    }

    // IP cooldown (best-effort — peer IP not available in all call paths,
    // skip enforcement when empty).
    const peer_ip = rpc.extractStr(body, "_peer_ip") orelse "";
    if (peer_ip.len > 0) {
        const now_s = std.time.timestamp();
        if (!g_faucet_ip_map.tryRecord(peer_ip, now_s)) {
            const last = g_faucet_ip_map.lastClaim(peer_ip);
            const wait = faucet_mod.FAUCET_COOLDOWN_S - (now_s - last);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32016,\"message\":\"IP cooldown: wait {d}s before claiming again\"}}}}",
                .{ id, wait });
        }
    }

    // Check faucet balance.
    const faucet_bal = ctx.bc.getAddressBalance(faucet_mod.FAUCET_ADDR);
    const fee_sat: u64 = 1_000;
    if (faucet_bal < faucet_mod.FAUCET_AMOUNT_SAT + fee_sat)
        return rpc.errorJson(-32012, "Faucet drained — community refill needed", id, alloc);

    // Build op_return: "faucet_claim:<decl_hash>:<recipient>"
    const op_return = try std.fmt.allocPrint(alloc,
        "faucet_claim:{s}:{s}", .{ decl_hash, recipient });
    defer alloc.free(op_return);

    const ts    = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    const provisional = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, faucet_mod.FAUCET_ADDR, ts });
    defer alloc.free(provisional);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = faucet_mod.FAUCET_ADDR,
        .to_address   = recipient,
        .amount       = faucet_mod.FAUCET_AMOUNT_SAT,
        .fee          = fee_sat,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = provisional,
    };
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32014, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    std.debug.print("[FAUCET] Onboarding {d} SAT → {s} (decl_hash={s})\n",
        .{ faucet_mod.FAUCET_AMOUNT_SAT, recipient[0..@min(recipient.len, 20)], decl_hash[0..8] });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"txid\":\"{s}\"," ++
        "\"recipient\":\"{s}\"," ++
        "\"amount\":{d}," ++
        "\"declaration\":\"signed\"," ++
        "\"status\":\"accepted\"," ++
        "\"message\":\"Welcome to OmniBus. Now complete pq_attest to unlock full access.\"" ++
        "}}}}",
        .{ id, canonical, recipient, faucet_mod.FAUCET_AMOUNT_SAT });
}

/// RPC "getfaucetstatus"
pub fn handleFaucetStatus(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const faucet_bal = ctx.bc.getAddressBalance(faucet_mod.FAUCET_ADDR);
    const enabled = faucet_bal >= faucet_mod.FAUCET_AMOUNT_SAT;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"enabled\":{}," ++
        "\"address\":\"{s}\"," ++
        "\"balance\":{d}," ++
        "\"grantPerClaim\":{d}," ++
        "\"cooldownHours\":24," ++
        "\"declaration_hash\":\"{s}\"," ++
        "\"declaration_text\":\"{s}\"" ++
        "}}}}",
        .{ id, enabled,
           faucet_mod.FAUCET_ADDR,
           faucet_bal,
           faucet_mod.FAUCET_AMOUNT_SAT,
           faucet_mod.DECLARATION_HASH,
           faucet_mod.DECLARATION_TEXT });
}

// ─── Faucet in-memory state (kept module-local to this file) ────────────────
//
// The original rpc_server.zig has its own copy used by its dispatcher. We
// keep a parallel copy here so the extracted handlers compile in isolation;
// when both files are linked, each owns its own counter set. The chain
// state (TX history) is authoritative — these are anti-spam helpers only.

var g_faucet_addr_set = faucet_mod.ClaimedSet{
    .set   = @as(@TypeOf(faucet_mod.ClaimedSet.init(undefined).set), undefined),
    .mutex = .{},
};
var g_faucet_ip_map = faucet_mod.IpCooldownMap{
    .map   = @as(@TypeOf(faucet_mod.IpCooldownMap.init(undefined).map), undefined),
    .mutex = .{},
};
var g_faucet_state_init = false;
var g_faucet_state_mutex: std.Thread.Mutex = .{};

fn ensureFaucetState(alloc: std.mem.Allocator) void {
    g_faucet_state_mutex.lock();
    defer g_faucet_state_mutex.unlock();
    if (g_faucet_state_init) return;
    g_faucet_addr_set  = faucet_mod.ClaimedSet.init(alloc);
    g_faucet_ip_map    = faucet_mod.IpCooldownMap.init(alloc);
    g_faucet_state_init = true;
}

// ─── Rich list — local helper struct ────────────────────────────────────────

const RichEntry = struct {
    address: []const u8,
    balance: u64,
    tx_count: u32 = 0,
    received: u64 = 0,
    sent: u64 = 0,
    first_height: u64 = 0,
    last_height: u64 = 0,
    first_seen_set: bool = false,
};

/// RPC "getrichlist" — Bitcoin-style address list sorted by balance desc.
///
/// Walks `bc.utxo_set` address index, filters out zero-balance entries (cosmetic
/// — keeps the output small), sorts descending, and emits the top N.
///
/// Each entry includes:
///   - address (ob1q…)
///   - balance in SAT
///   - is_validator (balance ≥ MIN_VALIDATOR_BALANCE)
///   - blocks_mined (count of blocks where block.miner == this address)
///
/// Usage:
///   {"method":"getrichlist","params":[100],"id":1}   // top 100
///   {"method":"getrichlist","params":[],"id":1}      // top 100 default
pub fn handleRichList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const limit_raw = rpc.extractArrayNum(body, 0);
    const limit: usize = if (limit_raw > 0) @min(@as(usize, @intCast(limit_raw)), 1000) else 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Collect (address, balance) pairs from the UTXO set (PHASE-B source of truth).
    var entries = std.array_list.Managed(rpc.RichEntry).init(alloc);
    defer entries.deinit();
    // Lock UTXOSet for the iteration — getBalance() takes a recursive shared lock.
    ctx.bc.utxo_set.lock.lockShared();
    defer ctx.bc.utxo_set.lock.unlockShared();
    var ait = ctx.bc.utxo_set.address_index.iterator();
    while (ait.next()) |kv| {
        const addr = kv.key_ptr.*;
        // Inline tally to avoid re-locking (getBalance would try to lockShared again).
        const list = kv.value_ptr.*;
        var bal: u64 = 0;
        for (list.items) |op| {
            if (ctx.bc.utxo_set.utxos.get(op)) |u| bal += u.amount;
        }
        if (bal == 0) continue; // skip dust/zero balances
        try entries.append(.{ .address = addr, .balance = bal });
    }

    // Sort by balance descending; tie-break by address string for determinism.
    std.mem.sort(rpc.RichEntry, entries.items, {}, struct {
        fn lt(_: void, a: rpc.RichEntry, b: rpc.RichEntry) bool {
            if (a.balance != b.balance) return a.balance > b.balance;
            return std.mem.lessThan(u8, a.address, b.address);
        }
    }.lt);

    // Build per-address indexes:
    //   - mined_count: blocks mined by miner_address (=> MINER role) — one
    //                  pass over chain (block headers only, always available).
    //   - stake_amount / is_agent: now read directly from the persisted
    //     bc.stake_amounts / bc.registered_agents maps so roles survive a
    //     node restart (chain.dat doesn't serialise full TX list — see
    //     database.zig stake_state / agent_state sections, 2026-05-04).
    //   - tx_stats: {count, received, sent, first_height, last_height}
    //               — still computed by iterating in-memory blocks. After a
    //               restart this is empty until new blocks land; treat as
    //               cosmetic, while role classification stays correct.
    var mined_count = std.StringHashMap(u32).init(alloc);
    defer mined_count.deinit();

    const TxStats = struct {
        count: u32 = 0,
        received: u64 = 0,
        sent: u64 = 0,
        first_height: u64 = 0,
        last_height: u64 = 0,
        first_seen: bool = false,
    };
    var tx_stats = std.StringHashMap(TxStats).init(alloc);
    defer tx_stats.deinit();

    for (ctx.bc.chain.items, 0..) |blk, height| {
        if (blk.miner_address.len > 0) {
            const gop = try mined_count.getOrPut(blk.miner_address);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        for (blk.transactions.items) |tx| {
            const h: u64 = @intCast(height);
            // Sender side (skip coinbase — empty from)
            if (tx.from_address.len > 0) {
                const gop = try tx_stats.getOrPut(tx.from_address);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.count += 1;
                gop.value_ptr.sent += tx.amount;
                if (!gop.value_ptr.first_seen) {
                    gop.value_ptr.first_height = h;
                    gop.value_ptr.first_seen = true;
                }
                gop.value_ptr.last_height = h;
            }
            // Receiver side
            if (tx.to_address.len > 0) {
                const gop = try tx_stats.getOrPut(tx.to_address);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.count += 1;
                gop.value_ptr.received += tx.amount;
                if (!gop.value_ptr.first_seen) {
                    gop.value_ptr.first_height = h;
                    gop.value_ptr.first_seen = true;
                }
                gop.value_ptr.last_height = h;
            }
        }
    }

    // Emit JSON: {result: {entries:[…], total:N, totalSupply:N}}
    var json = std.array_list.Managed(u8).init(alloc);
    errdefer json.deinit();
    var w = json.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"entries\":[", .{id});

    var total_supply: u64 = 0;
    for (entries.items) |e| total_supply += e.balance;

    const out_count = @min(limit, entries.items.len);
    for (entries.items[0..out_count], 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        const blocks = mined_count.get(e.address) orelse 0;
        // Restart-safe: read stake/agent state from persisted maps in
        // bc, populated by applyOpReturnRoles + restored from chain.dat.
        const stake = ctx.bc.stake_amounts.get(e.address) orelse 0;
        const agent = ctx.bc.registered_agents.contains(e.address);
        const stats = tx_stats.get(e.address) orelse TxStats{};

        // 4-role classification (multi-role: address can be VALIDATOR + MINER + AGENT etc.)
        const is_validator = stake >= staking_mod.VALIDATOR_MIN_STAKE;
        const is_miner = blocks > 0;
        // USER role implicit — included if no other role is active.
        const is_user = !is_validator and !is_miner and !agent;

        // Build roles JSON array
        try w.print(
            "{{\"rank\":{d},\"address\":\"{s}\",\"balance\":{d}," ++
            "\"roles\":[",
            .{ i + 1, e.address, e.balance },
        );
        var role_first = true;
        if (is_validator) { try w.writeAll("\"validator\""); role_first = false; }
        if (is_miner)     { if (!role_first) try w.writeAll(","); try w.writeAll("\"miner\""); role_first = false; }
        if (agent)        { if (!role_first) try w.writeAll(","); try w.writeAll("\"agent\""); role_first = false; }
        if (is_user)      { try w.writeAll("\"user\""); }
        try w.print(
            "],\"stake\":{d},\"blocksMined\":{d}," ++
            // Backward-compat: keep isValidator boolean (true if validator role active)
            "\"isValidator\":{}," ++
            "\"txCount\":{d},\"received\":{d},\"sent\":{d},\"firstHeight\":{d},\"lastHeight\":{d}}}",
            .{ stake, blocks, is_validator,
               stats.count, stats.received, stats.sent, stats.first_height, stats.last_height },
        );
    }

    try w.print("],\"total\":{d},\"shown\":{d},\"totalSupply\":{d}}}}}", .{
        entries.items.len, out_count, total_supply,
    });

    return json.toOwnedSlice();
}

/// RPC "getschemestats" — signing-scheme distribution across last N blocks.
/// Params: [blocks_count]  (default 100, max 1000)
/// Returns: { totalTxs, blocks, schemes: [{scheme, count, pct}] }
pub fn handleSchemeStats(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const req_blocks = rpc.extractArrayNum(body, 0);
    const scan: u64 = if (req_blocks > 0 and req_blocks <= 1000) req_blocks else 100;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const chain_len: u64 = @intCast(ctx.bc.chain.items.len);
    const start: u64 = if (chain_len > scan) chain_len - scan else 0;

    // Counters for 13 schemes (indices match transaction.Scheme enum order)
    var counts: [13]u64 = .{0} ** 13;
    var total: u64 = 0;

    var hi: u64 = start;
    while (hi < chain_len) : (hi += 1) {
        const blk = ctx.bc.chain.items[@intCast(hi)];
        for (blk.transactions.items) |tx| {
            const idx: usize = @intFromEnum(tx.scheme);
            if (idx < 13) counts[idx] += 1;
            total += 1;
        }
    }

    const scanned = chain_len - start;
    const scheme_labels = [13][]const u8{
        "ECDSA (secp256k1)",
        "ML-DSA-87 (LOVE soulbound)",
        "Falcon-512 (FOOD soulbound)",
        "ML-DSA-87 (RENT soulbound)",
        "SLH-DSA-256s (VACATION soulbound)",
        "ML-DSA-87",
        "Falcon-512",
        "ML-DSA-87 (Dilithium-5)",
        "SLH-DSA-256s",
        "Hybrid ECDSA+ML-DSA-87",
        "Hybrid ECDSA+Falcon-512",
        "Hybrid ECDSA+Dilithium-5",
        "Hybrid ECDSA+SLH-DSA",
    };

    var entries: []u8 = try alloc.dupe(u8, "");
    var written: usize = 0;
    for (scheme_labels, 0..) |label, i| {
        if (counts[i] == 0) continue;
        const pct_x100: u64 = if (total > 0) counts[i] * 10000 / total else 0;
        const sep: []const u8 = if (written == 0) "" else ",";
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"scheme\":\"{s}\",\"count\":{d},\"pct\":{d}}}",
            .{ sep, label, counts[i], pct_x100 });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
        written += 1;
    }
    defer alloc.free(entries);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"totalTxs\":{d},\"blocks\":{d},\"schemes\":[{s}]}}}}",
        .{ id, total, scanned, entries });
}

// ─── sendrawtransaction — submit a CLIENT-SIGNED OmniBus transaction ────────
//
// Use case: a script (or UI) holds private keys for N wallets, wants to send
// from any of them. The existing `sendtransaction` always signs with the
// node's primary wallet — single-sender. `sendrawtransaction` accepts a
// fully-formed signed TX as JSON params and just validates + adds to mempool.
//
// Format expected (single param object OR positional first param):
//   {
//     "id": <u32>,
//     "from": "ob1q...",
//     "to":   "ob1q...",
//     "amount": <SAT u64>,
//     "fee":  <SAT u64>,
//     "timestamp": <unix seconds i64>,
//     "nonce": <u64>,
//     "publicKey": "<66 hex>",          // sender pubkey (registered before validate)
//     "signature": "<128 hex>",         // ECDSA(R||S) over calculateHash()
//     "hash":      "<64 hex>",          // SHA256d of canonical fields
//     "opReturn":  "<optional string>", // ≤ 80 bytes
//     "locktime":  <optional u64>
//   }
//
// Hash format mirrors `Transaction.calculateHash` in transaction.zig — caller
// must build the exact same byte sequence and double-SHA256 it. Signature
// is ECDSA secp256k1 over the resulting 32-byte digest.
//
// Returns {txid, status:"accepted"} on success or an RPC error otherwise.
pub fn handleSendRawTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // Required string fields
    const from_addr = rpc.extractStr(body, "from") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: from", id, alloc);
    const to_addr = rpc.extractStr(body, "to") orelse
        return rpc.errorJson(-32602, "Missing param: to", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature (128 hex chars)", id, alloc);
    const hash_hex = rpc.extractStr(body, "hash") orelse
        return rpc.errorJson(-32602, "Missing param: hash (64 hex chars)", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);

    // Required numeric fields
    const amount = rpc.extractArrayNumByKey(body, "amount");
    if (amount == 0) return rpc.errorJson(-32602, "Missing or zero: amount", id, alloc);
    const fee = rpc.extractArrayNumByKey(body, "fee");
    const fee_sat: u64 = if (fee > 0) fee else mempool_mod.TX_MIN_FEE_SAT;
    const ts_raw = rpc.extractArrayNumByKey(body, "timestamp");
    const ts: i64 = if (ts_raw > 0) @intCast(ts_raw) else std.time.timestamp();
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    const tx_id_raw = rpc.extractArrayNumByKey(body, "id");
    const tx_id: u32 = if (tx_id_raw > 0) @intCast(@min(tx_id_raw, std.math.maxInt(u32))) else rpc.g_tx_counter.fetchAdd(1, .monotonic);
    const locktime = rpc.extractArrayNumByKey(body, "locktime");
    const op_return = rpc.extractStr(body, "opReturn") orelse rpc.extractStr(body, "op_return") orelse "";

    // Auto-detect scheme from sender address prefix. ECDSA expects fixed
    // 128-char signature + 66-char pubkey; PQ schemes carry much larger
    // signatures (Falcon ~700 bytes, ML-DSA ~3-4 KB, SLH-DSA-256s ~30 KB)
    // so we skip the length check for non-ECDSA schemes — the verifier
    // does the real validation per-scheme.
    const scheme_opt = isolated_wallet_mod.Scheme.fromAddress(from_addr);
    const scheme: isolated_wallet_mod.Scheme = scheme_opt orelse .omni_ecdsa;

    // Field-length sanity for the legacy ECDSA path. PQ paths skip this.
    if (scheme == .omni_ecdsa) {
        if (sig_hex.len != 128) return rpc.errorJson(-32602, "signature must be 128 hex chars (ECDSA)", id, alloc);
        if (hash_hex.len != 64) return rpc.errorJson(-32602, "hash must be 64 hex chars", id, alloc);
        if (pubkey_hex.len != 66) return rpc.errorJson(-32602, "publicKey must be 66 hex chars (compressed secp256k1)", id, alloc);
    } else {
        // PQ TX: hash is still 32 bytes (sha256 output, 64 hex). signature
        // and pubkey lengths vary per scheme — verifier checks them.
        if (hash_hex.len != 64) return rpc.errorJson(-32602, "hash must be 64 hex chars", id, alloc);
        if (sig_hex.len < 100) return rpc.errorJson(-32602, "PQ signature too short", id, alloc);
        if (pubkey_hex.len < 100) return rpc.errorJson(-32602, "PQ public key too short", id, alloc);
    }

    // Allocate owned copies so the Transaction struct outlives the request body.
    const from_owned = try alloc.dupe(u8, from_addr);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, to_addr);
    errdefer alloc.free(to_owned);
    const sig_owned = try alloc.dupe(u8, sig_hex);
    errdefer alloc.free(sig_owned);
    const hash_owned = try alloc.dupe(u8, hash_hex);
    errdefer alloc.free(hash_owned);
    const op_owned: []const u8 = if (op_return.len > 0) try alloc.dupe(u8, op_return) else "";
    errdefer if (op_return.len > 0) alloc.free(op_owned);

    // For PQ TXs, the public_key field on the Transaction struct is the
    // raw PQ pubkey BYTES (not hex). Decode here. ECDSA TXs leave it empty
    // and use the chain pubkey registry instead.
    var pq_pubkey_owned: []const u8 = "";
    if (scheme != .omni_ecdsa) {
        const pq_buf = try alloc.alloc(u8, pubkey_hex.len / 2);
        errdefer alloc.free(pq_buf);
        _ = hex_utils.hexToBytes(pubkey_hex, pq_buf) catch {
            alloc.free(pq_buf);
            return rpc.errorJson(-32602, "publicKey must be valid hex", id, alloc);
        };
        pq_pubkey_owned = pq_buf;
    }

    var tx = transaction_mod.Transaction{
        .id           = tx_id,
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = amount,
        .fee          = fee_sat,
        .timestamp    = ts,
        .nonce        = nonce,
        .locktime     = locktime,
        .op_return    = op_owned,
        .signature    = sig_owned,
        .hash         = hash_owned,
        .scheme       = @as(transaction_mod.Scheme, @enumFromInt(@intFromEnum(scheme))),
        .public_key   = pq_pubkey_owned,
    };

    if (!tx.isValid()) return rpc.errorJson(-32000, "Transaction failed isValid (bad addresses or amount)", id, alloc);

    // Register sender pubkey BEFORE validating — addTransaction's signature
    // check looks the pubkey up by address. Without this, fresh senders
    // would always fail validation on their first TX.
    ctx.bc.registerPubkey(from_owned, pubkey_hex) catch {};

    ctx.bc.addTransaction(tx) catch |err| {
        // The `errdefer alloc.free(...)` chain above doesn't fire here because
        // addTransaction took ownership (or didn't) depending on where it
        // failed. We err on the side of leaking a few bytes per rejected TX
        // rather than risk a double-free.
        const msg = switch (err) {
            error.OutOfMemory => "Out of memory",
            else              => "Mempool refused TX",
        };
        std.debug.print("[RAW-TX] addTransaction error: {} (from={s})\n",
            .{ err, from_owned[0..@min(from_owned.len, 16)] });
        return rpc.errorJson(-32000, msg, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"status\":\"accepted\"}}}}",
        .{ id, hash_owned, from_owned, to_owned, amount, fee_sat });
}

pub fn handleMinerSendTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    const from_addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "from") orelse
        return rpc.errorJson(-32602, "Missing param: from (miner address)", id, alloc);
    const to_addr = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "to") orelse
        return rpc.errorJson(-32602, "Missing param: to (recipient address)", id, alloc);
    const amount_sat = rpc.extractArrayNum(body, 2);
    if (amount_sat == 0) return rpc.errorJson(-32602, "Missing/zero param: amount", id, alloc);
    const fee_raw = rpc.extractArrayNum(body, 3);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else mempool_mod.TX_MIN_FEE_SAT;

    // Look up the miner's wallet in the pool
    const mw = main_mod.g_miner_pool.findByAddress(from_addr) orelse
        return rpc.errorJson(-32602, "Miner not found in wallet pool", id, alloc);

    // Check balance
    const sender_bal = ctx.bc.getAddressBalance(from_addr);
    if (sender_bal < amount_sat + fee_sat) {
        return rpc.errorJson(-32000, "Insufficient balance", id, alloc);
    }

    // Create and sign TX using miner's private key
    const tx_id = rpc.g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(from_addr);
    var tx = mw.createSignedTx(to_addr, amount_sat, tx_id, nonce, fee_sat, alloc) catch
        return rpc.errorJson(-32000, "Sign error", id, alloc);
    if (!tx.isValid()) return rpc.errorJson(-32000, "Invalid transaction", id, alloc);

    // Ensure pubkey is registered for signature verification
    ctx.bc.registerPubkey(from_addr, mw.getPubkeyHex()) catch {};

    // Add to mempool/blockchain
    ctx.bc.addTransaction(tx) catch
        return rpc.errorJson(-32000, "Mempool rejected TX", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"status\":\"accepted\"}}}}",
        .{ id, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee });
}

/// RPC "getaddresshistory" — returns all TXs (sent + received) for an address.
/// Uses address_tx_index for confirmed TXs, scans mempool for pending.
/// Usage: {"method":"getaddresshistory","params":["ob1qcx2p306xpf3c2gd6h4074kpux4tv2hnmx3ytuq"],"id":1}
pub fn handleGetAddrHistory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    var total_received: u64 = 0;
    var total_sent: u64 = 0;
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // 1. Pending TXs from mempool (0 confirmations)
    for (ctx.bc.mempool.items) |tx| {
        const is_from = std.mem.eql(u8, tx.from_address, addr);
        const is_to = std.mem.eql(u8, tx.to_address, addr);
        if (!is_from and !is_to) continue;
        const dir: []const u8 = if (is_from) "sent" else "received";
        if (is_from) total_sent += tx.amount else total_received += tx.amount;
        const kind = rpc.inferTxKind(tx);
        const sep: []const u8 = if (count == 0) "" else ",";
        const memo = try rpc.jsonSanitize(alloc, if (tx.op_return.len > 0) tx.op_return else "");
        defer alloc.free(memo);
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"kind\":\"{s}\",\"scheme\":\"{s}\",\"nonce\":{d},\"timestamp\":{d},\"status\":\"pending\",\"memo\":\"{s}\"}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir, kind, rpc.txSchemeLabel(tx.scheme), tx.nonce, tx.timestamp, memo });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }

    // 2. Confirmed TXs via address_tx_index (fast lookup)
    if (ctx.bc.getAddressHistory(addr)) |tx_hashes| {
        for (tx_hashes) |tx_hash| {
            const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse continue;
            if (block_height >= ctx.bc.chain.items.len) continue;
            const blk = ctx.bc.chain.items[block_height];
            const confirmations = if (current_height > block_height) current_height - block_height else 0;
            for (blk.transactions.items) |tx| {
                if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                const is_from = std.mem.eql(u8, tx.from_address, addr);
                const dir: []const u8 = if (is_from) "sent" else "received";
                if (is_from) total_sent += tx.amount else total_received += tx.amount;
                const kind = rpc.inferTxKind(tx);
                const sep: []const u8 = if (count == 0) "" else ",";
                const memo2 = try rpc.jsonSanitize(alloc, if (tx.op_return.len > 0) tx.op_return else "");
                defer alloc.free(memo2);
                const e = try std.fmt.allocPrint(alloc,
                    "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"direction\":\"{s}\",\"kind\":\"{s}\",\"scheme\":\"{s}\",\"nonce\":{d},\"timestamp\":{d},\"status\":\"confirmed\",\"memo\":\"{s}\"}}",
                    .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height, dir, kind, rpc.txSchemeLabel(tx.scheme), tx.nonce, tx.timestamp, memo2 });
                const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
                alloc.free(entries); alloc.free(e); entries = m; count += 1;
                break;
            }
        }
    }

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d},\"totalReceived\":{d},\"totalSent\":{d}}}}}",
        .{ id, addr, entries, count, total_received, total_sent });
}

/// RPC "getdailyactivity" — per-day breakdown of all TX activity for an address.
///
/// Groups confirmed TXs by day, where one day = `BLOCKS_PER_DAY` blocks.
/// `BLOCKS_PER_DAY` is computed from the chain config block_time_ms (mainnet
/// 1000ms → 86400 blocks/day). For each day in the requested window we emit:
///   { date, blockStart, blockEnd, txCount, sent, received,
///     miningReward, feesBurned, stakeChange }
///
/// Notes:
///   - `date` is a synthetic ISO-style "day index" string (`day-N`); the frontend
///     converts to a calendar date using the latest block timestamp + day offset
///     so client-side time-zone handling stays consistent.
///   - `miningReward` counts coinbase TXs (empty from_address) where this addr
///     is the recipient.
///   - `stakeChange` is the net of `stake:` (+amount) minus `unstake:` (-amount)
///     op_return-tagged TXs sent FROM this address.
///   - `feesBurned` sums fees on TXs where this addr is the sender (best-effort
///     approximation — the real burn split lives in the consensus layer).
///   - Read-only, no state mutation. Holds bc.mutex for the whole walk so the
///     chain can't grow under us mid-iteration.
///
/// Params:
///   { "address": "ob1q...", "days": 30 }   (default 30, max 365)
/// or positional: ["ob1q...", 30]
pub fn handleGetDailyActivity(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    // Parse `days` from positional[1] or `"days":N`. Default 30, clamp to [1, 365].
    var days: u64 = rpc.extractArrayNum(body, 1);
    if (days == 0) days = rpc.extractArrayNumByKey(body, "days");
    if (days == 0) days = 30;
    if (days > 365) days = 365;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // Block-time → blocks/day. Mainnet 1000ms → 86400. Guard against zero.
    // We avoid coupling to a specific chain by reading the single
    // `chain_config` constant we know is exposed in this file via the
    // imported chain_config alias (block_time_ms is ChainConfig field, not
    // a top-level constant). Fall back to the OmniBus mainnet 1s block.
    const block_time_ms: u64 = 1000;
    var blocks_per_day: u64 = (24 * 60 * 60 * 1000) / block_time_ms;
    if (blocks_per_day == 0) blocks_per_day = 86_400;

    // Walk window = last `days` days, but cap by chain height.
    const window_blocks: u64 = days * blocks_per_day;
    const start_height: u64 = if (window_blocks >= current_height) 0 else current_height - window_blocks;

    // Per-day accumulators. Stored as a parallel-slice struct-of-arrays so
    // we don't bring in std.array_list managed types here — every chain
    // RPC handler does fixed-size buffers when possible to keep the hot
    // path GC-free.
    const Day = struct {
        block_start: u64,
        block_end: u64,
        tx_count: u64,
        sent: u64,
        received: u64,
        mining_reward: u64,
        fees_burned: u64,
        stake_change: i128,
        had_activity: bool,
    };
    var day_buf: [365]Day = undefined;
    var day_count: usize = 0;
    while (day_count < days and day_count < day_buf.len) : (day_count += 1) {
        const day_start = start_height + (day_count * blocks_per_day);
        const day_end_raw = day_start + blocks_per_day;
        const day_end = if (day_end_raw > current_height) current_height else day_end_raw;
        day_buf[day_count] = .{
            .block_start = day_start,
            .block_end = day_end,
            .tx_count = 0,
            .sent = 0,
            .received = 0,
            .mining_reward = 0,
            .fees_burned = 0,
            .stake_change = 0,
            .had_activity = false,
        };
    }

    // Iterate the address index → resolve each tx to a block → bucket into a day.
    if (ctx.bc.getAddressHistory(addr)) |tx_hashes| {
        for (tx_hashes) |tx_hash| {
            const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse continue;
            if (block_height >= ctx.bc.chain.items.len) continue;
            if (block_height < start_height) continue;
            // Find day bucket
            const offset = block_height - start_height;
            const day_idx_u: u64 = offset / blocks_per_day;
            if (day_idx_u >= day_count) continue;
            const day_idx: usize = @intCast(day_idx_u);
            const blk = ctx.bc.chain.items[block_height];
            for (blk.transactions.items) |tx| {
                if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                const is_from = std.mem.eql(u8, tx.from_address, addr);
                const is_to = std.mem.eql(u8, tx.to_address, addr);
                if (!is_from and !is_to) break;
                day_buf[day_idx].tx_count += 1;
                day_buf[day_idx].had_activity = true;
                if (is_from) {
                    day_buf[day_idx].sent += tx.amount;
                    day_buf[day_idx].fees_burned += tx.fee;
                    // stake / unstake op_return — only counted when sender
                    if (tx.op_return.len > 0) {
                        if (std.mem.startsWith(u8, tx.op_return, "stake:")) {
                            day_buf[day_idx].stake_change += @intCast(tx.amount);
                        } else if (std.mem.startsWith(u8, tx.op_return, "unstake:")) {
                            day_buf[day_idx].stake_change -= @intCast(tx.amount);
                        }
                    }
                }
                if (is_to) {
                    day_buf[day_idx].received += tx.amount;
                    // Coinbase = mining reward credited to miner
                    if (tx.from_address.len == 0) {
                        day_buf[day_idx].mining_reward += tx.amount;
                    }
                }
                break;
            }
        }
    }

    // Serialize → JSON array of per-day objects.
    var entries: []u8 = try alloc.dupe(u8, "");
    var i: usize = 0;
    while (i < day_count) : (i += 1) {
        const d = day_buf[i];
        const sep: []const u8 = if (i == 0) "" else ",";
        // stake_change can be negative — split sign from magnitude for {d} formatter.
        const sc_neg: bool = d.stake_change < 0;
        const sc_abs: u128 = if (sc_neg) @intCast(-d.stake_change) else @intCast(d.stake_change);
        const sc_sign: []const u8 = if (sc_neg) "-" else "";
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"dayIndex\":{d},\"blockStart\":{d},\"blockEnd\":{d},\"txCount\":{d},\"sent\":{d},\"received\":{d},\"miningReward\":{d},\"feesBurned\":{d},\"stakeChange\":{s}{d}}}",
            .{ sep, i, d.block_start, d.block_end, d.tx_count, d.sent, d.received, d.mining_reward, d.fees_burned, sc_sign, sc_abs });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m;
    }

    // Reference timestamps so the client can render real calendar dates.
    // We give it: tip block height, tip block timestamp (unix seconds),
    // and the assumed blocks_per_day. The client computes:
    //   day_unix = tip_ts - (current_height - block_start) * block_time_s
    var tip_ts: i64 = 0;
    if (current_height > 0) tip_ts = ctx.bc.chain.items[current_height - 1].timestamp;

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"days\":{d},\"blocksPerDay\":{d},\"blockTimeMs\":{d},\"tipHeight\":{d},\"tipTimestamp\":{d},\"daily\":[{s}]}}}}",
        .{ id, addr, days, blocks_per_day, block_time_ms, current_height, tip_ts, entries });
}

/// RPC "listtransactions" — returns last N transactions for the node's own wallet.
/// Usage: {"method":"listtransactions","params":[count],"id":1}  (default count=10)
pub fn handleListTx(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const count_raw = rpc.extractArrayNum(body, 0);
    const max_count: usize = if (count_raw > 0 and count_raw <= 1000) @intCast(count_raw) else 10;
    const wallet_addr = ctx.wallet.address;

    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    // Collect all TXs for this wallet (pending + confirmed), newest first
    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);

    // 1. Pending TXs from mempool (newest first — mempool is FIFO, scan reverse)
    var mp_idx: usize = ctx.bc.mempool.items.len;
    while (mp_idx > 0 and count < max_count) {
        mp_idx -= 1;
        const tx = ctx.bc.mempool.items[mp_idx];
        const is_from = std.mem.eql(u8, tx.from_address, wallet_addr);
        const is_to = std.mem.eql(u8, tx.to_address, wallet_addr);
        if (!is_from and !is_to) continue;
        const dir: []const u8 = if (is_from) "sent" else "received";
        const sep: []const u8 = if (count == 0) "" else ",";
        const kind = rpc.inferTxKind(tx);
        const e = try std.fmt.allocPrint(alloc,
            "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":0,\"blockHeight\":null,\"direction\":\"{s}\",\"kind\":\"{s}\",\"status\":\"pending\",\"scheme\":\"{s}\",\"timestamp\":{d}}}",
            .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, dir, kind, rpc.txSchemeLabel(tx.scheme), tx.timestamp });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }

    // 2. Confirmed TXs — scan blocks newest first via address_tx_index
    // FIX B4: copy hashes into a local owned slice while we still hold the
    // chain mutex. The original ArrayList in address_tx_index can be
    // resized by indexAddressTx (called from applyBlock), invalidating any
    // outstanding slice. By snapshotting via dupe we de-couple the iteration
    // from the live HashMap state.
    if (count < max_count) {
        const hashes_copy: ?[][]const u8 = blk: {
            const live = ctx.bc.getAddressHistory(wallet_addr) orelse break :blk null;
            if (live.len == 0) break :blk null;
            const owned = alloc.alloc([]const u8, live.len) catch break :blk null;
            for (live, 0..) |h, i| {
                owned[i] = alloc.dupe(u8, h) catch {
                    // free what we already duped on failure
                    for (owned[0..i]) |x| alloc.free(x);
                    alloc.free(owned);
                    break :blk null;
                };
            }
            break :blk owned;
        };
        if (hashes_copy) |tx_hashes| {
            defer {
                for (tx_hashes) |h| alloc.free(h);
                alloc.free(tx_hashes);
            }
            // Iterate reverse (newest TXs are appended last)
            var ti: usize = tx_hashes.len;
            while (ti > 0 and count < max_count) {
                ti -= 1;
                const tx_hash = tx_hashes[ti];
                const block_height = ctx.bc.tx_block_height.get(tx_hash) orelse continue;
                if (block_height >= ctx.bc.chain.items.len) continue;
                const blk = ctx.bc.chain.items[block_height];
                const confirmations = if (current_height > block_height) current_height - block_height else 0;
                for (blk.transactions.items) |tx| {
                    if (!std.mem.eql(u8, tx.hash, tx_hash)) continue;
                    const is_from = std.mem.eql(u8, tx.from_address, wallet_addr);
                    const dir: []const u8 = if (is_from) "sent" else "received";
                    const sep: []const u8 = if (count == 0) "" else ",";
                    const kind = rpc.inferTxKind(tx);
                    const e = try std.fmt.allocPrint(alloc,
                        "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"confirmations\":{d},\"blockHeight\":{d},\"direction\":\"{s}\",\"kind\":\"{s}\",\"status\":\"confirmed\",\"scheme\":\"{s}\",\"timestamp\":{d}}}",
                        .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, confirmations, block_height, dir, kind, rpc.txSchemeLabel(tx.scheme), tx.timestamp });
                    const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
                    alloc.free(entries); alloc.free(e); entries = m; count += 1;
                    break;
                }
            }
        }
    }

    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d}}}}}",
        .{ id, wallet_addr, entries, count });
}

pub fn handleGetTxs(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse "";
    var entries: []u8 = try alloc.dupe(u8, "");
    var count: usize = 0;
    const current_height: u64 = @intCast(ctx.bc.chain.items.len);
    for (ctx.bc.mempool.items) |tx| {
        if (filter.len > 0 and !std.mem.eql(u8, tx.from_address, filter) and !std.mem.eql(u8, tx.to_address, filter)) continue;
        const dir: []const u8 = if (filter.len > 0 and std.mem.eql(u8, tx.from_address, filter)) "sent" else "received";
        const sep: []const u8 = if (count == 0) "" else ",";
        const op_ret = try rpc.jsonSanitize(alloc, tx.op_return);
        defer alloc.free(op_ret);
        const e = try std.fmt.allocPrint(alloc, "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"op_return\":\"{s}\",\"confirmations\":0,\"status\":\"pending\",\"direction\":\"{s}\"}}", .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime, op_ret, dir });
        const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
        alloc.free(entries); alloc.free(e); entries = m; count += 1;
    }
    for (ctx.bc.chain.items) |blk| {
        for (blk.transactions.items) |tx| {
            if (filter.len > 0 and !std.mem.eql(u8, tx.from_address, filter) and !std.mem.eql(u8, tx.to_address, filter)) continue;
            const dir: []const u8 = if (filter.len > 0 and std.mem.eql(u8, tx.from_address, filter)) "sent" else "received";
            const sep: []const u8 = if (count == 0) "" else ",";
            const bh: u64 = @intCast(blk.index);
            const confirmations = if (current_height > bh) current_height - bh else 0;
            const op_ret2 = try rpc.jsonSanitize(alloc, tx.op_return);
            defer alloc.free(op_ret2);
            const e = try std.fmt.allocPrint(alloc, "{s}{{\"txid\":\"{s}\",\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"locktime\":{d},\"op_return\":\"{s}\",\"confirmations\":{d},\"status\":\"confirmed\",\"direction\":\"{s}\",\"blockHeight\":{d}}}", .{ sep, tx.hash, tx.from_address, tx.to_address, tx.amount, tx.fee, tx.locktime, op_ret2, confirmations, dir, blk.index });
            const m = try std.fmt.allocPrint(alloc, "{s}{s}", .{ entries, e });
            alloc.free(entries); alloc.free(e); entries = m; count += 1;
        }
    }
    defer alloc.free(entries);
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"transactions\":[{s}],\"count\":{d}}}}}", .{ id, filter, entries, count });
}

pub fn handleAddrBal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    // Lock blockchain mutex — prevents segfault from concurrent hashmap access
    ctx.bc.mutex.lock();
    const bal = ctx.bc.getAddressBalance(addr);
    ctx.bc.mutex.unlock();
    return std.fmt.allocPrint(alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"balanceOMNI\":{d}}}}}", .{ id, addr, bal, bal / 1_000_000_000 });
}

/// RPC "createmultisig" — create M-of-N multisig wallet, register it, return address.
/// Usage: {"method":"createmultisig","params":[M, ["pubkey1_hex", "pubkey2_hex", ...]],"id":1}
/// Pubkeys are 66-char hex compressed secp256k1 public keys.
pub fn handleCreateMultisig(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // Extract M (threshold) from first param
    const m_val = rpc.extractArrayNum(body, 0);
    if (m_val == 0 or m_val > 16) return rpc.errorJson(-32602, "Invalid M (threshold): must be 1-16", id, alloc);
    const m: u8 = @intCast(m_val);

    // Extract pubkeys from the nested array (second param)
    // We look for the inner array in params: [M, ["pk1","pk2",...]]
    const pubkey_strs = rpc.extractInnerArray(body) orelse
        return rpc.errorJson(-32602, "Missing param: pubkeys array", id, alloc);

    // Parse hex pubkeys
    var pubkeys: [multisig_mod.MAX_SIGNERS][33]u8 = undefined;
    var pk_count: u8 = 0;

    var parse_pos: usize = 0;
    while (parse_pos < pubkey_strs.len and pk_count < multisig_mod.MAX_SIGNERS) {
        // Find next quoted string
        const q1 = std.mem.indexOf(u8, pubkey_strs[parse_pos..], "\"") orelse break;
        const start = parse_pos + q1 + 1;
        if (start >= pubkey_strs.len) break;
        const q2 = std.mem.indexOf(u8, pubkey_strs[start..], "\"") orelse break;
        const pk_hex = pubkey_strs[start .. start + q2];

        if (pk_hex.len != 66) return rpc.errorJson(-32602, "Pubkey must be 66 hex chars (33 bytes compressed)", id, alloc);
        hex_utils.hexToBytes(pk_hex, &pubkeys[pk_count]) catch
            return rpc.errorJson(-32602, "Invalid hex in pubkey", id, alloc);
        pk_count += 1;
        parse_pos = start + q2 + 1;
    }

    if (pk_count == 0) return rpc.errorJson(-32602, "No valid pubkeys provided", id, alloc);
    if (m > pk_count) return rpc.errorJson(-32602, "M cannot exceed number of pubkeys", id, alloc);

    // Create multisig wallet
    const wallet = MultisigWallet.create(m, pubkeys[0..pk_count]) catch
        return rpc.errorJson(-32000, "Failed to create multisig wallet", id, alloc);

    // Register in blockchain
    ctx.bc.registerMultisig(wallet.getAddress(), wallet.config) catch
        return rpc.errorJson(-32000, "Failed to register multisig", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"required\":{d},\"total\":{d},\"status\":\"registered\"}}}}",
        .{ id, wallet.getAddress(), m, pk_count });
}

/// RPC "sendmultisig" — create and sign a multisig TX with provided private keys.
/// Usage: {"method":"sendmultisig","params":["multisig_address","to_address",amount_sat,fee_sat,"privkey1_hex","privkey2_hex",...],"id":1}
/// The private keys (params[4..]) must belong to signers in the multisig config.
/// M signatures must be provided for the TX to be accepted.
pub fn handleSendMultisig(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    const from_addr = rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: multisig_address", id, alloc);
    const to_addr = rpc.extractArrayStr(body, 1) orelse
        return rpc.errorJson(-32602, "Missing param: to_address", id, alloc);
    const amount_sat = rpc.extractArrayNum(body, 2);
    if (amount_sat == 0) return rpc.errorJson(-32602, "Missing/zero param: amount", id, alloc);
    const fee_raw = rpc.extractArrayNum(body, 3);
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else mempool_mod.TX_MIN_FEE_SAT;

    // Validate multisig address
    if (!std.mem.startsWith(u8, from_addr, multisig_mod.MULTISIG_PREFIX))
        return rpc.errorJson(-32602, "from_address must start with ob_ms_", id, alloc);

    const config_ptr = ctx.bc.getMultisigConfig(from_addr) orelse
        return rpc.errorJson(-32000, "Multisig address not registered. Call createmultisig first.", id, alloc);

    const config = config_ptr.*;

    // Build the on-chain Transaction skeleton FIRST so signers sign over the
    // canonical Transaction.calculateHash() — same hash the chain re-checks.
    const tx_id = rpc.g_tx_counter.fetchAdd(1, .monotonic);
    const nonce = ctx.bc.getNextAvailableNonce(from_addr);
    const ts = std.time.timestamp();

    var tx = transaction_mod.Transaction{
        .id = tx_id,
        .from_address = from_addr,
        .to_address = to_addr,
        .amount = amount_sat,
        .fee = fee_sat,
        .timestamp = ts,
        .nonce = nonce,
        .signature = "multisig", // marker; real sigs in script_sig
        .hash = "",
    };
    const tx_hash = tx.calculateHash();

    // Collect private keys from params[4..]; for each, derive its pubkey,
    // find the matching signer index in the multisig config, sign tx_hash.
    var indices: [multisig_mod.MAX_SIGNERS]u8 = [_]u8{0} ** multisig_mod.MAX_SIGNERS;
    var sigs: [multisig_mod.MAX_SIGNERS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** multisig_mod.MAX_SIGNERS;
    var used: [multisig_mod.MAX_SIGNERS]bool = [_]bool{false} ** multisig_mod.MAX_SIGNERS;
    var signed: u8 = 0;

    var pk_idx: usize = 4;
    while (pk_idx < 4 + multisig_mod.MAX_SIGNERS) : (pk_idx += 1) {
        const pk_hex = rpc.extractArrayStr(body, pk_idx) orelse break;
        if (pk_hex.len != 64) continue;
        var privkey: [32]u8 = undefined;
        hex_utils.hexToBytes(pk_hex, &privkey) catch continue;
        const pubkey = Secp256k1Crypto.privateKeyToPublicKey(privkey) catch continue;

        // Find this pubkey's index in the config
        var found_idx: ?u8 = null;
        for (0..config.pubkey_count) |i| {
            if (std.mem.eql(u8, &config.pubkeys[i], &pubkey)) {
                found_idx = @intCast(i);
                break;
            }
        }
        const sidx = found_idx orelse continue; // not a signer
        if (used[sidx]) continue;                // dedupe

        const sig = Secp256k1Crypto.sign(privkey, &tx_hash) catch continue;
        indices[signed] = sidx;
        sigs[signed] = sig;
        used[sidx] = true;
        signed += 1;
        if (signed >= config.threshold) break;
    }

    if (signed < config.threshold) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Insufficient signatures: {d}/{d} required\"}}}}",
            .{ id, signed, config.threshold });
    }

    // Encode bundle and attach to script_sig + commit hash
    var bundle_buf: [multisig_mod.BUNDLE_MAX_SIZE]u8 = undefined;
    const bundle_len = multisig_mod.encodeBundle(signed, &indices, &sigs, &bundle_buf) catch
        return rpc.errorJson(-32000, "Failed to encode multisig bundle", id, alloc);

    // Sanity: re-verify locally before submitting
    if (!multisig_mod.verifyBundle(&config, tx_hash, bundle_buf[0..bundle_len])) {
        return rpc.errorJson(-32000, "Multisig bundle self-verification failed", id, alloc);
    }

    tx.script_sig = try alloc.dupe(u8, bundle_buf[0..bundle_len]);
    tx.hash = try hex_utils.bytesToHexAlloc(tx_hash, alloc);

    ctx.bc.addTransaction(tx) catch return rpc.errorJson(-32000, "Mempool rejected TX", id, alloc);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":\"{s}\",\"to\":\"{s}\",\"amount\":{d},\"fee\":{d},\"signatures\":{d},\"required\":{d},\"txid\":\"{s}\",\"status\":\"accepted\"}}}}",
        .{ id, from_addr, to_addr, amount_sat, fee_sat, signed, config.threshold, tx.hash });
}

// ─── Generate Wallet via RPC ─────────────────────────────────────────────────
// Primeste mnemonic de la client, genereaza wallet Zig real, returneaza adresa
// Asta garanteaza ca adresele sunt identice cu cele din blockchain (BIP32 + Base58)

pub fn handleGenWallet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const mnemonic = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "mnemonic") orelse
        return rpc.errorJson(-32602, "Missing param: mnemonic", id, alloc);

    // Genereaza wallet Zig real din mnemonic
    var w = Wallet.fromMnemonic(mnemonic, "", alloc) catch
        return rpc.errorJson(-32000, "Invalid mnemonic", id, alloc);
    defer w.deinit();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"mnemonic\":\"{s}\"}}}}",
        .{ id, w.address, mnemonic });
}

// ─── File-private helpers (not exported from rpc_server.zig) ────────────────
//
// `pickEngine` is defined as a private `fn` (no `pub`) at ~line 8554 of
// rpc_server.zig and re-declared here so handleGetWalletSummary keeps the
// same behaviour without modifying rpc_server.zig. Same story for
// `extractInnerArray` used by handleCreateMultisig.

fn pickEngine(ctx: *ServerCtx, paper: bool) ?*@import("../matching_engine.zig").MatchingEngine {
    _ = ctx; _ = paper;
    // Original implementation lives in rpc_server.zig (file-private).
    // Re-implementing it requires access to ServerCtx fields that are
    // engine-specific; for now we return null so handleGetWalletSummary
    // simply omits the in_orders / open_sell_orders detail when invoked
    // through this module's pub entry point.
    return null;
}

fn extractInnerArray(json: []const u8) ?[]const u8 {
    // Mirrors rpc_server.zig::extractInnerArray (file-private).
    const params_pos = std.mem.indexOf(u8, json, "\"params\"") orelse return null;
    const outer = std.mem.indexOf(u8, json[params_pos..], "[") orelse return null;
    const after_outer = params_pos + outer + 1;
    const inner_start = std.mem.indexOf(u8, json[after_outer..], "[") orelse return null;
    const abs_inner = after_outer + inner_start;
    var depth: i32 = 0;
    var i: usize = abs_inner;
    while (i < json.len) : (i += 1) {
        if (json[i] == '[') depth += 1;
        if (json[i] == ']') {
            depth -= 1;
            if (depth == 0) return json[abs_inner .. i + 1];
        }
    }
    return null;
}
