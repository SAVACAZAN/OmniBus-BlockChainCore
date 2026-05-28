//! Balance-management helpers extracted from blockchain.zig.
//!
//! All functions are free functions taking `*Blockchain` (or `*const Blockchain`)
//! as their first argument. The Blockchain struct itself stays in blockchain.zig
//! and re-exposes them as thin method shims so external callers keep using
//! `bc.creditBalance(...)` syntax.
//!
//! Covers:
//!   - creditBalance / creditBalanceLocked
//!   - debitBalance  / debitBalanceLocked
//!   - getAddressBalance, getMatureBalance
//!   - auditBalanceConsistency
//!   - applyFillTransferOmniBase
//!   - applyExchangeFees
//!   - getNextNonce, getNextAvailableNonce
//!   - getPendingOutgoing
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const registrar_mod = @import("../registrar_addresses.zig");

const Blockchain = blockchain_mod.Blockchain;

pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
    return self.utxo_set.getBalance(address);
}

/// Returneaza balanta matura (doar UTXO-uri cu >=100 confirmari).
/// Coinbase-urile necesita 100 blocuri inainte de a fi cheltuibile.
pub fn getMatureBalance(self: *const Blockchain, address: []const u8) u64 {
    const current_height = if (self.chain.items.len == 0) 0
                          else @as(u64, @intCast(self.chain.items.len - 1));
    // Hold UTXO read-lock for the whole walk — otherwise the slice returned
    // by getUTXOsForAddress could be invalidated by a concurrent addUTXO.
    const lk = @constCast(&self.utxo_set.lock);
    lk.lockShared();
    defer lk.unlockShared();
    const list = self.utxo_set.address_index.get(address) orelse return 0;
    var total: u64 = 0;
    for (list.items) |op| {
        if (self.utxo_set.utxos.get(op)) |utxo| {
            if (utxo.isMature(current_height)) total += utxo.amount;
        }
    }
    return total;
}

pub const AuditResult = struct {
    addresses_checked: usize,
    divergences: usize,
};

/// Audit: compara RAM cache (bc.balances) cu UTXO set.
/// In debug builds fail-fast pe divergente; in release doar log.
pub fn auditBalanceConsistency(self: *const Blockchain) AuditResult {
    var checked: usize = 0;
    var diverged: usize = 0;
    var it = self.balances.iterator();
    while (it.next()) |kv| {
        checked += 1;
        const ram = kv.value_ptr.*;
        const utxo = self.utxo_set.getBalance(kv.key_ptr.*);
        if (ram != utxo) {
            diverged += 1;
            std.debug.print(
                "[AUDIT-DIVERGE] addr={s} ram={d} utxo={d}\n",
                .{ kv.key_ptr.*, ram, utxo },
            );
        }
    }
    return .{ .addresses_checked = checked, .divergences = diverged };
}

/// Adauga reward la balanta minerului.
/// Lock-uit pentru a preveni race-ul cu RPC threads care citesc balances
/// (HashMap-ul Zig nu e thread-safe; concurrent get/put produce segfault).
pub fn creditBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try creditBalanceLocked(self, address, amount);
}

/// Internal — caller must already hold self.mutex.
/// Folosit din applyBlock / replayState, care deja tin mutex-ul.
/// IMPORTANT: StringHashMap stocheaza slice-ul ca key fara sa-l copieze.
/// Daca punem mereu slice nou (allocator.dupe in fiecare block), HashMap-ul
/// keep slice-ul vechi ca key (vechiul pointer poate deveni invalid),
/// produced silent balance corruption — count-ul intra in entries duplicate
/// dupa content vs pointer.
/// Solutie: getOrPut + dupe DOAR la prima insertie. Update-ul ulterior
/// reutilizeaza key-ul deja persistent.
pub fn creditBalanceLocked(self: *Blockchain, address: []const u8, amount: u64) !void {
    // PHASE C.3 — write-only contract enforcement.
    //
    // Every legitimate balance write happens inside applyBlock,
    // mineBlockForMiner, or recalculateFromHeight (chain replay).
    // All three flip `in_apply_block = true` for the duration of
    // their work. Any write outside that window is a phantom
    // mutation that vanishes on the next restart — the same class
    // of bug that wiped 51 testnet faucet recipients on 2026-04-28.
    // Count them, log them with a stack hint, surface via the
    // stabilizer ALERT once a minute. Do NOT panic — that would
    // kill the node on a real production run; the goal is to
    // *catch* phantoms in CI/staging long before mainnet.
    if (!self.in_apply_block) {
        self.stray_balance_writes += 1;
        std.debug.print(
            "[STRAY-CREDIT] addr={s} amount={d} count={d} — must come from applyBlock/mineBlock/recalc\n",
            .{ address[0..@min(20, address.len)], amount, self.stray_balance_writes },
        );
    }
    // SEGFAULT-FIX [scan-2026-04-26]: dupe FIRST, then getOrPut on the duped slice.
    // The previous code did getOrPut(externally-borrowed slice) and only duped
    // on !found_existing. Problem: getOrPut iterates HashMap buckets calling
    // eqlString on EXISTING keys. If any of those existing keys was inserted
    // earlier when caller's slice memory was later freed (e.g. dropped block's
    // miner_address) → eqlString dereferences dangling pointer → SEGFAULT
    // observed live 2026-04-26 at blockchain.zig:334.
    // The dupe-first approach trades a tiny extra alloc on found_existing
    // for guaranteed-valid keys throughout HashMap lifetime.
    if (address.len == 0) return; // skip empty addresses (no miner)

    const owned = try self.allocator.dupe(u8, address);
    const gop = self.balances.getOrPut(owned) catch |err| {
        self.allocator.free(owned);
        return err;
    };
    if (gop.found_existing) {
        // Key already in map — free our dupe; the existing key stays valid
        // (it was duped at its own first insertion).
        self.allocator.free(owned);
    } else {
        // First time — `owned` becomes the persistent key.
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += amount;
}

/// Scade din balanta (pentru tranzactii)
pub fn debitBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try debitBalanceLocked(self, address, amount);
}

/// Internal — caller must already hold self.mutex.
/// Same dupe-first pattern as creditBalanceLocked to avoid dangling
/// HashMap key pointers when caller passes a transient slice.
pub fn debitBalanceLocked(self: *Blockchain, address: []const u8, amount: u64) !void {
    // PHASE C.3 — same phantom-write detector as creditBalanceLocked.
    if (!self.in_apply_block) {
        self.stray_balance_writes += 1;
        std.debug.print(
            "[STRAY-DEBIT] addr={s} amount={d} count={d} — must come from applyBlock/mineBlock/recalc\n",
            .{ address[0..@min(20, address.len)], amount, self.stray_balance_writes },
        );
    }
    if (address.len == 0) return;
    const owned = try self.allocator.dupe(u8, address);
    const gop = self.balances.getOrPut(owned) catch |err| {
        self.allocator.free(owned);
        return err;
    };
    if (gop.found_existing) {
        self.allocator.free(owned);
    } else {
        gop.value_ptr.* = 0;
    }
    if (gop.value_ptr.* < amount) return error.InsufficientBalance;
    gop.value_ptr.* -= amount;
}

/// Settle the base-asset leg of an OMNI-base fill: spend a UTXO from
/// seller and create one for buyer (+ change to seller if leftover).
/// Source of truth in this chain is the UTXO set, so updating the
/// in-RAM `balances` cache is not enough — getAddressBalance reads
/// UTXO directly.
///
/// We synthesize a virtual "fill" tx hash unique per fill so the
/// outpoint key doesn't collide with real transactions.
pub fn applyFillTransferOmniBase(
    self: *Blockchain,
    buyer_addr: []const u8,
    seller_addr: []const u8,
    amount_sat: u64,
    fill_id: u64,
) !void {
    if (amount_sat == 0) return;

    self.mutex.lock();
    defer self.mutex.unlock();

    // Collect seller UTXOs until we cover amount_sat. Spend them all,
    // create one buyer output, and one change output back to seller.
    // Snapshot the keys first (spendUTXO mutates the index list).
    const outpoint_keys_live = self.utxo_set.getUTXOsForAddress(seller_addr);
    if (outpoint_keys_live.len == 0) return error.NoUTXO;
    var outpoint_keys_snap = try self.allocator.alloc([]const u8, outpoint_keys_live.len);
    defer self.allocator.free(outpoint_keys_snap);
    for (outpoint_keys_live, 0..) |k, i| outpoint_keys_snap[i] = k;

    var collected: u64 = 0;
    var spent: usize = 0;
    for (outpoint_keys_snap) |key| {
        if (collected >= amount_sat) break;
        const u = self.utxo_set.utxos.get(key) orelse continue;
        collected += u.amount;
        spent += 1;
    }
    if (collected < amount_sat) return error.InsufficientBalance;

    // Actually spend them. We need to make owned copies of the keys
    // because spendUTXO frees the original (it lives in address_index
    // which spendUTXO mutates).
    const to_spend_keys = try self.allocator.alloc([]u8, spent);
    defer {
        for (to_spend_keys) |k| self.allocator.free(k);
        self.allocator.free(to_spend_keys);
    }
    for (outpoint_keys_snap[0..spent], 0..) |key, i| {
        to_spend_keys[i] = try self.allocator.dupe(u8, key);
    }
    for (to_spend_keys) |key| {
        const colon = std.mem.lastIndexOfScalar(u8, key, ':') orelse return error.BadOutpointKey;
        const src_tx_hash = key[0..colon];
        const src_idx = std.fmt.parseInt(u32, key[colon + 1 ..], 10) catch return error.BadOutpointKey;
        _ = self.utxo_set.spendUTXO(src_tx_hash, src_idx) catch return error.SpendFailed;
    }

    const fill_tx_hash = try std.fmt.allocPrint(self.allocator, "fill:{d}", .{fill_id});
    const change = collected - amount_sat;
    const block_height: u64 = if (self.chain.items.len == 0) 0 else self.chain.items.len - 1;

    const buyer_addr_owned = try self.allocator.dupe(u8, buyer_addr);
    try self.utxo_set.addUTXO(
        fill_tx_hash, 0, buyer_addr_owned, amount_sat, block_height, "", false,
    );

    if (change > 0) {
        const seller_addr_owned = try self.allocator.dupe(u8, seller_addr);
        try self.utxo_set.addUTXO(
            fill_tx_hash, 1, seller_addr_owned, change, block_height, "", false,
        );
    }

    // Also keep the RAM cache in sync so any reader using `balances`
    // sees the right number until next UTXO sync.
    const was_in_apply = self.in_apply_block;
    self.in_apply_block = true;
    defer self.in_apply_block = was_in_apply;
    debitBalanceLocked(self, seller_addr, amount_sat) catch {};
    creditBalanceLocked(self, buyer_addr, amount_sat) catch {};
}

pub fn applyExchangeFees(
    self: *Blockchain,
    taker_addr: []const u8,
    maker_addr: []const u8,
    taker_fee: u64,
    maker_fee: u64,
    network_fee_sat: u64,
) !void {
    const treasury = registrar_mod.addressOf(.exchange) orelse return error.NoTreasury;
    const net_taker_share = (network_fee_sat + 1) / 2; // ceil
    const net_maker_share = network_fee_sat - net_taker_share; // floor
    const taker_total = taker_fee + net_taker_share;
    const maker_total = maker_fee + net_maker_share;

    self.mutex.lock();
    defer self.mutex.unlock();

    // Pre-check both balances so we never partial-mutate.
    const taker_bal = self.balances.get(taker_addr) orelse 0;
    const maker_bal = self.balances.get(maker_addr) orelse 0;
    if (taker_bal < taker_total) return error.InsufficientBalance;
    if (maker_bal < maker_total) return error.InsufficientBalance;

    const was_in_apply = self.in_apply_block;
    self.in_apply_block = true;
    defer self.in_apply_block = was_in_apply;

    if (taker_total > 0) try debitBalanceLocked(self, taker_addr, taker_total);
    if (maker_total > 0) try debitBalanceLocked(self, maker_addr, maker_total);

    // Treasury credit covers taker_fee + maker_fee always.
    // Network-fee portion goes to either accumulator (miner) or treasury
    // depending on the route_fees_to_miner switch.
    const treasury_credit = if (self.consensus_params.route_fees_to_miner)
        taker_fee + maker_fee
    else
        taker_total + maker_total;
    if (treasury_credit > 0) try creditBalanceLocked(self, treasury, treasury_credit);

    if (self.consensus_params.route_fees_to_miner and network_fee_sat > 0) {
        self.pending_miner_fees +|= network_fee_sat;
    }
}

/// Returneaza totalul outgoing pending din mempool pentru o adresa (amount + fee per TX)
/// Folosit in validateTransaction() pentru a preveni double-spend cu TX-uri rapide
pub fn getPendingOutgoing(self: *const Blockchain, address: []const u8) u64 {
    var total: u64 = 0;
    for (self.mempool.items) |tx| {
        if (std.mem.eql(u8, tx.from_address, address)) {
            total += tx.amount + tx.fee;
        }
    }
    return total;
}

/// Returneaza urmatorul nonce confirmat pentru o adresa (0 daca nu exista)
/// Acesta este nonce-ul pe chain — NU include TX-urile pending din mempool
pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
    return self.nonces.get(address) orelse 0;
}

/// Returneaza urmatorul nonce disponibil pentru o adresa,
/// incluzand TX-urile pending din mempool (chain_nonce + pending_count).
/// Aceasta metoda este utila pentru RPC "getnonce" — clientul stie ce nonce sa puna pe urmatoarea TX.
pub fn getNextAvailableNonce(self: *const Blockchain, address: []const u8) u64 {
    const chain_nonce = self.nonces.get(address) orelse 0;
    // Count pending TXs from this sender in mempool
    var pending: u64 = 0;
    for (self.mempool.items) |tx| {
        if (std.mem.eql(u8, tx.from_address, address)) {
            pending += 1;
        }
    }
    return chain_nonce + pending;
}
