// Name-service JSON-RPC handlers — ENS-like registry on OmniBus.
//
// Operations: register, resolve (forward + reverse + resolve-for-send),
// list, transfer, update, renew, prune-expired. Categories + preferred-slot
// metadata + per-TLD year-tier fees are exposed via ns_*.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const dns_mod = @import("../dns_registry.zig");
const registrar_mod = @import("../registrar_addresses.zig");

const ServerCtx = rpc.ServerCtx;

// ─── DNS / ENS handlers ─────────────────────────────────────────────────────
//
// On-chain name registry. Resolves human-friendly names like "alice" or
// "savacazan" to ob1q… addresses. The DnsRegistry struct lives in
// dns_registry.zig — we just expose 4 RPC methods over it.
//
// Why "alice", not "alice.omnibus": the registry stores the raw label.
// Front-ends append .omnibus for display (matching the LCX-side ENS).
// Registration is permissionless on testnet (no fee enforced yet) so the
// stress-test scripts can populate it freely.

pub fn handleRegisterName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "name") orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const address = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    // Owner defaults to the address being registered (self-ownership).
    const owner = rpc.extractArrayStr(body, 2) orelse rpc.extractStr(body, "owner") orelse address;
    // TLD optional — default "omnibus" (backward compat).
    const tld = rpc.extractArrayStr(body, 3) orelse rpc.extractStr(body, "tld") orelse "omnibus";
    // Fee txid optional — param[4] sau key "fee_txid".
    const fee_txid = rpc.extractArrayStr(body, 4) orelse rpc.extractStr(body, "fee_txid") orelse null;
    // Phase 2: years tier (1, 2, 3, 4, 5, 10, 25, 50, 100). Default 1.
    const years_raw = rpc.extractArrayNumByKey(body, "years");
    const years: u32 = if (years_raw == 0) 1 else @intCast(@min(years_raw, dns_mod.MAX_REGISTRATION_YEARS));
    if (!dns_mod.isValidYears(years)) {
        return rpc.errorJson(-32602, "Invalid years (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)", id, alloc);
    }

    // Phase 1: optional signature params (param[5..7] sau keys).
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    const sig_hex = rpc.extractStr(body, "signature") orelse "";
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse "";

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    // Sybil-resistant fee: scales with how many names `owner` already holds
    // (cheap for first-time registrants, progressively expensive for bulk
    // squatters). Owner count snapshotted at current_block, before this TX.
    const owner_count = dns.countNamesOwnedBy(owner, current_block);
    const required_fee = dns_mod.feeForRegistrationWithOwnerCount(name, tld, years, owner_count);

    // Phase 1: signature verification when signed_required is true.
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required) {
        if (sig_hex.len == 0 or (pubkey_hex.len == 0 and !is_hmac_bypass)) {
            return rpc.errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        if (!is_hmac_bypass) {
            var msg_buf: [512]u8 = undefined;
            const msg = rpc.buildDnsRegisterSignMessage(name, tld, address, owner, nonce, &msg_buf) catch
                return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
            if (!rpc.verifyDnsSignature(msg, sig_hex, pubkey_hex, owner, alloc)) {
                return rpc.errorJson(-32401, "Signing pubkey does not match owner address", id, alloc);
            }
        }
    }

    // Fee enforcement
    if (dns.fee_enforcement) {
        const txid = fee_txid orelse
            return rpc.errorJson(-32602, "fee_txid required (mainnet)", id, alloc);
        if (txid.len != dns_mod.TXID_LEN) {
            return rpc.errorJson(-32031, "fee TX invalid: txid must be 64 hex chars", id, alloc);
        }
        if (dns.isTxidConsumed(txid)) {
            return rpc.errorJson(-32031, "fee TX invalid: txid already used", id, alloc);
        }

        // Cauta TX in chain (confirmed blocks)
        var found_tx: ?*const transaction_mod.Transaction = null;
        ctx.bc.mutex.lock();
        for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |*tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    break;
                }
            }
            if (found_tx != null) break;
        }
        ctx.bc.mutex.unlock();

        const tx = found_tx orelse
            return rpc.errorJson(-32031, "fee TX invalid: transaction not found in chain", id, alloc);

        const treasury = dns.getTreasury();
        if (!std.mem.eql(u8, tx.to_address, treasury)) {
            return rpc.errorJson(-32031, "fee TX invalid: destination is not treasury", id, alloc);
        }
        if (tx.amount < required_fee) {
            return rpc.errorJson(-32031, "fee TX invalid: amount too low", id, alloc);
        }
    }

    dns.registerWithTldYearsAndFee(name, tld, address, owner, current_block, fee_txid, years) catch |err| {
        const msg: []const u8 = switch (err) {
            error.InvalidName     => "Invalid name (3-25 chars, lowercase a-z 0-9 _, must start with letter)",
            error.InvalidTld      => "Invalid TLD (allowed: omnibus, arbitraje, quantum, bank, gov, mil, fin, edu, org, dev)",
            error.NameTaken       => "Name already taken on this TLD",
            error.NameTakenCrossTld => "Name already held by another owner on a different TLD (cross-TLD uniqueness — anti-squatting)",
            error.InvalidYears    => "Invalid years tier (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)",
            error.RegistryFull    => "Registry full",
            error.FeeRequired     => "Fee required",
            error.InvalidTxid     => "Invalid txid",
            error.TxidAlreadyUsed => "Txid already used",
            error.ConsumedTxidsFull => "Consumed txids full",
            error.ReservedName    => "Reserved name",
            error.OwnerCapExceeded => "Per-owner name cap exceeded (max 10)",
        };
        return rpc.errorJson(-32031, msg, id, alloc);
    };

    // Update last_nonce on the newly created entry.
    if (dns.lookupEntry(name, tld)) |e| {
        e.last_nonce = nonce;
    }

    std.debug.print("[DNS] Registered '{s}.{s}' -> {s}\n",
        .{ name[0..@min(name.len, 25)], tld[0..@min(tld.len, 16)], address[0..@min(address.len, 16)] });

    const fee_paid_sat: u64 = if (fee_txid) |_| required_fee else 0;
    const fee_txid_esc = fee_txid orelse "";

    // Audit log
    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"address\":\"{s}\",\"owner\":\"{s}\",\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\",\"fee_paid_sat\":{d},\"fee_txid\":\"{s}\"",
        .{ name, tld, address, owner, nonce, pubkey_hex, sig_hex, fee_paid_sat, fee_txid_esc }) catch "";
    if (audit_fields.len > 0) rpc.dnsAuditAppend(ctx, "register", audit_fields);

    // WS push — frontend name-list refreshes without polling.
    if (main_mod.g_ws_srv) |ws| {
        ws.broadcastNameRegistered(name, tld, address, @intCast(@min(years, 255)));
    }

    {
        const rn_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(rn_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":\"{s}\",\"registeredAtBlock\":{d},\"fee_paid_sat\":{d},\"fee_txid\":\"{s}\"}}}}",
            .{ id, rn_safe, tld, rn_safe, tld, address, current_block, fee_paid_sat, fee_txid_esc });
    }
}

pub fn handleResolveName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    var name = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "name") orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    // Tolerant: strip the TLD suffix if user includes it (UI typically
    // displays "alice.omnibus" or "alice.bank" — Phase 2 extends to all 10).
    var tld_from_name: ?[]const u8 = null;
    inline for (.{
        ".omnibus", ".arbitraje", ".quantum", ".bank", ".gov",
        ".mil", ".fin", ".edu", ".org", ".dev",
    }) |suffix| {
        if (name.len > suffix.len and std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) {
            tld_from_name = suffix[1..]; // drop leading dot
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    // Explicit `tld` param overrides; else use the one stripped from the name; else default.
    const tld = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "tld") orelse
        (tld_from_name orelse "omnibus");

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    // Phase 2: lookup the full entry (not just the address) so we can
    // surface category, PQ slots, preferred slot, and registered_years.
    const name_safe = try rpc.jsonSanitize(alloc, name);
    defer alloc.free(name_safe);
    const entry = dns.lookupEntry(name, tld);
    if (entry) |e| {
        if (e.active and !e.isExpired(current_block)) {
            // Pull each PQ slot — empty slot returns the primary as fallback,
            // so JS sees a usable address either way. Mark `*_set` so the UI
            // can still render "not configured" badges where appropriate.
            const pq_k = e.getPqAddress(.ml_dsa);
            const pq_f = e.getPqAddress(.falcon);
            const pq_s = e.getPqAddress(.dilithium);
            const pq_d = e.getPqAddress(.slh_dsa);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
                    "\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
                    "\"address\":\"{s}\"," ++  // primary (legacy field)
                    "\"addresses\":{{" ++
                        "\"primary\":\"{s}\"," ++
                        "\"k\":\"{s}\",\"k_set\":{}," ++
                        "\"f\":\"{s}\",\"f_set\":{}," ++
                        "\"s\":\"{s}\",\"s_set\":{}," ++
                        "\"d\":\"{s}\",\"d_set\":{}" ++
                    "}}," ++
                    "\"category\":\"{s}\"," ++
                    "\"preferred_slot\":{d}," ++
                    "\"registered_years\":{d}," ++
                    "\"registered_block\":{d}," ++
                    "\"expires_block\":{d}," ++
                    "\"found\":true" ++
                "}}}}",
                .{
                    id, name_safe, tld, name_safe, tld,
                    e.getAddress(),
                    e.getAddress(),
                    pq_k, e.addr_pq_lens[0] > 0,
                    pq_f, e.addr_pq_lens[1] > 0,
                    pq_s, e.addr_pq_lens[2] > 0,
                    pq_d, e.addr_pq_lens[3] > 0,
                    e.category.toString(),
                    e.preferred_slot,
                    e.registered_years,
                    e.registered_block,
                    e.expires_block,
                });
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\",\"address\":null,\"found\":false}}}}",
        .{ id, name_safe, tld, name_safe, tld });
}

/// Phase 2 send-routing helper — closes the loop on `preferred_slot`.
///
/// `resolveName` returns the full DNS entry (all 4 PQ slots + flags), pushing
/// the routing decision to the client. `ns_resolveForSend` is the opinionated
/// variant: chain decides which address to deliver to and tells the wallet
/// exactly which kind of address it is.
///
/// Result contract:
/// ```
/// {
///   "name": "alice", "tld": "bank", "fullLabel": "alice.bank",
///   "primary_address": "ob1q…",        // always the ECDSA address
///   "route_slot": 0|1|2|3|4,            // 0 = ECDSA, 1=ML-DSA, 2=Falcon,
///                                       // 3=Dilithium, 4=SLH-DSA
///   "route_address": "obk1_…",          // the address to send to
///   "route_address_kind": "ecdsa"|"ml_dsa"|"falcon"|"dilithium"|"slh_dsa",
///   "preferred_slot": <stored>,         // raw on-chain field (may differ
///                                       // from route_slot if pref slot empty)
///   "fell_back_to_primary": false,      // true if pref was set but slot empty
///   "found": true
/// }
/// ```
/// When `preferred_slot == 0` or the corresponding PQ slot is unset, the chain
/// falls back to the primary ECDSA address and `route_slot == 0`. Default
/// behavior is therefore unchanged for legacy entries.
pub fn handleResolveForSend(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    var name = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "name") orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    // Mirror `resolvename` tolerance — accept "alice.bank" or just "alice".
    var tld_from_name: ?[]const u8 = null;
    inline for (.{
        ".omnibus", ".arbitraje", ".quantum", ".bank", ".gov",
        ".mil", ".fin", ".edu", ".org", ".dev",
    }) |suffix| {
        if (name.len > suffix.len and std.mem.eql(u8, name[name.len - suffix.len ..], suffix)) {
            tld_from_name = suffix[1..];
            name = name[0 .. name.len - suffix.len];
            break;
        }
    }
    const tld = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "tld") orelse
        (tld_from_name orelse "omnibus");

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const entry = dns.lookupEntry(name, tld);
    if (entry) |e| {
        if (e.active and !e.isExpired(current_block)) {
            const primary = e.getAddress();
            var route_slot: u8 = 0;
            var route_addr: []const u8 = primary;
            var route_kind: []const u8 = "ecdsa";
            var fell_back: bool = false;

            if (e.preferred_slot >= 1 and e.preferred_slot <= dns_mod.PQ_SLOT_COUNT) {
                const idx = e.preferred_slot - 1;
                if (e.addr_pq_lens[idx] > 0) {
                    route_slot = e.preferred_slot;
                    route_addr = e.addr_pq[idx][0..e.addr_pq_lens[idx]];
                    route_kind = switch (idx) {
                        0 => "ml_dsa",
                        1 => "falcon",
                        2 => "dilithium",
                        3 => "slh_dsa",
                        else => "ecdsa",
                    };
                } else {
                    // Owner declared a preference but never populated the slot;
                    // wallet falls through to ECDSA so the TX still lands.
                    fell_back = true;
                }
            }

            const rfs_safe = try rpc.jsonSanitize(alloc, name);
            defer alloc.free(rfs_safe);
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
                    "\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
                    "\"primary_address\":\"{s}\"," ++
                    "\"route_slot\":{d}," ++
                    "\"route_address\":\"{s}\"," ++
                    "\"route_address_kind\":\"{s}\"," ++
                    "\"preferred_slot\":{d}," ++
                    "\"fell_back_to_primary\":{}," ++
                    "\"found\":true" ++
                "}}}}",
                .{
                    id, rfs_safe, tld, rfs_safe, tld,
                    primary,
                    route_slot,
                    route_addr,
                    route_kind,
                    e.preferred_slot,
                    fell_back,
                });
        }
    }
    {
        const rfs_nf = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(rfs_nf);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"fullLabel\":\"{s}.{s}\"," ++
                "\"primary_address\":null,\"route_slot\":0,\"route_address\":null," ++
                "\"route_address_kind\":\"ecdsa\",\"preferred_slot\":0," ++
                "\"fell_back_to_primary\":false,\"found\":false}}}}",
            .{ id, rfs_nf, tld, rfs_nf, tld });
    }
}

pub fn handleReverseResolveName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const address = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const found = dns.reverseResolve(address, current_block);

    if (found) |name| {
        const rr_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(rr_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"name\":\"{s}\",\"found\":true}}}}",
            .{ id, address, rr_safe });
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"name\":null,\"found\":false}}}}",
        .{ id, address });
}

pub fn handleListNames(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    _ = body;

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);

    var json = std.array_list.Managed(u8).init(alloc);
    errdefer json.deinit();
    var w = json.writer();

    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"entries\":[", .{id});

    var first = true;
    var active_count: usize = 0;
    for (dns.entries[0..dns.entry_count]) |*e| {
        if (!e.active or e.isExpired(current_block)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":\"");
        try rpc.writeJsonSafeStr(w, e.getName());
        try w.print(
            "\",\"tld\":\"{s}\",\"fullLabel\":\"",
            .{e.getTld()},
        );
        try rpc.writeJsonSafeStr(w, e.getName());
        try w.print(
            ".{s}\",\"address\":\"{s}\",\"category\":\"{s}\"," ++
                "\"preferred_slot\":{d},\"registered_years\":{d}," ++
                "\"registeredAtBlock\":{d},\"expiresAtBlock\":{d}}}",
            .{
                e.getTld(), e.getAddress(),
                e.category.toString(), e.preferred_slot, e.registered_years,
                e.registered_block, e.expires_block,
            },
        );
        active_count += 1;
    }

    try w.print("],\"total\":{d}}}}}", .{active_count});
    return json.toOwnedSlice();
}

pub fn handleGetEnsFee(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Name registration PRICE — same on every chain. This is what the user
    // pays to claim the name (think domain-registrar pricing, not gas fee).
    // The TX-level network fee is separate and tiny (TX_MIN_FEE_SAT).
    //
    // Optional `owner_address` (param[0] or key) — when provided, returns
    // the Sybil progressive multiplier the owner currently faces (1.0× for
    // 0 names, 2.0× at 5 names, 3.0× at 10, etc.). Without it, multiplier
    // defaults to 1.0× (base price). Frontend wallet UI passes the
    // connected address so the displayed price matches what the chain
    // will actually charge.
    if (ctx.dns == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury\":\"\",\"enforcement\":false,\"cost_omnibus_omni\":5,\"cost_arbitraje_omni\":10,\"owner_count\":0,\"sybil_multiplier_milli\":1000}}}}",
            .{id});
    }
    const dns = ctx.dns.?;
    const treasury = dns.getTreasury();

    var owner_count: usize = 0;
    var multiplier_milli: u64 = 1000;
    if (rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "owner_address")) |owner_addr| {
        if (owner_addr.len > 0) {
            const current_block: u64 = @intCast(ctx.bc.chain.items.len);
            owner_count = dns.countNamesOwnedBy(owner_addr, current_block);
            multiplier_milli = dns_mod.sybilFeeMultiplierMilli(owner_count);
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"treasury\":\"{s}\",\"enforcement\":{},\"cost_omnibus_omni\":5,\"cost_arbitraje_omni\":10,\"owner_count\":{d},\"sybil_multiplier_milli\":{d}}}}}",
        .{ id, treasury, dns.fee_enforcement, owner_count, multiplier_milli });
}

/// ns_listTlds — read-only. Returneaza toate TLD-urile permise + fee-uri
/// pentru auto-discovery la wallet UI / SDK. Equivalent cu pq_listSchemes
/// dar pentru namespace.
pub fn handleNsListTlds(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    // Hardcoded list — must mirror dns_mod.ALLOWED_TLDS exactly.
    // Each entry: {tld, fee_sat (raw), fee_omni (display), category, mainnet_fee_omni}
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
            "{{\"tld\":\"omnibus\",\"fee_sat\":5000000000,\"fee_omni\":\"5\",\"category\":\"personal\",\"mainnet_fee_omni\":5}}," ++
            "{{\"tld\":\"arbitraje\",\"fee_sat\":10000000000,\"fee_omni\":\"10\",\"category\":\"trading\",\"mainnet_fee_omni\":10}}," ++
            "{{\"tld\":\"quantum\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"premium_personal\",\"mainnet_fee_omni\":10}}," ++
            "{{\"tld\":\"bank\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"financial_institution\",\"mainnet_fee_omni\":50}}," ++
            "{{\"tld\":\"gov\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"government\",\"mainnet_fee_omni\":100}}," ++
            "{{\"tld\":\"mil\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"military\",\"mainnet_fee_omni\":50}}," ++
            "{{\"tld\":\"fin\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"financial_trustee\",\"mainnet_fee_omni\":50}}," ++
            "{{\"tld\":\"edu\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"academic\",\"mainnet_fee_omni\":20}}," ++
            "{{\"tld\":\"org\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"non_profit\",\"mainnet_fee_omni\":10}}," ++
            "{{\"tld\":\"dev\",\"fee_sat\":1000000,\"fee_omni\":\"0.001\",\"category\":\"developer\",\"mainnet_fee_omni\":5}}" ++
        "]}}",
        .{id});
}

/// ns_yearTiers — read-only. Returns the allowed registration durations
/// (years) and their fee multipliers. Wallet UI uses this to render the
/// "register for X years" dropdown without hardcoding the table.
pub fn handleNsYearTiers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
            "{{\"years\":1,\"multiplier\":1.000,\"per_year_pct\":100}}," ++
            "{{\"years\":2,\"multiplier\":1.900,\"per_year_pct\":95}}," ++
            "{{\"years\":3,\"multiplier\":2.800,\"per_year_pct\":93}}," ++
            "{{\"years\":4,\"multiplier\":3.700,\"per_year_pct\":92}}," ++
            "{{\"years\":5,\"multiplier\":4.500,\"per_year_pct\":90}}," ++
            "{{\"years\":10,\"multiplier\":8.000,\"per_year_pct\":80}}," ++
            "{{\"years\":25,\"multiplier\":18.000,\"per_year_pct\":72}}," ++
            "{{\"years\":50,\"multiplier\":32.000,\"per_year_pct\":64}}," ++
            "{{\"years\":100,\"multiplier\":55.000,\"per_year_pct\":55}}" ++
        "]}}",
        .{id});
}

/// ns_stats — read-only. Returns the full NS Health Dashboard snapshot in
/// a single round-trip: totals, per-category / per-TLD / per-years counts,
/// and PQ/preferred-slot adoption metrics. Replaces the old fan-out where
/// the UI called `getnamesbycategory` per category or downloaded all 1000
/// entries via `listnames`.
pub fn handleNsStats(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const s = dns.getStats(current_block);
    // Category indices (match dns_mod.Category enum):
    //   0=none, 1=personal, 2=bank, 3=gov, 4=mil, 5=fin, 6=edu, 7=org, 8=dev, 9=trading
    // TLD indices (match dns_mod.ALLOWED_TLDS):
    //   0=omnibus, 1=arbitraje, 2=quantum, 3=bank, 4=gov, 5=mil, 6=fin, 7=edu, 8=org, 9=dev
    // Years indices (match dns_mod.ALLOWED_YEARS):
    //   0=1, 1=2, 2=3, 3=4, 4=5, 5=10, 6=25, 7=50, 8=100
    // Split into 3 chunks — std.fmt.allocPrint caps at 32 args per call.
    const head = try std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"total_active\":{d},\"total_expired\":{d}," ++
            "\"by_category\":{{" ++
                "\"personal\":{d},\"bank\":{d},\"gov\":{d},\"mil\":{d},\"fin\":{d}," ++
                "\"edu\":{d},\"org\":{d},\"dev\":{d},\"trading\":{d},\"none\":{d}" ++
            "}},",
        .{
            id, s.total_active, s.total_expired,
            s.counts_by_category[1], s.counts_by_category[2], s.counts_by_category[3],
            s.counts_by_category[4], s.counts_by_category[5], s.counts_by_category[6],
            s.counts_by_category[7], s.counts_by_category[8], s.counts_by_category[9],
            s.counts_by_category[0],
        });
    defer alloc.free(head);
    const middle = try std.fmt.allocPrint(alloc,
        "\"by_tld\":{{" ++
            "\"omnibus\":{d},\"arbitraje\":{d},\"quantum\":{d},\"bank\":{d},\"gov\":{d}," ++
            "\"mil\":{d},\"fin\":{d},\"edu\":{d},\"org\":{d},\"dev\":{d}" ++
        "}},",
        .{
            s.counts_by_tld[0], s.counts_by_tld[1], s.counts_by_tld[2], s.counts_by_tld[3],
            s.counts_by_tld[4], s.counts_by_tld[5], s.counts_by_tld[6], s.counts_by_tld[7],
            s.counts_by_tld[8], s.counts_by_tld[9],
        });
    defer alloc.free(middle);
    const tail = try std.fmt.allocPrint(alloc,
        "\"by_years\":{{" ++
            "\"1\":{d},\"2\":{d},\"3\":{d},\"4\":{d},\"5\":{d}," ++
            "\"10\":{d},\"25\":{d},\"50\":{d},\"100\":{d}" ++
        "}}," ++
        "\"pq_slots_set\":{d},\"preferred_slot_set\":{d}}}}}",
        .{
            s.counts_by_years[0], s.counts_by_years[1], s.counts_by_years[2],
            s.counts_by_years[3], s.counts_by_years[4], s.counts_by_years[5],
            s.counts_by_years[6], s.counts_by_years[7], s.counts_by_years[8],
            s.pq_slots_set, s.preferred_slot_set,
        });
    defer alloc.free(tail);
    return std.mem.concat(alloc, u8, &.{ head, middle, tail });
}

// ─── Phase 2 NS — multi-address per name + categories ──────────────────────

/// setpqaddress — owner attaches/clears a specific PQ scheme address slot.
/// Params: { name, tld?, slot ("ml_dsa"|"falcon"|"dilithium"|"slh_dsa" or 0..3),
///           pq_address (empty string to clear), owner }
pub fn handleSetPqAddress(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const name = rpc.extractStr(body, "name") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const tld = rpc.extractStr(body, "tld") orelse rpc.extractArrayStr(body, 1) orelse "omnibus";
    const slot_str = rpc.extractStr(body, "slot") orelse rpc.extractArrayStr(body, 2) orelse
        return rpc.errorJson(-32602, "Missing param: slot (ml_dsa|falcon|dilithium|slh_dsa)", id, alloc);
    const pq_addr = rpc.extractStr(body, "pq_address") orelse rpc.extractArrayStr(body, 3) orelse "";
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractArrayStr(body, 4) orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);

    const slot: dns_mod.PqSlot = blk: {
        if (std.mem.eql(u8, slot_str, "ml_dsa")    or std.mem.eql(u8, slot_str, "obk1") or std.mem.eql(u8, slot_str, "0")) break :blk .ml_dsa;
        if (std.mem.eql(u8, slot_str, "falcon")    or std.mem.eql(u8, slot_str, "obf5") or std.mem.eql(u8, slot_str, "1")) break :blk .falcon;
        if (std.mem.eql(u8, slot_str, "dilithium") or std.mem.eql(u8, slot_str, "obd5") or std.mem.eql(u8, slot_str, "2")) break :blk .dilithium;
        if (std.mem.eql(u8, slot_str, "slh_dsa")   or std.mem.eql(u8, slot_str, "obs3") or std.mem.eql(u8, slot_str, "3")) break :blk .slh_dsa;
        return rpc.errorJson(-32602, "Invalid slot (use ml_dsa|falcon|dilithium|slh_dsa or 0..3)", id, alloc);
    };

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    dns.updatePqAddress(name, tld, owner, slot, pq_addr, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner     => "Not owner of this name",
            error.AddrTooLong  => "PQ address exceeds 64 chars",
        };
        return rpc.errorJson(-32030, msg, id, alloc);
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"slot\":\"{s}\",\"pq_address\":\"{s}\",\"updated\":true}}}}",
        .{ id, name, tld, slot_str, pq_addr });
}

/// setcategory — owner assigns a category badge to their name.
/// Params: { name, tld?, category ("personal"|"bank"|...), owner }
pub fn handleSetCategory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const name = rpc.extractStr(body, "name") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const tld = rpc.extractStr(body, "tld") orelse rpc.extractArrayStr(body, 1) orelse "omnibus";
    const cat_str = rpc.extractStr(body, "category") orelse rpc.extractArrayStr(body, 2) orelse
        return rpc.errorJson(-32602, "Missing param: category", id, alloc);
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractArrayStr(body, 3) orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);

    const cat: dns_mod.Category = blk: {
        if (std.mem.eql(u8, cat_str, "personal")) break :blk .personal;
        if (std.mem.eql(u8, cat_str, "bank"))     break :blk .bank;
        if (std.mem.eql(u8, cat_str, "gov"))      break :blk .gov;
        if (std.mem.eql(u8, cat_str, "mil"))      break :blk .mil;
        if (std.mem.eql(u8, cat_str, "fin"))      break :blk .fin;
        if (std.mem.eql(u8, cat_str, "edu"))      break :blk .edu;
        if (std.mem.eql(u8, cat_str, "org"))      break :blk .org;
        if (std.mem.eql(u8, cat_str, "dev"))      break :blk .dev;
        if (std.mem.eql(u8, cat_str, "trading"))  break :blk .trading;
        if (std.mem.eql(u8, cat_str, "none"))     break :blk .none;
        return rpc.errorJson(-32602, "Invalid category (use personal|bank|gov|mil|fin|edu|org|dev|trading|none)", id, alloc);
    };

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    dns.updateCategory(name, tld, owner, cat, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner     => "Not owner of this name",
        };
        return rpc.errorJson(-32030, msg, id, alloc);
    };
    {
        const scat_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(scat_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"category\":\"{s}\",\"updated\":true}}}}",
            .{ id, scat_safe, tld, cat.toString() });
    }
}

/// setpreferredslot — owner sets which scheme they want funds delivered to by default.
/// Params: { name, tld?, slot (0=primary, 1=ml_dsa, 2=falcon, 3=dilithium, 4=slh_dsa), owner }
pub fn handleSetPreferredSlot(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const name = rpc.extractStr(body, "name") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const tld = rpc.extractStr(body, "tld") orelse rpc.extractArrayStr(body, 1) orelse "omnibus";
    const slot_raw = rpc.extractArrayNumByKey(body, "slot");
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractArrayStr(body, 3) orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);

    if (slot_raw > 4) return rpc.errorJson(-32602, "Invalid slot (0=primary, 1..4=PQ)", id, alloc);
    const slot_idx: u8 = @intCast(slot_raw);
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    dns.updatePreferredSlot(name, tld, owner, slot_idx, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner     => "Not owner of this name",
            error.InvalidSlot  => "Invalid slot",
        };
        return rpc.errorJson(-32030, msg, id, alloc);
    };
    {
        const sps_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(sps_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"preferred_slot\":{d},\"updated\":true}}}}",
            .{ id, sps_safe, tld, slot_idx });
    }
}

/// getnamesbycategory — list all names with a given category badge.
/// Params: { category ("bank"|"gov"|...), limit? }
pub fn handleGetNamesByCategory(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const cat_str = rpc.extractStr(body, "category") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: category", id, alloc);
    const limit_raw = rpc.extractArrayNumByKey(body, "limit");
    const limit: usize = if (limit_raw > 0 and limit_raw <= 200) @intCast(limit_raw) else 50;

    const cat: dns_mod.Category = blk: {
        if (std.mem.eql(u8, cat_str, "personal")) break :blk .personal;
        if (std.mem.eql(u8, cat_str, "bank"))     break :blk .bank;
        if (std.mem.eql(u8, cat_str, "gov"))      break :blk .gov;
        if (std.mem.eql(u8, cat_str, "mil"))      break :blk .mil;
        if (std.mem.eql(u8, cat_str, "fin"))      break :blk .fin;
        if (std.mem.eql(u8, cat_str, "edu"))      break :blk .edu;
        if (std.mem.eql(u8, cat_str, "org"))      break :blk .org;
        if (std.mem.eql(u8, cat_str, "dev"))      break :blk .dev;
        if (std.mem.eql(u8, cat_str, "trading"))  break :blk .trading;
        return rpc.errorJson(-32602, "Invalid category", id, alloc);
    };

    var buf: [200]*const dns_mod.DnsEntry = undefined;
    const slice = buf[0..@min(limit, buf.len)];
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const found = dns.listByCategory(cat, slice, current_block);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    const gncw = out.writer(alloc);
    try std.fmt.format(gncw,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"category\":\"{s}\",\"total\":{d},\"entries\":[",
        .{ id, cat.toString(), found });
    var i: usize = 0;
    while (i < found) : (i += 1) {
        const e = slice[i];
        if (i > 0) try gncw.writeByte(',');
        try gncw.writeAll("{\"name\":\"");
        try rpc.writeJsonSafeStr(gncw, e.getName());
        try std.fmt.format(gncw,
            "\",\"tld\":\"{s}\",\"address\":\"{s}\",\"preferred_slot\":{d},\"registeredAtBlock\":{d}}}",
            .{ e.getTld(), e.getAddress(), e.preferred_slot, e.registered_block });
    }
    try gncw.writeAll("]}}");
    return alloc.dupe(u8, out.items);
}

// ─── Phase 1: transfername ──────────────────────────────────────────────────
pub fn handleTransferName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = rpc.extractStr(body, "name") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const tld = rpc.extractStr(body, "tld") orelse rpc.extractArrayStr(body, 1) orelse "omnibus";
    const new_owner = rpc.extractStr(body, "new_owner") orelse rpc.extractArrayStr(body, 2) orelse
        return rpc.errorJson(-32602, "Missing param: new_owner", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    const sig_hex = rpc.extractStr(body, "signature") orelse "";
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse "";

    const entry = dns.lookupEntry(name, tld) orelse
        return rpc.errorJson(-32400, "Name not found", id, alloc);
    const owner = entry.getOwner();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);

    // Signature check
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required and !is_hmac_bypass) {
        if (sig_hex.len == 0 or pubkey_hex.len == 0) {
            return rpc.errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        var msg_buf: [512]u8 = undefined;
        const msg = rpc.buildDnsTransferSignMessage(name, tld, new_owner, nonce, &msg_buf) catch
            return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!rpc.verifyDnsSignature(msg, sig_hex, pubkey_hex, owner, alloc)) {
            return rpc.errorJson(-32401, "Signing pubkey does not match current owner", id, alloc);
        }
    }

    // Nonce replay protection
    if (nonce <= entry.last_nonce) {
        return rpc.errorJson(-32402, "Nonce too low (replay rejected)", id, alloc);
    }

    const old_address = entry.getAddress();
    dns.transfer(name, tld, owner, old_address, new_owner, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner => "Not owner",
            error.OwnerCapExceeded => "Per-owner name cap exceeded for new_owner",
        };
        return rpc.errorJson(-32031, msg, id, alloc);
    };
    entry.last_nonce = nonce;

    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"old_owner\":\"{s}\",\"new_owner\":\"{s}\",\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\"",
        .{ name, tld, owner, new_owner, nonce, pubkey_hex, sig_hex }) catch "";
    if (audit_fields.len > 0) rpc.dnsAuditAppend(ctx, "transfer", audit_fields);

    {
        const tn_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(tn_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"old_owner\":\"{s}\",\"new_owner\":\"{s}\",\"transferredAtBlock\":{d}}}}}",
            .{ id, tn_safe, tld, owner, new_owner, current_block });
    }
}

// ─── Phase 1: updatename ────────────────────────────────────────────────────
pub fn handleUpdateName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = rpc.extractStr(body, "name") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const tld = rpc.extractStr(body, "tld") orelse rpc.extractArrayStr(body, 1) orelse "omnibus";
    const new_address = rpc.extractStr(body, "new_address") orelse rpc.extractArrayStr(body, 2) orelse
        return rpc.errorJson(-32602, "Missing param: new_address", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    const sig_hex = rpc.extractStr(body, "signature") orelse "";
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse "";

    const entry = dns.lookupEntry(name, tld) orelse
        return rpc.errorJson(-32400, "Name not found", id, alloc);
    const owner = entry.getOwner();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const old_address = entry.getAddress();

    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required and !is_hmac_bypass) {
        if (sig_hex.len == 0 or pubkey_hex.len == 0) {
            return rpc.errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        var msg_buf: [512]u8 = undefined;
        const msg = rpc.buildDnsUpdateSignMessage(name, tld, new_address, nonce, &msg_buf) catch
            return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!rpc.verifyDnsSignature(msg, sig_hex, pubkey_hex, owner, alloc)) {
            return rpc.errorJson(-32401, "Signing pubkey does not match current owner", id, alloc);
        }
    }

    if (nonce <= entry.last_nonce) {
        return rpc.errorJson(-32402, "Nonce too low (replay rejected)", id, alloc);
    }

    dns.updateAddress(name, tld, owner, new_address, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound => "Name not found",
            error.NotOwner => "Not owner",
        };
        return rpc.errorJson(-32031, msg, id, alloc);
    };
    entry.last_nonce = nonce;

    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"old_address\":\"{s}\",\"new_address\":\"{s}\",\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\"",
        .{ name, tld, old_address, new_address, nonce, pubkey_hex, sig_hex }) catch "";
    if (audit_fields.len > 0) rpc.dnsAuditAppend(ctx, "update", audit_fields);

    {
        const un_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(un_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"old_address\":\"{s}\",\"new_address\":\"{s}\",\"updatedAtBlock\":{d}}}}}",
            .{ id, un_safe, tld, old_address, new_address, current_block });
    }
}

// ─── Phase 1+2: renewname ───────────────────────────────────────────────────
//
// Phase 2 contract — params (positional or keyed):
//   name, tld?, owner_address?, fee_txid?, {years, nonce, signature, publicKey}
//
// `years` is the additional years to add (1, 2, 3, 4, 5, 10, 25, 50, 100).
// Default 1 for backward compatibility with Phase 1 callers.
//
// The signing message is V2 when years is supplied (embeds years to prevent
// cross-tier replay). Phase 1 V1 callers (no years key, signed_required off)
// still work — we fall back to renewWithYears(1y) and do NOT verify a V2 sig.
pub fn handleRenewName(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const name = rpc.extractStr(body, "name") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: name", id, alloc);
    const tld = rpc.extractStr(body, "tld") orelse rpc.extractArrayStr(body, 1) orelse "omnibus";
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    const sig_hex = rpc.extractStr(body, "signature") orelse "";
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse "";
    const fee_txid = rpc.extractStr(body, "fee_txid") orelse null;
    // Phase 2: years tier (default 1 for V1 compat).
    const years_raw = rpc.extractArrayNumByKey(body, "years");
    const years: u32 = if (years_raw == 0) 1 else @intCast(@min(years_raw, dns_mod.MAX_REGISTRATION_YEARS));
    if (!dns_mod.isValidYears(years)) {
        return rpc.errorJson(-32602, "Invalid years (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)", id, alloc);
    }

    const entry = dns.lookupEntry(name, tld) orelse
        return rpc.errorJson(-32400, "Name not found", id, alloc);
    const owner = entry.getOwner();
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const old_expires = entry.expires_block;
    const old_years = entry.registered_years;

    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (dns.signed_required and !is_hmac_bypass) {
        if (sig_hex.len == 0 or pubkey_hex.len == 0) {
            return rpc.errorJson(-32602, "signature and publicKey required (signed mode)", id, alloc);
        }
        var msg_buf: [512]u8 = undefined;
        // V2 signing message embeds years; V1 message kept for legacy callers
        // that don't pass `years` (defaulted to 1). We try V2 first; if it
        // fails AND years==1, fall back to V1 to keep Phase 1 clients alive.
        const msg_v2 = rpc.buildDnsRenewYearsSignMessage(name, tld, years, nonce, &msg_buf) catch
            return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
        var ok = rpc.verifyDnsSignature(msg_v2, sig_hex, pubkey_hex, owner, alloc);
        if (!ok and years == 1) {
            var legacy_buf: [512]u8 = undefined;
            const msg_v1 = rpc.buildDnsRenewSignMessage(name, tld, nonce, &legacy_buf) catch
                return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
            ok = rpc.verifyDnsSignature(msg_v1, sig_hex, pubkey_hex, owner, alloc);
        }
        if (!ok) {
            return rpc.errorJson(-32401, "Signing pubkey does not match current owner", id, alloc);
        }
    }

    if (nonce <= entry.last_nonce) {
        return rpc.errorJson(-32402, "Nonce too low (replay rejected)", id, alloc);
    }

    // Fee enforcement for renewal — Phase 2: scales with `years` via the
    // same multiplier curve as registration. 100y renew costs ~55× base,
    // not 100× (long-term commitment discount).
    const required_fee = dns_mod.feeForRenewal(name, tld, years);
    if (dns.fee_enforcement) {
        const txid = fee_txid orelse
            return rpc.errorJson(-32602, "fee_txid required (mainnet)", id, alloc);
        if (txid.len != dns_mod.TXID_LEN) {
            return rpc.errorJson(-32031, "fee TX invalid: txid must be 64 hex chars", id, alloc);
        }
        if (dns.isTxidConsumed(txid)) {
            return rpc.errorJson(-32031, "fee TX invalid: txid already used", id, alloc);
        }
        var found_tx: ?*const transaction_mod.Transaction = null;
        ctx.bc.mutex.lock();
        for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |*tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    break;
                }
            }
            if (found_tx != null) break;
        }
        ctx.bc.mutex.unlock();
        const tx = found_tx orelse
            return rpc.errorJson(-32031, "fee TX invalid: transaction not found in chain", id, alloc);
        const treasury = dns.getTreasury();
        if (!std.mem.eql(u8, tx.to_address, treasury)) {
            return rpc.errorJson(-32031, "fee TX invalid: destination is not treasury", id, alloc);
        }
        if (tx.amount < required_fee) {
            return rpc.errorJson(-32031, "fee TX invalid: amount too low", id, alloc);
        }
        dns.consumeTxid(txid) catch |err| {
            const msg: []const u8 = switch (err) {
                error.InvalidTxid => "Invalid txid",
                error.ConsumedTxidsFull => "Consumed txids full",
            };
            return rpc.errorJson(-32031, msg, id, alloc);
        };
    }

    dns.renewWithYears(name, tld, owner, years, current_block) catch |err| {
        const msg: []const u8 = switch (err) {
            error.NameNotFound      => "Name not found",
            error.NotOwner          => "Not owner",
            error.InvalidYears      => "Invalid years tier (allowed: 1, 2, 3, 4, 5, 10, 25, 50, 100)",
            error.YearsCapExceeded  => "Cumulative registered_years would exceed 100 (hard cap)",
        };
        return rpc.errorJson(-32031, msg, id, alloc);
    };
    entry.last_nonce = nonce;

    const fee_paid_sat: u64 = if (fee_txid) |_| required_fee else 0;
    const fee_txid_esc = fee_txid orelse "";

    var audit_buf: [1024]u8 = undefined;
    const audit_fields = std.fmt.bufPrint(&audit_buf,
        "\"name\":\"{s}\",\"tld\":\"{s}\",\"added_years\":{d},\"old_years\":{d},\"new_years\":{d},\"old_expires_block\":{d},\"new_expires_block\":{d},\"nonce\":{d},\"signer_pubkey\":\"{s}\",\"signature\":\"{s}\",\"fee_paid_sat\":{d},\"fee_txid\":\"{s}\"",
        .{ name, tld, years, old_years, entry.registered_years, old_expires, entry.expires_block, nonce, pubkey_hex, sig_hex, fee_paid_sat, fee_txid_esc }) catch "";
    if (audit_fields.len > 0) rpc.dnsAuditAppend(ctx, "renew", audit_fields);

    // WS push — UI updates the expiry pill on the renewed name.
    if (main_mod.g_ws_srv) |ws| {
        ws.broadcastNameRenewed(name, tld, owner, @intCast(@min(years, 255)));
    }

    {
        const ren_safe = try rpc.jsonSanitize(alloc, name);
        defer alloc.free(ren_safe);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"name\":\"{s}\",\"tld\":\"{s}\",\"added_years\":{d},\"registered_years\":{d},\"old_expires_block\":{d},\"new_expires_block\":{d},\"fee_paid_sat\":{d}}}}}",
            .{ id, ren_safe, tld, years, entry.registered_years, old_expires, entry.expires_block, fee_paid_sat });
    }
}

// ─── Phase 2: ns_expiringSoon ───────────────────────────────────────────────
//
// Lifecycle UI helper. Given an owner address, returns names that expire
// within `blocks_threshold` blocks (default = 30 days = 30*86400/10 = 259200
// at the canonical 10s block time). The frontend uses this for the warning
// badge on the WalletConnect pill + the per-row "expires in N days" label.
//
// Params (positional or keyed):
//   address: string         — owner wallet (ob1q…). Required.
//   blocks_threshold?: u64  — default 259200.
//
// Result:
//   {
//     address, current_block, blocks_threshold,
//     entries: [
//       { name, tld, fullLabel, expiresAtBlock, blocks_remaining,
//         estimated_days_remaining, registered_years, in_grace }
//     ]
//   }
//
// Note: `blocks_remaining` is signed conceptually but JSON-emitted unsigned;
// when the entry is in grace, it's reported as 0 and `in_grace: true`.
pub fn handleNsExpiringSoon(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;

    const address = rpc.extractStr(body, "address") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    // Default ~30 days at 10s block time = 259200 blocks.
    const DEFAULT_THRESHOLD_BLOCKS: u64 = 259_200;
    const t_raw = rpc.extractArrayNumByKey(body, "blocks_threshold");
    const blocks_threshold: u64 = if (t_raw == 0) DEFAULT_THRESHOLD_BLOCKS else t_raw;

    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    var buf: [dns_mod.MAX_NAMES_PER_OWNER]*const dns_mod.DnsEntry = undefined;
    const n = dns.getExpiringNames(address, current_block, blocks_threshold, &buf);

    // Build JSON result. ~512B per entry is plenty.
    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    const w = out.writer();
    try std.fmt.format(w,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"current_block\":{d},\"blocks_threshold\":{d},\"entries\":[",
        .{ id, address, current_block, blocks_threshold });
    for (buf[0..n], 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        const tld_s = e.getTld();
        const in_grace = e.isInGrace(current_block);
        const remaining: u64 = if (in_grace or e.expires_block <= current_block)
            0
        else
            e.expires_block - current_block;
        // 10s/block, so days = remaining / (86400/10) = remaining / 8640
        const est_days: u64 = remaining / 8640;
        try w.writeAll("{\"name\":\"");
        try rpc.writeJsonSafeStr(w, e.getName());
        try std.fmt.format(w, "\",\"tld\":\"{s}\",\"fullLabel\":\"", .{tld_s});
        try rpc.writeJsonSafeStr(w, e.getName());
        try std.fmt.format(w,
            ".{s}\",\"expiresAtBlock\":{d},\"blocks_remaining\":{d},\"estimated_days_remaining\":{d},\"registered_years\":{d},\"in_grace\":{}}}",
            .{ tld_s, e.expires_block, remaining, est_days, e.registered_years, in_grace });
    }
    try w.writeAll("]}}");
    return out.toOwnedSlice();
}

// ─── Phase 2: ns_pruneExpired ───────────────────────────────────────────────
//
// Admin / maintenance RPC. Drops every entry whose grace period has fully
// elapsed (truly auctionable + abandoned). Returns the number removed and
// the new entry_count. Not auto-called; main.zig invokes it once at startup
// and (optionally) every N blocks during mining.
//
// Result: { removed: u64, entry_count: u64, current_block: u64 }
pub fn handleNsPruneExpired(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.dns == null) return rpc.errorJson(-32030, "DNS registry not enabled on this node", id, alloc);
    const dns = ctx.dns.?;
    const current_block: u64 = @intCast(ctx.bc.chain.items.len);
    const removed = dns.pruneExpiredNames(current_block);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"removed\":{d},\"entry_count\":{d},\"current_block\":{d}}}}}",
        .{ id, removed, dns.entry_count, current_block });
}

// ─── Unresolved file-private symbols from rpc_server.zig ────────────────────
// These are referenced above and must be made `pub` in rpc_server.zig (or moved):
//   - extractArrayNumByKey (rpc_server.zig:5961)
//   - buildDnsRegisterSignMessage (rpc_server.zig:10982)
//   - buildDnsTransferSignMessage (rpc_server.zig:10995)
//   - buildDnsUpdateSignMessage   (rpc_server.zig:11007)
//   - buildDnsRenewSignMessage    (rpc_server.zig:11019)
//   - buildDnsRenewYearsSignMessage (rpc_server.zig:11033)
//   - verifyDnsSignature          (rpc_server.zig:11047)
//   - dnsAuditAppend              (rpc_server.zig:11080)
//
// Also referenced module-locals: transaction_mod, main_mod (already imported
// at top of rpc_server.zig — when split out, these need explicit @import here).
const transaction_mod = @import("../transaction.zig");
const main_mod = @import("../main.zig");
