// oracle.zig — Oracle + omnibus_* RPC handlers extracted from rpc_server.zig.
const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const oracle_mod = @import("../oracle.zig");
const cross_chain_oracle_mod = @import("../cross_chain_oracle.zig");
const price_oracle_mod = @import("../price_oracle.zig");
const ws_exchange_feed_mod = @import("../ws_exchange_feed.zig");
const secp256k1_mod = @import("../secp256k1.zig");

const block_mod = @import("../block.zig");
const chain_config = @import("../chain_config.zig");
const hex_utils = @import("../hex_utils.zig");
const main_mod = @import("../main.zig");
const ServerCtx = rpc.ServerCtx;

// Extra dependencies pulled in via the parent rpc_server module.

pub fn handleOracleBtcHeight(ctx: *ServerCtx, id: u64) ![]u8 {
    rpc.ensureOracleLoaded();
    rpc.g_xchain_oracle_mutex.lock();
    defer rpc.g_xchain_oracle_mutex.unlock();
    const h = rpc.g_xchain_oracle.latestBtcHeight() orelse 0;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"height\":{d}}}}}",
        .{ id, h });
}

pub fn handleOracleEthHeight(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    rpc.ensureOracleLoaded();
    const cid_str = rpc.extractStr(body, "chain_id") orelse "1";
    const cid = std.fmt.parseInt(u64, cid_str, 10) catch
        return rpc.errorJson(-32602, "Invalid chain_id", id, ctx.allocator);
    rpc.g_xchain_oracle_mutex.lock();
    defer rpc.g_xchain_oracle_mutex.unlock();
    const h = rpc.g_xchain_oracle.latestEthHeight(cid) orelse 0;
    return std.fmt.allocPrint(ctx.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"chain_id\":{d},\"height\":{d}}}}}",
        .{ id, cid, h });
}

pub fn handleOracleRecordHeader(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    rpc.ensureOracleLoaded();

    const chain = rpc.extractStr(body, "chain") orelse
        return rpc.errorJson(-32602, "Missing param: chain (btc|eth)", id, ctx.allocator);

    const ts_str = rpc.extractStr(body, "timestamp") orelse "0";
    const ts = std.fmt.parseInt(u64, ts_str, 10) catch 0;

    // ─── Quorum signature verification ──────────────────────────────────
    // Build canonical message:
    //   sha256("OMNI_ORACLE_v1\n" + chain + "\n" + height + "\n" + header_hash_hex)
    // Then require ≥ ORACLE_QUORUM_MIN distinct valid secp256k1 sigs from
    // pubkeys registered via setOracleQuorumPubkeys(). Any of:
    //   - missing quorum_sigs field
    //   - fewer than 3 valid+distinct sigs
    //   - signers not in the registered pubkey set
    // → reject with -32031.
    //
    // BACKWARD-COMPAT (dev-only): if the legacy `quorum_ok=true` flag is
    // present AND the node has zero registered quorum pubkeys, we accept
    // with a logged warning. This keeps dev/testnet bring-up scripts
    // working while a real validator key set is being set up. Production
    // operators MUST install pubkeys (and then quorum_ok is ignored).
    // `quorum_sigs` may arrive in two shapes:
    //   * NEW (preferred): JSON array of {"pubkey","sig"} objects
    //   * LEGACY: a flat string "pk1:sig1,pk2:sig2,..." (comma-sep pairs)
    // We detect new-format via findJsonArray; on miss we fall back to
    // extractStr which handles the legacy string. When the legacy form
    // is used we log a warning (one-shot per request) so operators know
    // to migrate their callers.
    const sigs_array_body: ?[]const u8 = rpc.findJsonArray(body, "quorum_sigs");
    const sigs_blob: []const u8 = if (sigs_array_body == null)
        (rpc.extractStr(body, "quorum_sigs") orelse "")
    else
        "";
    if (sigs_array_body == null and sigs_blob.len > 0) {
        std.debug.print(
            "[oracle_recordHeader] DEPRECATED: legacy comma-separated quorum_sigs string accepted; clients should migrate to JSON array form.\n",
            .{},
        );
    }
    const legacy_flag = rpc.extractStr(body, "quorum_ok") orelse "";
    const have_legacy = std.mem.eql(u8, legacy_flag, "true");

    // We need the height + header hash up-front to build the canonical msg.
    // Each chain-specific branch below re-parses these; here we do a
    // pre-pass JUST to assemble the message.
    //
    // Field names — accept both new ("height") and legacy ("block_height"
    // for BTC, "block_number" for ETH) for backward compatibility.
    var height_for_msg: u64 = 0;
    var header_hash_for_msg: [64]u8 = undefined;
    var header_hash_hex_len: usize = 0;
    if (std.mem.eql(u8, chain, "btc")) {
        const h_str = rpc.extractStr(body, "height") orelse
            rpc.extractStr(body, "block_height") orelse "0";
        height_for_msg = std.fmt.parseInt(u64, h_str, 10) catch 0;
        var hh = rpc.extractStr(body, "header_hash") orelse "";
        if (hh.len >= 2 and hh[0] == '0' and (hh[1] == 'x' or hh[1] == 'X')) hh = hh[2..];
        if (hh.len > 64) return rpc.errorJson(-32602, "Bad header_hash", id, ctx.allocator);
        @memcpy(header_hash_for_msg[0..hh.len], hh);
        header_hash_hex_len = hh.len;
    } else if (std.mem.eql(u8, chain, "eth")) {
        const bn_str = rpc.extractStr(body, "height") orelse
            rpc.extractStr(body, "block_number") orelse "0";
        height_for_msg = std.fmt.parseInt(u64, bn_str, 10) catch 0;
        // For ETH the canonical message uses block_hash if available,
        // otherwise fall back to header_hash (the new alias).
        var bh = rpc.extractStr(body, "block_hash") orelse
            rpc.extractStr(body, "header_hash") orelse "";
        if (bh.len >= 2 and bh[0] == '0' and (bh[1] == 'x' or bh[1] == 'X')) bh = bh[2..];
        if (bh.len > 64) return rpc.errorJson(-32602, "Bad block_hash", id, ctx.allocator);
        @memcpy(header_hash_for_msg[0..bh.len], bh);
        header_hash_hex_len = bh.len;
    }

    var canon_buf: [256]u8 = undefined;
    const canon = std.fmt.bufPrint(
        &canon_buf,
        "OMNI_ORACLE_v1\n{s}\n{d}\n{s}",
        .{ chain, height_for_msg, header_hash_for_msg[0..header_hash_hex_len] },
    ) catch return rpc.errorJson(-32000, "Canonical msg overflow", id, ctx.allocator);
    var canon_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canon, &canon_digest, .{});

    // Verify each pair, dedup signers, count valid.
    // pubkey_hex = 66 chars (compressed secp256k1), sig_hex = 128 chars.
    var distinct_signers: [rpc.ORACLE_QUORUM_MAX][33]u8 = undefined;
    var distinct_count: usize = 0;
    if (sigs_array_body) |arr_body| {
        // NEW shape: JSON array of {pubkey, sig} objects. We walk by
        // brace-counting to slice out each object body, then extract
        // the two string fields with extractStr (it's scoped to that
        // sub-slice so name collisions with the outer body are impossible).
        var i: usize = 1; // skip leading '['
        const end = arr_body.len - 1; // exclude trailing ']'
        while (i < end) {
            // Skip whitespace + commas.
            while (i < end and (arr_body[i] == ' ' or arr_body[i] == ',' or
                arr_body[i] == '\t' or arr_body[i] == '\r' or arr_body[i] == '\n')) : (i += 1) {}
            if (i >= end) break;
            if (arr_body[i] != '{') break; // malformed — bail safely
            // Find matching '}'.
            const obj_start = i;
            var depth: i32 = 0;
            var in_str = false;
            while (i < end) : (i += 1) {
                const c = arr_body[i];
                if (in_str) {
                    if (c == '\\') { i += 1; continue; }
                    if (c == '"') in_str = false;
                    continue;
                }
                if (c == '"') in_str = true
                else if (c == '{') depth += 1
                else if (c == '}') {
                    depth -= 1;
                    if (depth == 0) { i += 1; break; }
                }
            }
            const obj = arr_body[obj_start..i];
            const pk_hex = rpc.extractStr(obj, "pubkey") orelse continue;
            const sig_hex = rpc.extractStr(obj, "sig") orelse continue;
            if (pk_hex.len != 66 or sig_hex.len != 128) continue;
            var pk_bytes: [33]u8 = undefined;
            var sig_bytes: [64]u8 = undefined;
            hex_utils.hexToBytes(pk_hex, &pk_bytes) catch continue;
            hex_utils.hexToBytes(sig_hex, &sig_bytes) catch continue;
            if (!rpc.isQuorumPubkey(pk_bytes)) continue;
            var dup = false;
            var j: usize = 0;
            while (j < distinct_count) : (j += 1) {
                if (std.mem.eql(u8, &distinct_signers[j], &pk_bytes)) { dup = true; break; }
            }
            if (dup) continue;
            if (!secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, &canon_digest, sig_bytes)) continue;
            distinct_signers[distinct_count] = pk_bytes;
            distinct_count += 1;
            if (distinct_count >= rpc.ORACLE_QUORUM_MAX) break;
        }
    } else if (sigs_blob.len > 0) {
        // LEGACY shape: comma-separated `pubkey_hex:sig_hex` pairs.
        var it = std.mem.splitScalar(u8, sigs_blob, ',');
        while (it.next()) |pair| {
            const colon = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
            const pk_hex = pair[0..colon];
            const sig_hex = pair[colon + 1 ..];
            if (pk_hex.len != 66 or sig_hex.len != 128) continue;
            var pk_bytes: [33]u8 = undefined;
            var sig_bytes: [64]u8 = undefined;
            hex_utils.hexToBytes(pk_hex, &pk_bytes) catch continue;
            hex_utils.hexToBytes(sig_hex, &sig_bytes) catch continue;
            if (!rpc.isQuorumPubkey(pk_bytes)) continue;
            var dup = false;
            var j: usize = 0;
            while (j < distinct_count) : (j += 1) {
                if (std.mem.eql(u8, &distinct_signers[j], &pk_bytes)) { dup = true; break; }
            }
            if (dup) continue;
            if (!secp256k1_mod.Secp256k1Crypto.verify(pk_bytes, &canon_digest, sig_bytes)) continue;
            distinct_signers[distinct_count] = pk_bytes;
            distinct_count += 1;
            if (distinct_count >= rpc.ORACLE_QUORUM_MAX) break;
        }
    }

    if (distinct_count < rpc.ORACLE_QUORUM_MIN) {
        // Legacy dev-mode escape hatch: only when no quorum pubkeys are
        // configured AND the legacy flag is set.
        if (rpc.g_oracle_quorum_count == 0 and have_legacy) {
            std.debug.print(
                "[oracle_recordHeader] WARNING: dev-mode (no quorum pubkeys configured); accepting on legacy quorum_ok=true\n",
                .{},
            );
        } else {
            return rpc.errorJson(-32031, "Quorum signature insufficient", id, ctx.allocator);
        }
    }

    if (std.mem.eql(u8, chain, "btc")) {
        // Accept new "height" alongside legacy "block_height".
        const h_str = rpc.extractStr(body, "height") orelse
            rpc.extractStr(body, "block_height") orelse
            return rpc.errorJson(-32602, "Missing param: height (or block_height)", id, ctx.allocator);
        const hh_str = rpc.extractStr(body, "header_hash") orelse
            return rpc.errorJson(-32602, "Missing param: header_hash", id, ctx.allocator);
        const h = std.fmt.parseInt(u64, h_str, 10) catch
            return rpc.errorJson(-32602, "Bad height", id, ctx.allocator);
        const hh = rpc.parseHex32Spv(hh_str) orelse
            return rpc.errorJson(-32602, "Bad header_hash (need 32-byte hex)", id, ctx.allocator);

        // Optional: caller may supply the raw 80-byte block header as hex
        // (160 chars). When present, we extract merkle_root via parseHeader
        // and store it on the anchor — defense-in-depth so SPV verifiers
        // can ignore caller-supplied merkle_root and trust the anchor instead.
        // Backward-compat: if `raw_header_hex` is absent, merkle_root stays
        // zero on the anchor and SPV falls back to the legacy blob field.
        var merkle_root: [32]u8 = [_]u8{0} ** 32;
        if (rpc.extractStr(body, "raw_header_hex")) |raw_hex| {
            if (raw_hex.len != 160) {
                return rpc.errorJson(-32602, "raw_header_hex must be 160 hex chars (80 bytes)", id, ctx.allocator);
            }
            var raw_bytes: [80]u8 = undefined;
            hex_utils.hexToBytes(raw_hex, &raw_bytes) catch
                return rpc.errorJson(-32602, "Bad raw_header_hex", id, ctx.allocator);
            const spv_btc_mod = @import("../spv_btc.zig");
            const parsed = spv_btc_mod.parseHeader(raw_bytes);
            merkle_root = parsed.merkle_root;
        }

        rpc.g_xchain_oracle_mutex.lock();
        defer rpc.g_xchain_oracle_mutex.unlock();
        rpc.g_xchain_oracle.recordBtcAnchor(.{
            .block_height = h,
            .header_hash = hh,
            .merkle_root = merkle_root,
            .timestamp = ts,
        }) catch |e| {
            const msg = if (e == error.NonMonotonic) "Non-monotonic update" else "Anchor rejected";
            return rpc.errorJson(-32000, msg, id, ctx.allocator);
        };
        rpc.g_xchain_oracle.saveToFile(rpc.XCHAIN_ORACLE_PATH) catch {};
        return std.fmt.allocPrint(ctx.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"chain\":\"btc\",\"height\":{d}}}}}",
            .{ id, h });
    }

    if (std.mem.eql(u8, chain, "eth")) {
        const cid_str = rpc.extractStr(body, "chain_id") orelse "1";
        // Accept new "height" alongside legacy "block_number".
        const bn_str = rpc.extractStr(body, "height") orelse
            rpc.extractStr(body, "block_number") orelse
            return rpc.errorJson(-32602, "Missing param: height (or block_number)", id, ctx.allocator);
        // Accept new "header_hash" alias alongside legacy "block_hash".
        const bh_str = rpc.extractStr(body, "block_hash") orelse
            rpc.extractStr(body, "header_hash") orelse
            return rpc.errorJson(-32602, "Missing param: header_hash (or block_hash)", id, ctx.allocator);
        const rr_str = rpc.extractStr(body, "receipts_root") orelse
            return rpc.errorJson(-32602, "Missing param: receipts_root", id, ctx.allocator);
        const cid = std.fmt.parseInt(u64, cid_str, 10) catch
            return rpc.errorJson(-32602, "Bad chain_id", id, ctx.allocator);
        const bn = std.fmt.parseInt(u64, bn_str, 10) catch
            return rpc.errorJson(-32602, "Bad height", id, ctx.allocator);
        const bh = rpc.parseHex32Spv(bh_str) orelse
            return rpc.errorJson(-32602, "Bad header_hash", id, ctx.allocator);
        const rr = rpc.parseHex32Spv(rr_str) orelse
            return rpc.errorJson(-32602, "Bad receipts_root", id, ctx.allocator);
        rpc.g_xchain_oracle_mutex.lock();
        defer rpc.g_xchain_oracle_mutex.unlock();
        rpc.g_xchain_oracle.recordEthAnchor(.{
            .chain_id = cid, .block_number = bn, .block_hash = bh,
            .receipts_root = rr, .timestamp = ts,
        }) catch |e| {
            const msg = switch (e) {
                error.NonMonotonic => "Non-monotonic update",
                error.TooManyChains => "Chain registry full",
            };
            return rpc.errorJson(-32000, msg, id, ctx.allocator);
        };
        rpc.g_xchain_oracle.saveToFile(rpc.XCHAIN_ORACLE_PATH) catch {};
        return std.fmt.allocPrint(ctx.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"ok\":true,\"chain\":\"eth\",\"chain_id\":{d},\"block_number\":{d}}}}}",
            .{ id, cid, bn });
    }

    return rpc.errorJson(-32602, "Unknown chain (use 'btc' or 'eth')", id, ctx.allocator);
}

pub fn handleOmnibusPrices(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (ctx.oracle) |oracle| {
        // Build prices for main chains
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const prefix = std.fmt.bufPrint(buf[pos..], "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id}) catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        const chains = [_]struct { name: []const u8, idx: usize }{
            .{ .name = "OMNI/USD", .idx = 0 },
            .{ .name = "BTC/USD", .idx = 1 },
            .{ .name = "ETH/USD", .idx = 2 },
        };

        for (chains, 0..) |chain, ci| {
            if (ci > 0) { buf[pos] = ','; pos += 1; }
            const cp = oracle.consensus_prices[chain.idx];
            const price_usd = cp.price_micro_usd / 1_000_000;
            const price_cents = (cp.price_micro_usd % 1_000_000) / 10_000;
            const entry = std.fmt.bufPrint(buf[pos..],
                "{{\"pair\":\"{s}\",\"price\":\"{d}.{d:0>2}\",\"sources\":{d},\"valid\":{s}}}",
                .{ chain.name, price_usd, price_cents, cp.submission_count, if (cp.is_valid) "true" else "false" },
            ) catch break;
            pos += entry.len;
        }

        const suffix = std.fmt.bufPrint(buf[pos..], "]}}", .{}) catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += suffix.len;
        return alloc.dupe(u8, buf[0..pos]);
    }

    // No oracle attached — return empty
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[]}}",
        .{id},
    );
}

// ─── omnibus_getblockprices / omnibus_getpricerange ────────────────────────
//
// Lightweight read endpoints for the 21-slot per-block oracle snapshot.
// Both use the same fast-path/fallback strategy as `getblock`:
//   1) If the in-memory `block_prices` map has the height, use it (cheap).
//   2) Otherwise fall back to the on-chain `blk.prices` array (authoritative;
//      committed via prices_root in the block hash).

/// Renders a single block's prices into the supplied buffer at `pos`. Skips
/// empty/zero entries. Returns the number of bytes written.
fn appendPricesJson(
    bc: *blockchain_mod.Blockchain,
    blk: *const block_mod.Block,
    buf: []u8,
    pos_in: usize,
) usize {
    var pos = pos_in;
    if (pos >= buf.len) return 0;
    buf[pos] = '['; pos += 1;
    var written: usize = 0;
    if (bc.getBlockPrices(blk.index)) |entries| {
        for (entries) |e| {
            if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
            if (written > 0) {
                if (pos >= buf.len) break;
                buf[pos] = ','; pos += 1;
            }
            const ex = e.exchange[0..e.exchange_len];
            const pr = e.pair[0..e.pair_len];
            const item = std.fmt.bufPrint(buf[pos..],
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
            ) catch break;
            pos += item.len;
            written += 1;
        }
    } else {
        for (blk.prices) |e| {
            if (e.exchange_len == 0 and e.pair_len == 0 and !e.success and e.timestamp_ms == 0) continue;
            if (written > 0) {
                if (pos >= buf.len) break;
                buf[pos] = ','; pos += 1;
            }
            const ex = e.exchange[0..e.exchange_len];
            const pr = e.pair[0..e.pair_len];
            const item = std.fmt.bufPrint(buf[pos..],
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                .{ ex, pr, e.bid_micro_usd, e.ask_micro_usd, e.timestamp_ms, if (e.success) "true" else "false" },
            ) catch break;
            pos += item.len;
            written += 1;
        }
    }
    if (pos >= buf.len) return pos - pos_in;
    buf[pos] = ']'; pos += 1;
    return pos - pos_in;
}

/// Hex-encode a 32-byte hash into 64 lowercase hex chars (in-place fill).
fn hashToHex(hash: [32]u8, out: *[64]u8) void {
    for (0..32) |i| {
        const b = hash[i];
        out[i * 2] = "0123456789abcdef"[b >> 4];
        out[i * 2 + 1] = "0123456789abcdef"[b & 0x0f];
    }
}

/// `omnibus_getblockprices [height]` — returns just the 21 price entries
/// for the given block, plus pricesRoot + pricesValidated. Lightweight path
/// for clients (charts, oracles) that don't need the rest of the block.
pub fn handleOmnibusBlockPrices(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const height: u32 = std.math.cast(u32, rpc.extractArrayNum(body, 0)) orelse 0;
    const blk_opt = ctx.bc.getBlock(height);
    const blk = blk_opt orelse return rpc.errorJson(-5, "Block not found", id, alloc);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const prefix = std.fmt.bufPrint(buf[pos..],
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"height\":{d},\"prices\":",
        .{ id, blk.index },
    ) catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
    pos += prefix.len;

    pos += appendPricesJson(ctx.bc, &blk, &buf, pos);

    var pr_hex: [64]u8 = undefined;
    hashToHex(blk.prices_root, &pr_hex);
    const validated = blk.validatePrices();

    const suffix = std.fmt.bufPrint(buf[pos..],
        ",\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}}}",
        .{ pr_hex, if (validated) "true" else "false" },
    ) catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
    pos += suffix.len;

    return alloc.dupe(u8, buf[0..pos]);
}

/// `omnibus_getpricerange [from_height, count]` — returns an array of
/// {height, prices, pricesRoot, pricesValidated} for the range
/// [from_height, from_height + count). Capped at 100 blocks. Useful for
/// charting historical bid/ask trajectories.
pub fn handleOmnibusPriceRange(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from: u32 = std.math.cast(u32, rpc.extractArrayNum(body, 0)) orelse 0;
    const req_count = rpc.extractArrayNum(body, 1);
    const max_count: u32 = 100;
    const count: u32 = if (req_count == 0 or req_count > max_count)
        max_count
    else
        std.math.cast(u32, req_count) orelse max_count;

    // Build into a heap buffer — each block can be ~3 KiB at the upper bound,
    // so a 100-block window is ~300 KiB. Far too large for the stack.
    const cap: usize = @as(usize, count) * 4096 + 256;
    var buf = try alloc.alloc(u8, cap);
    defer alloc.free(buf);
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"from\":{d},\"count\":",
        .{ id, from },
    ) catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
    pos += prefix.len;

    // Reserve placeholder for actual count (zero-padded to 4 chars). We
    // overwrite this once we know how many blocks we actually emitted.
    const count_marker_pos = pos;
    {
        const placeholder = std.fmt.bufPrint(buf[pos..], "0000,\"blocks\":[", .{})
            catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += placeholder.len;
    }

    var emitted: u32 = 0;
    var h: u32 = from;
    while (emitted < count) : ({ h += 1; emitted += 1; }) {
        const blk_opt = ctx.bc.getBlock(h);
        const blk = blk_opt orelse break;

        if (emitted > 0) {
            if (pos >= buf.len) break;
            buf[pos] = ','; pos += 1;
        }
        const open = std.fmt.bufPrint(buf[pos..], "{{\"height\":{d},\"prices\":", .{blk.index})
            catch break;
        pos += open.len;

        pos += appendPricesJson(ctx.bc, &blk, buf, pos);

        var pr_hex: [64]u8 = undefined;
        hashToHex(blk.prices_root, &pr_hex);
        const validated = blk.validatePrices();
        const close = std.fmt.bufPrint(buf[pos..],
            ",\"pricesRoot\":\"{s}\",\"pricesValidated\":{s}}}",
            .{ pr_hex, if (validated) "true" else "false" },
        ) catch break;
        pos += close.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]}}}}", .{})
        catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
    pos += suffix.len;

    // Patch the count placeholder. emitted is at most 100 so 4 chars is plenty.
    var count_str: [4]u8 = .{ '0', '0', '0', '0' };
    var n = emitted;
    var idx: usize = 4;
    while (idx > 0) {
        idx -= 1;
        count_str[idx] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    @memcpy(buf[count_marker_pos .. count_marker_pos + 4], &count_str);

    return alloc.dupe(u8, buf[0..pos]);
}

/// omnibus_getexchangefeed — live BTC + LCX bid/ask from 3 exchanges
/// (Coinbase, Kraken, LCX) via WebSocket. Returns raw feed snapshot from
/// `main_mod.g_ws_feed` (NOT the distributed-oracle consensus).
/// Slots layout:
///   [0] BTC Coinbase  [1] BTC Kraken  [2] BTC LCX
///   [3] LCX Coinbase  [4] LCX Kraken  [5] LCX LCX
pub fn handleOmnibusExchangeFeed(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (main_mod.g_ws_feed) |*feed| {
        const snap = feed.snapshot();
        const median_btc = feed.getMedianBtc();
        const median_lcx = feed.getMedianLcx();

        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const prefix = std.fmt.bufPrint(buf[pos..],
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[", .{id})
            catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        for (snap, 0..) |p, i| {
            if (i > 0) { buf[pos] = ','; pos += 1; }
            // Bid + ask in micro-USD as integer values (avoid float in JSON).
            const entry = std.fmt.bufPrint(buf[pos..],
                "{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s}}}",
                .{ p.exchange, p.pair, p.bid_micro_usd, p.ask_micro_usd, p.timestamp_ms, if (p.success) "true" else "false" },
            ) catch break;
            pos += entry.len;
        }

        // Median BTC: emit number or null.
        if (median_btc) |m| {
            const t = std.fmt.bufPrint(buf[pos..], "],\"medianBtcMicroUsd\":{d}", .{m})
                catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        } else {
            const t = std.fmt.bufPrint(buf[pos..], "],\"medianBtcMicroUsd\":null", .{})
                catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        }

        // Median LCX: emit number or null.
        if (median_lcx) |m| {
            const t = std.fmt.bufPrint(buf[pos..], ",\"medianLcxMicroUsd\":{d}}}}}", .{m})
                catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        } else {
            const t = std.fmt.bufPrint(buf[pos..], ",\"medianLcxMicroUsd\":null}}}}", .{})
                catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
            pos += t.len;
        }
        return alloc.dupe(u8, buf[0..pos]);
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[],\"medianBtcMicroUsd\":null,\"medianLcxMicroUsd\":null}}}}",
        .{id});
}

// ─── omnibus_getallprices / omnibus_getarbitrage ────────────────────────────
//
// These two handlers depend on the *new* ExchangeFeed API being landed in
// core/ws_exchange_feed.zig by the parallel refactor agent.

/// Direct call to ExchangeFeed.getAllPrices (full unbounded PriceMap snapshot).
fn feedGetAllPrices(
    feed: *ws_exchange_feed_mod.ExchangeFeed,
    alloc: std.mem.Allocator,
) ![]ws_exchange_feed_mod.PriceFetch {
    return feed.getAllPrices(alloc);
}

/// Direct call to PriceFetch.isStale method (added in parallel refactor).
fn feedIsStale(
    p: ws_exchange_feed_mod.PriceFetch,
    now_ms: i64,
    threshold_ms: i64,
) bool {
    return p.isStale(now_ms, threshold_ms);
}

/// Canonicalize a pair label so cross-exchange variants line up.
threadlocal var CANON_BUF: [16][32]u8 = std.mem.zeroes([16][32]u8);
threadlocal var CANON_IDX: usize = 0;

fn canonicalPair(pair: []const u8) []const u8 {
    // Find separator
    const sep_idx: usize = blk: {
        for (pair, 0..) |c, idx| {
            if (c == '/' or c == '-') break :blk idx;
        }
        break :blk pair.len; // no separator → return as-is
    };
    if (sep_idx == 0 or sep_idx >= pair.len - 1) return pair;

    var base = pair[0..sep_idx];
    const quote = pair[sep_idx + 1 ..];

    // Kraken legacy normalization: XBT/XDG in BASE.
    if (std.mem.eql(u8, base, "XBT")) base = "BTC";
    if (std.mem.eql(u8, base, "XDG")) base = "DOGE";

    // Quote bucket normalization (matches pair_discovery.py).
    var qbucket: []const u8 = quote;
    if (std.mem.eql(u8, quote, "USD") or
        std.mem.eql(u8, quote, "USDC") or
        std.mem.eql(u8, quote, "USDT") or
        std.mem.eql(u8, quote, "DAI") or
        std.mem.eql(u8, quote, "USDS"))
    {
        qbucket = "USD";
    } else if (std.mem.eql(u8, quote, "EUR") or std.mem.eql(u8, quote, "EURC")) {
        qbucket = "EUR";
    }

    // Build "<base>/<qbucket>" in a thread-local rotating buffer.
    const slot = &CANON_BUF[CANON_IDX];
    CANON_IDX = (CANON_IDX + 1) % CANON_BUF.len;
    const total_len = base.len + 1 + qbucket.len;
    if (total_len > slot.len) return pair; // safety: weird long pair, return original
    @memcpy(slot[0..base.len], base);
    slot[base.len] = '/';
    @memcpy(slot[base.len + 1 .. base.len + 1 + qbucket.len], qbucket);
    return slot[0..total_len];
}

/// omnibus_getallprices — paginated dump of every PriceFetch the feed holds.
pub fn handleOmnibusAllPrices(ctx: *ServerCtx, body: []const u8, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (main_mod.g_ws_feed) |*feed| {
        const offset: usize = @intCast(rpc.extractArrayNum(body, 0));
        const limit_raw = rpc.extractArrayNum(body, 1);
        const limit: usize = if (limit_raw == 0) 1000 else @intCast(limit_raw);

        // WIRE-UP-MARKER: feed.getAllPrices(alloc) once API lands.
        const all = try feedGetAllPrices(feed, alloc);
        defer alloc.free(all);

        const total = all.len;
        const start = if (offset >= total) total else offset;
        const want_end = start +| limit;
        const end = if (want_end > total) total else want_end;

        const BUF_SZ: usize = 256 * 1024;
        var buf = try alloc.alloc(u8, BUF_SZ);
        defer alloc.free(buf);

        const now_ms = std.time.milliTimestamp();
        var pos: usize = 0;

        const prefix = std.fmt.bufPrint(buf[pos..],
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[", .{id})
            catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        var last_update_ms: i64 = 0;
        var emitted: usize = 0;
        var i: usize = start;
        while (i < end) : (i += 1) {
            const p = all[i];
            const stale = feedIsStale(p, now_ms, 30_000);
            const sep = if (emitted == 0) "" else ",";
            const entry = std.fmt.bufPrint(buf[pos..],
                "{s}{{\"exchange\":\"{s}\",\"pair\":\"{s}\",\"bidMicroUsd\":{d},\"askMicroUsd\":{d},\"timestampMs\":{d},\"success\":{s},\"stale\":{s}}}",
                .{
                    sep, p.exchange, p.pair, p.bid_micro_usd, p.ask_micro_usd,
                    p.timestamp_ms,
                    if (p.success) "true" else "false",
                    if (stale) "true" else "false",
                },
            ) catch {
                break;
            };
            pos += entry.len;
            emitted += 1;
            if (p.timestamp_ms > last_update_ms) last_update_ms = p.timestamp_ms;
        }

        const suffix = std.fmt.bufPrint(buf[pos..],
            "],\"count\":{d},\"offset\":{d},\"limit\":{d},\"total\":{d},\"lastUpdateMs\":{d}}}}}",
            .{ emitted, start, limit, total, last_update_ms })
            catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += suffix.len;

        return alloc.dupe(u8, buf[0..pos]);
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"prices\":[],\"count\":0,\"offset\":0,\"limit\":0,\"total\":0,\"lastUpdateMs\":0}}}}",
        .{id});
}

/// omnibus_getfxrate — current EUR→USD multiplier.
pub fn handleOmnibusFxRate(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (main_mod.g_ws_feed) |*feed| {
        const rate = feed.getEurToUsdRate();
        if (rate) |r| {
            const whole = r / 1_000_000;
            const frac = r % 1_000_000;
            return std.fmt.allocPrint(alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"eurToUsdMicro\":{d},\"eurToUsd\":\"{d}.{d:0>6}\"}}}}",
                .{ id, r, whole, frac });
        }
    }
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"eurToUsdMicro\":null,\"eurToUsd\":null}}}}",
        .{id});
}

/// omnibus_getarbitrage — pre-compute cross-exchange arbitrage opportunities.
pub fn handleOmnibusArbitrage(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    if (main_mod.g_ws_feed) |*feed| {
        // WIRE-UP-MARKER: feed.getAllPrices(alloc) once API lands.
        const all = try feedGetAllPrices(feed, alloc);
        defer alloc.free(all);

        const now_ms = std.time.milliTimestamp();
        const eur_to_usd_micro: ?u64 = feed.getEurToUsdRate();
        _ = eur_to_usd_micro;
        var fresh = try alloc.alloc(ws_exchange_feed_mod.PriceFetch, all.len);
        defer alloc.free(fresh);
        var fresh_n: usize = 0;
        const ARBITRAGE_STALE_MS: i64 = 5 * 60 * 1000; // 5 min
        for (all) |p| {
            if (!p.success) continue;
            if (feedIsStale(p, now_ms, ARBITRAGE_STALE_MS)) continue;
            if (p.bid_micro_usd == 0 or p.ask_micro_usd == 0) continue;
            if (std.mem.eql(u8, p.pair, "USDC/EUR") or
                std.mem.eql(u8, p.pair, "USDC-EUR") or
                std.mem.eql(u8, p.pair, "USDT/EUR") or
                std.mem.eql(u8, p.pair, "USDT-EUR") or
                std.mem.eql(u8, p.pair, "DAI/EUR")) continue;
            fresh[fresh_n] = p;
            fresh_n += 1;
        }

        const Opp = struct {
            pair: []const u8,
            buy_ex: []const u8,
            sell_ex: []const u8,
            buy_ask: u64,
            sell_bid: u64,
            spread_micro: u64,
            spread_pct: f64,
            buy_ts: i64,
            sell_ts: i64,
        };

        const max_combos: usize = if (fresh_n == 0) 1 else fresh_n * fresh_n;
        var opps = try alloc.alloc(Opp, max_combos);
        defer alloc.free(opps);
        var opps_n: usize = 0;

        var canon_labels = try alloc.alloc([]u8, fresh_n);
        defer {
            for (canon_labels) |s| alloc.free(s);
            alloc.free(canon_labels);
        }
        for (fresh[0..fresh_n], 0..) |p, idx| {
            const c = canonicalPair(p.pair);
            canon_labels[idx] = try alloc.dupe(u8, c);
        }

        var i: usize = 0;
        while (i < fresh_n) : (i += 1) {
            var j: usize = 0;
            while (j < fresh_n) : (j += 1) {
                if (i == j) continue;
                const buy = fresh[i];
                const sell = fresh[j];
                if (!std.mem.eql(u8, canon_labels[i], canon_labels[j])) continue;
                if (std.mem.eql(u8, buy.exchange, sell.exchange)) continue;
                if (sell.bid_micro_usd <= buy.ask_micro_usd) continue;
                if (buy.ask_micro_usd < 1000 or sell.bid_micro_usd < 1000) continue;
                const spread = sell.bid_micro_usd - buy.ask_micro_usd;
                const pct = (@as(f64, @floatFromInt(spread)) /
                             @as(f64, @floatFromInt(buy.ask_micro_usd))) * 100.0;
                if (pct <= 0.05) continue;
                if (pct > 50.0) continue;
                opps[opps_n] = .{
                    .pair = canon_labels[i],
                    .buy_ex = buy.exchange,
                    .sell_ex = sell.exchange,
                    .buy_ask = buy.ask_micro_usd,
                    .sell_bid = sell.bid_micro_usd,
                    .spread_micro = spread,
                    .spread_pct = pct,
                    .buy_ts = buy.timestamp_ms,
                    .sell_ts = sell.timestamp_ms,
                };
                opps_n += 1;
            }
        }

        var k: usize = 1;
        while (k < opps_n) : (k += 1) {
            var m = k;
            while (m > 0 and opps[m - 1].spread_pct < opps[m].spread_pct) : (m -= 1) {
                const tmp = opps[m - 1];
                opps[m - 1] = opps[m];
                opps[m] = tmp;
            }
        }

        const cap: usize = if (opps_n > 50) 50 else opps_n;

        const BUF_SZ: usize = 256 * 1024;
        var buf = try alloc.alloc(u8, BUF_SZ);
        defer alloc.free(buf);
        var pos: usize = 0;

        const prefix = std.fmt.bufPrint(buf[pos..],
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"opportunities\":[", .{id})
            catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += prefix.len;

        var emitted: usize = 0;
        var idx: usize = 0;
        while (idx < cap) : (idx += 1) {
            const o = opps[idx];
            const sep = if (emitted == 0) "" else ",";
            const entry = std.fmt.bufPrint(buf[pos..],
                "{s}{{\"pair\":\"{s}\",\"buyAt\":\"{s}\",\"buyAskMicroUsd\":{d},\"sellAt\":\"{s}\",\"sellBidMicroUsd\":{d},\"spreadMicroUsd\":{d},\"spreadPct\":{d:.4},\"buyTimestampMs\":{d},\"sellTimestampMs\":{d}}}",
                .{
                    sep, o.pair, o.buy_ex, o.buy_ask, o.sell_ex, o.sell_bid,
                    o.spread_micro, o.spread_pct, o.buy_ts, o.sell_ts,
                },
            ) catch break;
            pos += entry.len;
            emitted += 1;
        }

        const suffix = std.fmt.bufPrint(buf[pos..],
            "],\"count\":{d}}}}}", .{emitted})
            catch return rpc.errorJson(-32603, "buf overflow", id, alloc);
        pos += suffix.len;

        return alloc.dupe(u8, buf[0..pos]);
    }

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"opportunities\":[],\"count\":0}}}}",
        .{id});
}

/// omnibus_getorderbook — placeholder (matching engine not heap-allocated yet)
pub fn handleOmnibusOrderbook(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pair = rpc.extractStr(body, "pair") orelse rpc.extractArrayStr(body, 0) orelse "OMNI/USDC";
    _ = pair;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"bids\":[],\"asks\":[],\"note\":\"Matching engine active — connect via P2P for live orderbook\"}}}}",
        .{id},
    );
}

/// omnibus_gettotalmined — total OMNI minted via mining since genesis.
pub fn handleOmnibusTotalMined(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const tip = ctx.bc.getBlockCount(); // chain length (height + 1)
    var total_sat: u64 = 0;
    var h: u64 = 1; // skip genesis
    while (h < tip) : (h += 1) {
        total_sat +%= blockchain_mod.blockRewardAt(h);
    }
    const omni_int  = total_sat / 1_000_000_000;
    const omni_frac = total_sat % 1_000_000_000;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"totalMinedSAT\":{d},\"totalMinedOMNI\":\"{d}.{d:0>9}\",\"blockHeight\":{d}}}}}",
        .{ id, total_sat, omni_int, omni_frac, if (tip == 0) 0 else tip - 1 },
    );
}

/// omnibus_bridge_limits — public-facing bridge configuration.
pub fn handleOmnibusBridgeLimits(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"maxPerTxSAT\":{d}," ++
            "\"maxDailySAT\":{d}," ++
            "\"dailyWindowBlocks\":{d}," ++
            "\"requiredSigs\":{d}," ++
            "\"maxRelayers\":{d}," ++
            "\"challengeWindowBlocks\":{d}," ++
            "\"autoPauseFractionBps\":{d}," ++
            "\"vaultAddrHex\":\"{s}\"" ++
        "}}}}",
        .{
            id,
            chain_config.BRIDGE_MAX_PER_TX_SAT,
            chain_config.BRIDGE_MAX_DAILY_SAT,
            chain_config.BRIDGE_DAILY_WINDOW_BLOCKS,
            chain_config.BRIDGE_REQUIRED_SIGS,
            chain_config.BRIDGE_MAX_RELAYERS,
            chain_config.BRIDGE_CHALLENGE_WINDOW_BLOCKS,
            chain_config.BRIDGE_AUTO_PAUSE_BLOCK_FRACTION_BPS,
            chain_config.BRIDGE_VAULT_ADDR_HEX,
        },
    );
}

/// omnibus_getoraclepolicy — return current price-deviation policy as JSON.
pub fn handleOmnibusGetOraclePolicy(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    main_mod.g_oracle_policy_mutex.lock();
    const pol = main_mod.g_oracle_policy;
    main_mod.g_oracle_policy_mutex.unlock();
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"warn_pct\":{d:.4},\"reject_pct\":{d:.4},\"fillgap_pct\":{d:.4},\"enabled\":{s}}}}}",
        .{ id, pol.warn_pct, pol.reject_pct, pol.fillgap_pct, if (pol.enabled) "true" else "false" },
    );
}

/// omnibus_setoraclepolicy — atomically replace the price-deviation policy.
pub fn handleOmnibusSetOraclePolicy(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    main_mod.g_oracle_policy_mutex.lock();
    var pol = main_mod.g_oracle_policy;

    if (rpc.extractParamObjectFloat(body, "warn_pct")) |v| pol.warn_pct = v;
    if (rpc.extractParamObjectFloat(body, "reject_pct")) |v| pol.reject_pct = v;
    if (rpc.extractParamObjectFloat(body, "fillgap_pct")) |v| pol.fillgap_pct = v;
    if (rpc.extractParamObjectBool(body, "enabled")) |v| pol.enabled = v;

    if (rpc.extractParamArrayFloats(body)) |vals| {
        if (vals.count >= 1) pol.warn_pct = vals.values[0];
        if (vals.count >= 2) pol.reject_pct = vals.values[1];
        if (vals.count >= 3) pol.fillgap_pct = vals.values[2];
        if (vals.bool_present) pol.enabled = vals.bool_value;
    }

    main_mod.g_oracle_policy = pol;
    main_mod.g_oracle_policy_mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"warn_pct\":{d:.4},\"reject_pct\":{d:.4},\"fillgap_pct\":{d:.4},\"enabled\":{s}}}}}",
        .{ id, pol.warn_pct, pol.reject_pct, pol.fillgap_pct, if (pol.enabled) "true" else "false" },
    );
}
