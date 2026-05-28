// Identity JSON-RPC handlers — DID, OBM, KYC, reputation, profile,
// MiCA, selective disclosure.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const identity_mod = @import("../identity.zig");
const kyc_mod = @import("../kyc.zig");
const reputation_mod = @import("../reputation.zig");
const reputation_manager_mod = @import("../reputation_manager.zig");
const id_layer_mod = @import("../identity/identity.zig");

const main_mod = @import("../main.zig");
const hex_utils = @import("../hex_utils.zig");
const bech32_mod = @import("../bech32.zig");
const notarize_mod = @import("../notarize.zig");
const escrow_mod = @import("../escrow.zig");

const ServerCtx = rpc.ServerCtx;

/// RPC `getdid` — returns `did:omnibus:<base58(sha256(h160))>` for an address.
pub fn handleGetDid(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    // Recover the 20-byte hash160 from the bech32 address.
    const decoded = bech32_mod.decodeWitnessAddress(bech32_mod.OB_HRP, addr, alloc) catch
        return rpc.errorJson(-32602, "Invalid bech32 address", id, alloc);
    defer alloc.free(decoded.program);
    if (decoded.program.len != 20) return rpc.errorJson(-32602, "Address is not P2WPKH-equivalent", id, alloc);
    var h160: [20]u8 = undefined;
    @memcpy(&h160, decoded.program);

    const did = try id_layer_mod.did.didFromHash160(h160, alloc);
    defer alloc.free(did);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"did\":\"{s}\"}}}}",
        .{ id, addr, did });
}

/// RPC `getobm` — 1-byte OmniBus Binary Map for an address, with each bit
/// also surfaced as a named boolean so clients don't have to decode it.
pub fn handleGetObm(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const cups = blk: {
        if (main_mod.g_reputation != null) {
            if (main_mod.g_reputation.?.snapshot(addr)) |c| break :blk c;
        }
        break :blk @import("../reputation.zig").ReputationCups{};
    };

    // Validator = stake_amounts >= 100 OMNI. Same threshold as getvalidators.
    var is_validator = false;
    {
        ctx.bc.mutex.lock();
        defer ctx.bc.mutex.unlock();
        if (ctx.bc.stake_amounts.get(addr)) |amt| {
            if (amt / 1_000_000_000 >= 100) is_validator = true;
        }
    }

    // DNS-name flag: we don't iterate the whole registry here (potentially
    // expensive). The flag stays false unless a future indexer exposes a
    // per-owner count. Conservative on purpose.
    const has_dns_name = false;
    // PQ-key flag: chain does not yet maintain a per-address PQ registry,
    // so we leave the bit dark. Will flip true once pq_attest indexes it.
    const has_pq_key = false;

    const obm_byte = id_layer_mod.obm.compute(.{
        .cups = cups,
        .has_pq_key = has_pq_key,
        .has_dns_name = has_dns_name,
        .is_validator = is_validator,
    });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"obm\":{d},\"love_badge\":{},\"food_badge\":{},\"rent_badge\":{},\"vacation_badge\":{},\"has_pq_key\":{},\"has_dns_name\":{},\"is_validator\":{},\"is_zen_tier\":{}}}}}",
        .{
            id, addr, obm_byte,
            id_layer_mod.obm.has(obm_byte, .love_badge),
            id_layer_mod.obm.has(obm_byte, .food_badge),
            id_layer_mod.obm.has(obm_byte, .rent_badge),
            id_layer_mod.obm.has(obm_byte, .vacation_badge),
            id_layer_mod.obm.has(obm_byte, .has_pq_key),
            id_layer_mod.obm.has(obm_byte, .has_dns_name),
            id_layer_mod.obm.has(obm_byte, .is_validator),
            id_layer_mod.obm.has(obm_byte, .is_zen_tier),
        });
}

/// RPC `getfacets <addr>` — returns which OmniBus ID facets (Social,
/// Professional, Cultural) the holder has populated.
///
/// Facet roots themselves live off-chain in the holder's vault — chain
/// only sees them when explicitly anchored via a manifest_anchor TX. Until
/// that endpoint exists, this RPC reports which facets the chain has
/// derivable evidence for: social=true if the address has follows on chain,
/// professional=true if it has any kyc_attest entries (treated as cert
/// proxies for now), cultural=true if it has POAPs.
///
/// This is intentionally conservative — false negatives are expected for
/// holders who keep everything off-chain. Only true positives are reliable.
pub fn handleGetFacets(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    // Resolve h160 so we can look up the rpc.ProfileStore entry.
    const h160_opt: ?[20]u8 = rpc.addrToH160(addr, alloc) catch null;

    // Per-facet results: populated flag + root hex string (64 hex chars or empty).
    const FacetResult = struct {
        populated: bool,
        root_hex: [64]u8,
        root_hex_len: usize,
    };
    var results: [4]FacetResult = .{
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
        .{ .populated = false, .root_hex = undefined, .root_hex_len = 0 },
    };

    if (h160_opt) |h160| {
        const store = rpc.getProfileStore(alloc);
        store.mutex.lock();
        defer store.mutex.unlock();
        if (store.get(h160)) |entry| {
            for (&results, 0..) |*r, i| {
                const facet = &entry.facets[i];
                if (facet.fields.count() > 0) {
                    const root = rpc.computeFacetRoot(facet, alloc) catch continue;
                    const hex_chars = "0123456789abcdef";
                    for (root, 0..) |b, bi| {
                        r.root_hex[bi * 2]     = hex_chars[b >> 4];
                        r.root_hex[bi * 2 + 1] = hex_chars[b & 0x0f];
                    }
                    r.root_hex_len = 64;
                    r.populated = true;
                }
            }
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\"," ++
        "\"social\":{{\"populated\":{},\"root_hex\":\"{s}\"}}," ++
        "\"professional\":{{\"populated\":{},\"root_hex\":\"{s}\"}}," ++
        "\"cultural\":{{\"populated\":{},\"root_hex\":\"{s}\"}}," ++
        "\"economic\":{{\"populated\":{},\"root_hex\":\"{s}\"}}}}}}",
        .{
            id, addr,
            results[0].populated, results[0].root_hex[0..results[0].root_hex_len],
            results[1].populated, results[1].root_hex[0..results[1].root_hex_len],
            results[2].populated, results[2].root_hex[0..results[2].root_hex_len],
            results[3].populated, results[3].root_hex[0..results[3].root_hex_len],
        });
}

/// RPC `getreputation` — citeste paharele LOVE/FOOD/RENT/VACATION pentru o
/// adresa, plus rep total agregat (0-1M) si tier (OMNI/LOVE/FOOD/RENT/VACATION).
/// Vezi memory/project_omnibus_reputation_economy.md pentru rationale.
///
/// Body: {"address": "ob1q..."}
/// Răspuns: { "address", "cups": {love, food, rent, vacation}, "total",
///           "tier", "satoshi_badge", "first_active_block", "last_active_block",
///           "total_blocks_mined", "violations" }
pub fn handleGetReputation(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    if (main_mod.g_reputation == null) {
        return rpc.errorJson(-32030, "Reputation system not enabled on this node", id, alloc);
    }
    const cups = main_mod.g_reputation.?.snapshot(addr) orelse {
        // Address never seen — return zero cups (still valid response).
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"cups\":{{\"love\":\"0.00\",\"food\":\"0.00\",\"rent\":\"0.00\",\"vacation\":\"0.00\"}},\"total\":0,\"tier\":\"OMNI\",\"satoshi_badge\":false,\"first_active_block\":0,\"last_active_block\":0,\"total_blocks_mined\":0,\"violations\":0}}}}",
            .{ id, addr });
    };
    const total = cups.computeRepTotal();
    const tier = cups.tier();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"cups\":{{\"love\":\"{d}.{d:0>2}\",\"food\":\"{d}.{d:0>2}\",\"rent\":\"{d}.{d:0>2}\",\"vacation\":\"{d}.{d:0>2}\"}},\"total\":{d},\"tier\":\"{s}\",\"satoshi_badge\":{},\"is_zen\":{},\"first_active_block\":{d},\"last_active_block\":{d},\"uptime_blocks\":{d},\"total_blocks_mined\":{d},\"violations\":{d}}}}}",
        .{
            id, addr,
            cups.love_stored / 100, cups.love_stored % 100,
            cups.food_stored / 100, cups.food_stored % 100,
            cups.rent_stored / 100, cups.rent_stored % 100,
            cups.vacation_stored / 100, cups.vacation_stored % 100,
            total,
            tier.name(),
            cups.hasSatoshiBadge(),
            cups.hasSatoshiBadge(),
            cups.first_active_block,
            cups.last_active_block,
            cups.uptimeBlocks(),
            cups.total_blocks_mined,
            cups.violations,
        },
    );
}

/// RPC `getreputationtop` — top N adrese sortate după reputation total descendent.
/// Body: {"limit": 50}  (default 50, max 200)
pub fn handleGetReputationTop(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (main_mod.g_reputation == null) {
        return rpc.errorJson(-32030, "Reputation system not enabled on this node", id, alloc);
    }
    var limit: u32 = 50;
    if (rpc.extractStr(body, "limit")) |s| {
        limit = std.fmt.parseInt(u32, s, 10) catch 50;
    }
    if (limit == 0) limit = 50;
    if (limit > 200) limit = 200;

    const Entry = struct {
        addr: []const u8,
        total: u64,
        tier: []const u8,
        love: u32,
        food: u32,
        rent: u32,
        vacation: u32,
        satoshi: bool,
        blocks_mined: u64,
        first_block: u64,
        uptime_blocks: u64,
        rank_score: u128,
    };

    const rep = &main_mod.g_reputation.?;
    rep.lock();
    defer rep.unlock();

    var entries = std.array_list.Managed(Entry).init(alloc);
    defer entries.deinit();

    var it = rep.iterate();
    while (it.next()) |kv| {
        const total = kv.value_ptr.computeRepTotal();
        if (total == 0 and kv.value_ptr.total_blocks_mined == 0) continue;
        try entries.append(.{
            .addr = kv.key_ptr.*,
            .total = total,
            .tier = kv.value_ptr.tier().name(),
            .love = kv.value_ptr.love_stored,
            .food = kv.value_ptr.food_stored,
            .rent = kv.value_ptr.rent_stored,
            .vacation = kv.value_ptr.vacation_stored,
            .satoshi = kv.value_ptr.hasSatoshiBadge(),
            .blocks_mined = kv.value_ptr.total_blocks_mined,
            .first_block = kv.value_ptr.first_active_block,
            .uptime_blocks = kv.value_ptr.uptimeBlocks(),
            .rank_score = kv.value_ptr.rankScore(),
        });
    }

    // Sort by rank_score descending — Zen-i automat sus, intre Zen-i tiebreaker
    // = uptime_blocks (incorporat in rank_score). Intre non-Zen: rep_total.
    std.sort.insertion(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.rank_score > b.rank_score;
        }
    }.less);

    const cap_n: usize = if (entries.items.len < limit) entries.items.len else limit;

    var buf = std.array_list.Managed(u8).init(alloc);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"count\":{d},\"total\":{d},\"entries\":[",
        .{ id, cap_n, entries.items.len },
    );
    for (entries.items[0..cap_n], 0..) |e, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.print(
            "{{\"rank\":{d},\"address\":\"{s}\",\"total\":{d},\"tier\":\"{s}\",\"cups\":{{\"love\":\"{d}.{d:0>2}\",\"food\":\"{d}.{d:0>2}\",\"rent\":\"{d}.{d:0>2}\",\"vacation\":\"{d}.{d:0>2}\"}},\"satoshi_badge\":{},\"is_zen\":{},\"blocks_mined\":{d},\"first_active_block\":{d},\"uptime_blocks\":{d}}}",
            .{
                idx + 1,
                e.addr,
                e.total,
                e.tier,
                e.love / 100, e.love % 100,
                e.food / 100, e.food % 100,
                e.rent / 100, e.rent % 100,
                e.vacation / 100, e.vacation % 100,
                e.satoshi,
                e.satoshi, // is_zen alias for clarity in UI
                e.blocks_mined,
                e.first_block,
                e.uptime_blocks,
            },
        );
    }
    try w.writeAll("]}}");
    return buf.toOwnedSlice();
}

pub fn handleIdentitySet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.identity_store orelse
        return rpc.errorJson(-32601, "Identity store not initialized", id, alloc);

    const address = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const nickname = rpc.extractStr(body, "nickname") orelse "";
    const ens = rpc.extractStr(body, "ens") orelse rpc.extractStr(body, "ensPrimary") orelse "";
    const visibility_str = rpc.extractStr(body, "visibility") orelse "public";
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    if (nickname.len > identity_mod.NICKNAME_MAX) {
        return rpc.errorJson(-32602, "nickname too long (max 32)", id, alloc);
    }
    if (ens.len > identity_mod.ENS_MAX) {
        return rpc.errorJson(-32602, "ens too long (max 64)", id, alloc);
    }

    // Build canonical message and verify signature.
    var msg_buf: [256]u8 = undefined;
    const msg = rpc.buildIdentitySignMessage(&msg_buf, address, nickname, ens, visibility_str, nonce) catch
        return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived);
    if (!std.mem.eql(u8, derived, address)) {
        return rpc.errorJson(-32000, "Public key does not match address", id, alloc);
    }

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    // Reuse exchange nonce table — they live in the same context. New
    // nonce must be strictly greater than last seen for this address.
    const last_nonce = rpc.nonceLookup(ctx, address);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used", id, alloc);
    }
    rpc.nonceSet(ctx, address, nonce);

    const visibility = identity_mod.Visibility.fromStr(visibility_str);
    store.upsert(address, nickname, ens, visibility, std.time.milliTimestamp(), true) catch |err| {
        return rpc.errorJson(-32000, switch (err) {
            error.NicknameNotPrintable => "Nickname must be printable ASCII (no quotes/control/unicode)",
            error.NicknameTooLong => "Nickname too long",
            error.EnsTooLong => "ENS too long",
            error.StoreFull => "Identity store full",
            error.BadAddress => "Bad address",
        }, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\",\"updated\":true}}}}",
        .{ id, address, nickname, ens, visibility.toStr() });
}

pub fn handleIdentityGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.identity_store orelse
        return rpc.errorJson(-32601, "Identity store not initialized", id, alloc);
    const address = rpc.extractStr(body, "address") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    // `respect_visibility=true` so private addresses return null.
    const it = store.lookup(address, true) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
            .{id});
    };

    // For ens_only visibility, blank the nickname so the UI doesn't even
    // see it. Address is already public on chain anyway.
    const nick: []const u8 = if (it.visibility == .ens_only) "" else it.getNickname();
    const nick_safe = try rpc.jsonSanitize(alloc, nick);
    defer alloc.free(nick_safe);
    const ens_safe = try rpc.jsonSanitize(alloc, it.getEns());
    defer alloc.free(ens_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\",\"updated\":{d}}}}}",
        .{ id, it.getAddress(), nick_safe, ens_safe, it.visibility.toStr(), it.updated_ms });
}

pub fn handleIdentitySearch(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.identity_store orelse
        return rpc.errorJson(-32601, "Identity store not initialized", id, alloc);
    const prefix = rpc.extractStr(body, "prefix") orelse rpc.extractArrayStr(body, 0) orelse "";
    const limit_raw = rpc.extractArrayNumByKey(body, "limit");
    const limit: u32 = if (limit_raw == 0) 25 else @intCast(@min(limit_raw, @as(u64, 100)));

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");
    var first = true;
    var emitted: u32 = 0;
    var i: u16 = 0;
    while (i < store.count and emitted < limit) : (i += 1) {
        const it = &store.items[i];
        if (it.visibility == .private) continue;
        const nick = it.getNickname();
        if (prefix.len > 0) {
            const nlower = nick;
            if (nlower.len < prefix.len) continue;
            if (!std.ascii.startsWithIgnoreCase(nlower, prefix)) continue;
        }
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        const visible_nick: []const u8 = if (it.visibility == .ens_only) "" else nick;
        const vnick_safe = try rpc.jsonSanitize(alloc, visible_nick);
        defer alloc.free(vnick_safe);
        const vens_safe = try rpc.jsonSanitize(alloc, it.getEns());
        defer alloc.free(vens_safe);
        try std.fmt.format(out.writer(alloc),
            "{{\"address\":\"{s}\",\"nickname\":\"{s}\",\"ens\":\"{s}\",\"visibility\":\"{s}\"}}",
            .{ it.getAddress(), vnick_safe, vens_safe, it.visibility.toStr() });
        emitted += 1;
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

// ── KYC (signed attestations) ─────────────────────────────────────────

pub fn handleKycGetStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.kyc_store orelse
        return rpc.errorJson(-32601, "KYC store not initialized", id, alloc);
    const address = rpc.extractStr(body, "address") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    const now_ms = std.time.milliTimestamp();
    const att = store.highest(address, now_ms) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"level\":0,\"label\":\"none\"}}}}",
            .{ id, address });
    };
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"level\":{d},\"label\":\"{s}\",\"issuer\":\"{s}\",\"issued\":{d},\"expires\":{d}}}}}",
        .{ id, address, att.level.toU8(), att.level.label(),
           att.getIssuer(), att.issued_ms, att.expires_ms });
}

/// kyc_attest — only callable by the configured KYC issuer (registrar
/// slot 4). The issuer signs the canonical message and submits it; we
/// verify the signature derives to the configured issuer address.
pub fn handleKycAttest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const store = ctx.kyc_store orelse
        return rpc.errorJson(-32601, "KYC store not initialized", id, alloc);
    if (ctx.kyc_issuer_addr_len == 0) {
        return rpc.errorJson(-32601, "KYC issuance disabled on this node", id, alloc);
    }
    const expected_issuer = ctx.kyc_issuer_addr_buf[0..ctx.kyc_issuer_addr_len];

    const target = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address (subject)", id, alloc);
    const level_raw = rpc.extractArrayNumByKey(body, "level");
    const level = kyc_mod.Level.fromU8(@intCast(@min(level_raw, @as(u64, 3))));
    const issued_raw = rpc.extractArrayNumByKey(body, "issued");
    const issued: i64 = if (issued_raw > 0) @intCast(issued_raw) else std.time.milliTimestamp();
    // Default expiry: +1 year if caller didn't pass one.
    const expires_raw = rpc.extractArrayNumByKey(body, "expires");
    const default_expiry: i64 = issued + 365 * 24 * 60 * 60 * 1000;
    const expires: i64 = if (expires_raw > 0) @intCast(expires_raw) else default_expiry;

    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey (issuer)", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = kyc_mod.buildAttestMessage(&msg_buf, target, level, expected_issuer, issued, expires) catch
        return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
    }

    // Verify pubkey -> address derivation matches the configured issuer.
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived);
    if (!std.mem.eql(u8, derived, expected_issuer)) {
        return rpc.errorJson(-32000, "Caller is not the registered KYC issuer", id, alloc);
    }

    ctx.identity_mutex.lock();
    defer ctx.identity_mutex.unlock();

    store.append(target, level, expected_issuer, issued, expires, sig_hex, true) catch |err| {
        return rpc.errorJson(-32000, switch (err) {
            error.StoreFull => "KYC store full",
            error.BadAddress => "Bad subject address",
            error.BadIssuer => "Bad issuer address",
            error.BadSignature => "Bad signature",
        }, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"level\":{d},\"label\":\"{s}\",\"issuer\":\"{s}\",\"issued\":{d},\"expires\":{d}}}}}",
        .{ id, target, level.toU8(), level.label(), expected_issuer, issued, expires });
}

pub fn handleKycListIssuers(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.kyc_issuer_addr_len == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}", .{id});
    }
    const issuer = ctx.kyc_issuer_addr_buf[0..ctx.kyc_issuer_addr_len];
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[{{\"address\":\"{s}\",\"role\":\"kyc.omnibus\",\"slot\":4}}]}}",
        .{ id, issuer });
}

// ── getidentity — Identity Hub aggregator ────────────────────────────────────
// { "address": "ob1q..." }
// Returns a single JSON object with all identity facets for an address.

pub fn handleGetIdentity(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr  = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    // ── 1. PQ identity (pq_attest) ────────────────────────────────────────
    ctx.bc.mutex.lock();
    const identity_opt = ctx.bc.pq_identity_map.get(addr);
    const omni_balance = ctx.bc.balances.get(addr) orelse 0;
    ctx.bc.mutex.unlock();

    var pq_json: []const u8 = "null";
    var pq_json_owned = false;
    if (identity_opt) |idt| {
        pq_json = try std.fmt.allocPrint(alloc,
            "{{\"love\":\"{s}\",\"food\":\"{s}\",\"rent\":\"{s}\"," ++
            "\"vacation\":\"{s}\",\"btc\":\"{s}\",\"eth\":\"{s}\"," ++
            "\"attest_block\":{d}}}",
            .{ idt.loveSlice(), idt.foodSlice(), idt.rentSlice(),
               idt.vacationSlice(), idt.btcSlice(), idt.ethSlice(),
               idt.attest_block });
        pq_json_owned = true;
    }
    defer if (pq_json_owned) alloc.free(pq_json);

    // ── 2. Labels ─────────────────────────────────────────────────────────
    const label_verdict = ctx.bc.label_registry.report(addr).verdictStr();

    // ── 3. Social graph ───────────────────────────────────────────────────
    const followers_n  = ctx.bc.social_graph.followerCount(addr);
    const following_n  = ctx.bc.social_graph.followingCount(addr);

    // ── 4. POAP ───────────────────────────────────────────────────────────
    const poap_n = ctx.bc.poap_registry.claimCountByHolder(addr);

    // ── 5. Notarizations ──────────────────────────────────────────────────
    var note_entries: [64]notarize_mod.NotarizeEntry = undefined;
    const note_count = ctx.bc.notarize_registry.listByOwner(addr, &note_entries);

    // ── 6. Escrow stats ───────────────────────────────────────────────────
    var esc_from_buf: [64]escrow_mod.EscrowEntry = undefined;
    var esc_to_buf:   [64]escrow_mod.EscrowEntry = undefined;
    const esc_sent = ctx.bc.escrow_registry.listByFrom(addr, &esc_from_buf);
    const esc_recv = ctx.bc.escrow_registry.listByTo(addr, &esc_to_buf);

    // ── 7. Reputation ─────────────────────────────────────────────────────
    var rep_json: []const u8 = "null";
    var rep_json_owned = false;
    if (main_mod.g_reputation) |*rep_ptr| {
        if (rep_ptr.snapshot(addr)) |cups| {
            const total = cups.computeRepTotal();
            rep_json = try std.fmt.allocPrint(alloc,
                "{{\"love\":{d},\"food\":{d},\"rent\":{d},\"vacation\":{d}," ++
                "\"total\":{d},\"tier\":\"{s}\",\"satoshi_badge\":{}}}",
                .{ cups.love_stored, cups.food_stored,
                   cups.rent_stored, cups.vacation_stored,
                   total, cups.tier().name(), cups.hasSatoshiBadge() });
            rep_json_owned = true;
        }
    }
    defer if (rep_json_owned) alloc.free(rep_json);

    // ── 8. Active governance proposals / votes (counts only) ─────────────
    const active_proposals = ctx.bc.gov_registry.activeProposalCount();
    const votes_cast = ctx.bc.gov_registry.voteCountBy(addr);

    // ── Assemble final JSON ───────────────────────────────────────────────
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"address\":\"{s}\"," ++
        "\"balance_sat\":{d}," ++
        "\"pq_identity\":{s}," ++
        "\"label_verdict\":\"{s}\"," ++
        "\"social\":{{\"followers\":{d},\"following\":{d}}}," ++
        "\"poap_count\":{d}," ++
        "\"notarization_count\":{d}," ++
        "\"escrow\":{{\"sent\":{d},\"received\":{d}}}," ++
        "\"reputation\":{s}," ++
        "\"governance\":{{\"active_chain_proposals\":{d},\"votes_cast\":{d}}}" ++
        "}}}}",
        .{
            id, addr,
            omni_balance,
            pq_json,
            label_verdict,
            followers_n, following_n,
            poap_n,
            note_count,
            esc_sent, esc_recv,
            rep_json,
            active_proposals, votes_cast,
        },
    );
}

/// RPC `profile_init <addr>` — idempotent. Generates the DID, returns an
/// empty Manifest skeleton (all 10 leaves zero) and a fresh salt (returned
/// only this once). Appends an `op=init` line to profiles.jsonl.
pub fn handleProfileInit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const h160 = rpc.addrToH160(addr, alloc) catch
        return rpc.errorJson(-32602, "Invalid bech32 address", id, alloc);

    const did = try id_layer_mod.did.didFromHash160(h160, alloc);
    defer alloc.free(did);

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    _ = try store.getOrCreate(h160);

    // Best-effort JSONL append — init event so replay can recreate the entry.
    {
        const ts = std.time.timestamp();
        const init_line = std.fmt.allocPrint(alloc,
            "{{\"op\":\"init\",\"addr\":\"{s}\",\"did\":\"{s}\",\"ts\":{d}}}",
            .{ addr, did, ts }) catch null;
        if (init_line) |l| {
            defer alloc.free(l);
            rpc.appendProfileLog(ctx, l);
        }
    }

    // Empty manifest skeleton — all leaves zero. Use the same Manifest type
    // so the root we report matches what an off-chain anchor would produce
    // for an unpopulated holder.
    const empty_manifest = id_layer_mod.manifest.Manifest{
        .kyc_hash = [_]u8{0} ** 32,
        .assets_root = [_]u8{0} ** 32,
        .reputation = .{},
        .pq_pubkeys_concat = "",
        .obm = 0,
        .timestamp_unix_s = 0,
    };
    const root = try id_layer_mod.manifest.computeRoot(empty_manifest, alloc);
    const root_hex = try rpc.hexEncode(alloc, &root);
    defer alloc.free(root_hex);

    const salt_bytes = try store.salt_mgr.manager().getOrCreate();
    const salt_hex = try rpc.hexEncode(alloc, &salt_bytes);
    defer alloc.free(salt_hex);

    const zero_hex = "0000000000000000000000000000000000000000000000000000000000000000";

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"did\":\"{s}\",\"address\":\"{s}\",\"manifest_root_empty\":\"{s}\",\"salt_hex\":\"{s}\",\"facets\":{{\"social\":\"{s}\",\"professional\":\"{s}\",\"cultural\":\"{s}\",\"economic\":\"{s}\"}}}}}}",
        .{ id, did, addr, root_hex, salt_hex, zero_hex, zero_hex, zero_hex, zero_hex });
}

/// RPC `profile_update <addr> <facet> <field> <value> <is_public>` — update
/// one field in one facet. Stored in-memory + JSONL log.
pub fn handleProfileUpdate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const facet_name = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "facet") orelse
        return rpc.errorJson(-32602, "Missing param: facet", id, alloc);
    const field_name = rpc.extractArrayStr(body, 2) orelse rpc.extractStr(body, "field") orelse
        return rpc.errorJson(-32602, "Missing param: field", id, alloc);
    const value = rpc.extractArrayStr(body, 3) orelse rpc.extractStr(body, "value") orelse
        return rpc.errorJson(-32602, "Missing param: value", id, alloc);
    // is_public — accept "true"/"false" string OR bare JSON boolean true/false in
    // array position 4, or the "is_public" named key. extractArrayToken handles both.
    var is_public: bool = false;
    if (rpc.extractArrayToken(body, 4)) |s| {
        is_public = std.mem.eql(u8, s, "true");
    } else if (rpc.extractStr(body, "is_public")) |s| {
        is_public = std.mem.eql(u8, s, "true");
    }

    const fidx = rpc.facetIndex(facet_name) orelse
        return rpc.errorJson(-32602, "Unknown facet (expected social|professional|cultural|economic)", id, alloc);

    const h160 = rpc.addrToH160(addr, alloc) catch
        return rpc.errorJson(-32602, "Invalid bech32 address", id, alloc);

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = try store.getOrCreate(h160);
    var facet = &entry.facets[fidx];

    // Drop any prior value for this key (free its memory) before insert.
    if (facet.fields.fetchRemove(field_name)) |old| {
        store.allocator.free(old.key);
        store.allocator.free(old.value.value);
    }
    const key_dup = try store.allocator.dupe(u8, field_name);
    const val_dup = try store.allocator.dupe(u8, value);
    try facet.fields.put(key_dup, .{ .value = val_dup, .is_public = is_public });

    const new_root = try rpc.computeFacetRoot(facet, alloc);
    const root_hex = try rpc.hexEncode(alloc, &new_root);
    defer alloc.free(root_hex);

    // Best-effort JSONL append — update event with all fields needed for replay.
    const ts = std.time.timestamp();
    const log_line = try std.fmt.allocPrint(alloc,
        "{{\"op\":\"update\",\"addr\":\"{s}\",\"facet\":\"{s}\",\"field\":\"{s}\",\"value\":\"{s}\",\"is_public\":\"{}\",\"ts\":{d}}}",
        .{ addr, facet_name, field_name, value, is_public, ts });
    defer alloc.free(log_line);
    rpc.appendProfileLog(ctx, log_line);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"facet\":\"{s}\",\"new_facet_root\":\"{s}\"}}}}",
        .{ id, facet_name, root_hex });
}

/// RPC `profile_get <addr>` — public view: only fields marked is_public.
pub fn handleProfileGet(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const h160 = rpc.addrToH160(addr, alloc) catch
        return rpc.errorJson(-32602, "Invalid bech32 address", id, alloc);

    const did = try id_layer_mod.did.didFromHash160(h160, alloc);
    defer alloc.free(did);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"did\":\"{s}\",\"address\":\"{s}\",\"facets\":{{",
        .{ id, did, addr });

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    const maybe_entry = store.get(h160);

    for (rpc.FACET_NAMES, 0..) |fname, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":", .{fname});
        if (maybe_entry) |entry| {
            try rpc.writeFacetPublicJson(w, &entry.facets[i]);
        } else {
            try w.writeAll("{}");
        }
    }
    try w.writeAll("}}}");
    return buf.toOwnedSlice();
}

/// RPC `mica_attest <addr> <kind> <issuer_did> <signature_hex>` — record a
/// KYC / AML / sanctions attestation on the address's economic profile.
pub fn handleMicaAttest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const kind = rpc.extractArrayStr(body, 1) orelse rpc.extractStr(body, "kind") orelse
        return rpc.errorJson(-32602, "Missing param: kind", id, alloc);
    const issuer = rpc.extractArrayStr(body, 2) orelse rpc.extractStr(body, "issuer_did") orelse "";
    const sig_hex = rpc.extractArrayStr(body, 3) orelse rpc.extractStr(body, "signature_hex") orelse "";

    if (!(std.mem.eql(u8, kind, "kyc") or std.mem.eql(u8, kind, "aml") or
          std.mem.eql(u8, kind, "sanctions")))
        return rpc.errorJson(-32602, "kind must be kyc|aml|sanctions", id, alloc);

    if (!rpc.isHexShape(sig_hex))
        return rpc.errorJson(-32602, "signature_hex must be hex (even length, [0-9a-f])", id, alloc);

    // Self-attestation rule: empty issuer ⇒ signature must be zeros (or empty).
    if (issuer.len == 0 and sig_hex.len > 0 and !rpc.isAllZeros(sig_hex))
        return rpc.errorJson(-32602, "Self-attestation requires zero signature", id, alloc);

    const h160 = rpc.addrToH160(addr, alloc) catch
        return rpc.errorJson(-32602, "Invalid bech32 address", id, alloc);

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    const entry = try store.getOrCreate(h160);

    try entry.mica.append(.{
        .kind = try store.allocator.dupe(u8, kind),
        .issuer_did = try store.allocator.dupe(u8, issuer),
        .signature_hex = try store.allocator.dupe(u8, sig_hex),
        .timestamp_unix_s = @intCast(std.time.timestamp()),
    });

    // Mirror the latest-of-kind flag into the economic facet as a public
    // field (e.g. kyc_verified=true). Cleartext sig stays in mica list.
    var econ = &entry.facets[3];
    const flag_key = try std.fmt.allocPrint(store.allocator, "{s}_verified", .{kind});
    if (econ.fields.fetchRemove(flag_key)) |old| {
        store.allocator.free(old.key);
        store.allocator.free(old.value.value);
    }
    const flag_val = try store.allocator.dupe(u8, "true");
    try econ.fields.put(flag_key, .{ .value = flag_val, .is_public = true });

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"attestation_kind\":\"{s}\",\"issuer\":\"{s}\"}}}}",
        .{ id, kind, issuer });
}

/// RPC `mica_disclose <addr>` — return all MiCA-relevant attestations for
/// the address (KYC, AML, sanctions) plus issuer flag and risk category
/// pulled from the economic facet (best-effort).
pub fn handleMicaDisclose(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const h160 = rpc.addrToH160(addr, alloc) catch
        return rpc.errorJson(-32602, "Invalid bech32 address", id, alloc);

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    const w = buf.writer();

    try w.print(
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"attestations\":[",
        .{ id, addr });

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();
    const maybe_entry = store.get(h160);

    var is_mica_issuer: bool = false;
    var risk_category: []const u8 = "unknown";

    if (maybe_entry) |entry| {
        for (entry.mica.items, 0..) |att, i| {
            if (i > 0) try w.writeByte(',');
            try w.print(
                "{{\"kind\":\"{s}\",\"issuer_did\":\"{s}\",\"signature_hex\":\"{s}\",\"timestamp\":{d}}}",
                .{ att.kind, att.issuer_did, att.signature_hex, att.timestamp_unix_s });
        }
        // Pull optional economic-facet flags (only if marked public).
        const econ = &entry.facets[3];
        if (econ.fields.get("is_mica_issuer")) |fv| {
            if (fv.is_public) is_mica_issuer = std.mem.eql(u8, fv.value, "true");
        }
        if (econ.fields.get("risk_category")) |fv| {
            if (fv.is_public) risk_category = fv.value;
        }
    }
    try w.print("],\"is_mica_issuer\":{},\"risk_category\":\"{s}\"}}}}", .{ is_mica_issuer, risk_category });
    return buf.toOwnedSlice();
}

/// RPC `disclose_post` — prove a specific social post from facet[0].
/// Request:  {"method":"disclose_post","params":{"address":"ob1q...","post_index":0}}
/// Response: {"post_hash":"hex...","timestamp":N,"is_public":true,"proof":["hex..."]}
pub fn handleDisclosePost(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const post_idx = rpc.extractParamObjectU64(body, "post_index");

    const h160 = rpc.addrToH160(address, alloc) catch
        return rpc.errorJson(-32602, "Invalid address", id, alloc);

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = store.get(h160) orelse
        return rpc.errorJson(-32000, "Profile not found", id, alloc);

    const facet = &entry.facets[0]; // social

    // Build key names for this post index (max fits in 32 bytes).
    var hash_key_buf: [32]u8 = undefined;
    var ts_key_buf:   [32]u8 = undefined;
    var pub_key_buf:  [32]u8 = undefined;

    const hash_key = std.fmt.bufPrint(&hash_key_buf, "post_{d}_hash",   .{post_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const ts_key   = std.fmt.bufPrint(&ts_key_buf,   "post_{d}_ts",     .{post_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const pub_key  = std.fmt.bufPrint(&pub_key_buf,  "post_{d}_public", .{post_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);

    const hash_val = (facet.fields.get(hash_key) orelse
        return rpc.errorJson(-32000, "Post not found at index", id, alloc)).value;

    const ts_val  = if (facet.fields.get(ts_key))  |fv| fv.value else "0";
    const pub_val = if (facet.fields.get(pub_key)) |fv| fv.value else "false";
    const is_pub  = std.mem.eql(u8, pub_val, "true");

    // Proof = facet root (commits to all items in this facet).
    const facet_root = try rpc.computeFacetRoot(facet, alloc);
    const root_hex   = try rpc.hexEncode(alloc, &facet_root);
    defer alloc.free(root_hex);

    const ts_num = std.fmt.parseInt(u64, ts_val, 10) catch 0;

    const phash_safe = try rpc.jsonSanitize(alloc, hash_val);
    defer alloc.free(phash_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"post_hash\":\"{s}\",\"timestamp\":{d},\"is_public\":{},\"proof\":[\"{s}\"]}}}}",
        .{ id, phash_safe, ts_num, is_pub, root_hex });
}

/// RPC `disclose_cert` — prove a specific professional certification from facet[1].
/// Request:  {"method":"disclose_cert","params":{"address":"ob1q...","cert_index":0}}
/// Response: {"issuer_did":"did:...","credential_kind":"engineering","valid_from":N,"valid_until":N,"hash":"hex...","proof":["hex..."]}
pub fn handleDiscloseCert(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const cert_idx = rpc.extractParamObjectU64(body, "cert_index");

    const h160 = rpc.addrToH160(address, alloc) catch
        return rpc.errorJson(-32602, "Invalid address", id, alloc);

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = store.get(h160) orelse
        return rpc.errorJson(-32000, "Profile not found", id, alloc);

    const facet = &entry.facets[1]; // professional

    var issuer_key_buf:  [32]u8 = undefined;
    var kind_key_buf:    [32]u8 = undefined;
    var from_key_buf:    [32]u8 = undefined;
    var until_key_buf:   [32]u8 = undefined;
    var hash_key_buf:    [32]u8 = undefined;

    const issuer_key = std.fmt.bufPrint(&issuer_key_buf, "cert_{d}_issuer",      .{cert_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const kind_key   = std.fmt.bufPrint(&kind_key_buf,   "cert_{d}_kind",        .{cert_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const from_key   = std.fmt.bufPrint(&from_key_buf,   "cert_{d}_valid_from",  .{cert_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const until_key  = std.fmt.bufPrint(&until_key_buf,  "cert_{d}_valid_until", .{cert_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const hash_key   = std.fmt.bufPrint(&hash_key_buf,   "cert_{d}_hash",        .{cert_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);

    // issuer or hash must exist — use issuer as the required sentinel.
    const issuer_val = (facet.fields.get(issuer_key) orelse
        return rpc.errorJson(-32000, "Cert not found at index", id, alloc)).value;

    const kind_val  = if (facet.fields.get(kind_key))  |fv| fv.value else "";
    const from_val  = if (facet.fields.get(from_key))  |fv| fv.value else "0";
    const until_val = if (facet.fields.get(until_key)) |fv| fv.value else "0";
    const hash_val  = if (facet.fields.get(hash_key))  |fv| fv.value else "";

    const facet_root = try rpc.computeFacetRoot(facet, alloc);
    const root_hex   = try rpc.hexEncode(alloc, &facet_root);
    defer alloc.free(root_hex);

    const from_num  = std.fmt.parseInt(u64, from_val,  10) catch 0;
    const until_num = std.fmt.parseInt(u64, until_val, 10) catch 0;

    const issuer_safe = try rpc.jsonSanitize(alloc, issuer_val);
    defer alloc.free(issuer_safe);
    const ckind_safe = try rpc.jsonSanitize(alloc, kind_val);
    defer alloc.free(ckind_safe);
    const chash_safe = try rpc.jsonSanitize(alloc, hash_val);
    defer alloc.free(chash_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"issuer_did\":\"{s}\",\"credential_kind\":\"{s}\",\"valid_from\":{d},\"valid_until\":{d},\"hash\":\"{s}\",\"proof\":[\"{s}\"]}}}}",
        .{ id, issuer_safe, ckind_safe, from_num, until_num, chash_safe, root_hex });
}

/// RPC `disclose_work` — prove a specific notarized work from facet[2] (cultural).
/// Request:  {"method":"disclose_work","params":{"address":"ob1q...","work_index":0}}
/// Response: {"content_hash":"hex...","work_kind":"code","notarized_at":N,"is_public":bool,"proof":["hex..."]}
pub fn handleDiscloseWork(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractParamObjectField(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const work_idx = rpc.extractParamObjectU64(body, "work_index");

    const h160 = rpc.addrToH160(address, alloc) catch
        return rpc.errorJson(-32602, "Invalid address", id, alloc);

    const store = rpc.getProfileStore(alloc);
    store.mutex.lock();
    defer store.mutex.unlock();

    const entry = store.get(h160) orelse
        return rpc.errorJson(-32000, "Profile not found", id, alloc);

    const facet = &entry.facets[2]; // cultural

    var hash_key_buf: [32]u8 = undefined;
    var kind_key_buf: [32]u8 = undefined;
    var ts_key_buf:   [32]u8 = undefined;
    var pub_key_buf:  [32]u8 = undefined;

    const hash_key = std.fmt.bufPrint(&hash_key_buf, "work_{d}_hash",   .{work_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const kind_key = std.fmt.bufPrint(&kind_key_buf, "work_{d}_kind",   .{work_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const ts_key   = std.fmt.bufPrint(&ts_key_buf,   "work_{d}_ts",     .{work_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);
    const pub_key  = std.fmt.bufPrint(&pub_key_buf,  "work_{d}_public", .{work_idx}) catch
        return rpc.errorJson(-32000, "Index too large", id, alloc);

    const hash_val = (facet.fields.get(hash_key) orelse
        return rpc.errorJson(-32000, "Work not found at index", id, alloc)).value;

    const kind_val = if (facet.fields.get(kind_key)) |fv| fv.value else "";
    const ts_val   = if (facet.fields.get(ts_key))   |fv| fv.value else "0";
    const pub_val  = if (facet.fields.get(pub_key))  |fv| fv.value else "false";
    const is_pub   = std.mem.eql(u8, pub_val, "true");

    const facet_root = try rpc.computeFacetRoot(facet, alloc);
    const root_hex   = try rpc.hexEncode(alloc, &facet_root);
    defer alloc.free(root_hex);

    const ts_num = std.fmt.parseInt(u64, ts_val, 10) catch 0;

    const whash_safe = try rpc.jsonSanitize(alloc, hash_val);
    defer alloc.free(whash_safe);
    const wkind_safe = try rpc.jsonSanitize(alloc, kind_val);
    defer alloc.free(wkind_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content_hash\":\"{s}\",\"work_kind\":\"{s}\",\"notarized_at\":{d},\"is_public\":{},\"proof\":[\"{s}\"]}}}}",
        .{ id, whash_safe, wkind_safe, ts_num, is_pub, root_hex });
}
