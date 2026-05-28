// Post-quantum signature JSON-RPC handlers — list PQ schemes, query
// PQ balances, send PQ-signed TXs, manage PQ attestations & identity.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const pq_crypto_mod = @import("../pq_crypto.zig");
const transaction_mod = @import("../transaction.zig");
const isolated_wallet_mod = @import("../isolated_wallet.zig");
const hex_utils = @import("../hex_utils.zig");
const mempool_mod = @import("../mempool.zig");

const ServerCtx = rpc.ServerCtx;

/// auto-discovery. Nu modifica state.
///
/// 0..4 = original isolated wallets (OMNI primary + 4 reputation cups,
///        last one being non-signing KEM).
/// 5..8 = PQ-OMNI — transferable OMNI wallets with post-quantum signing,
///        added 2026-04-30. Same balance semantics as omni_ecdsa, only
///        the signature scheme differs.
pub fn handlePqListSchemes(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[" ++
            "{{\"scheme\":\"omni_ecdsa\",\"code\":0,\"address_prefix\":\"ob1q\",\"transferable\":true}}," ++
            "{{\"scheme\":\"love_dilithium\",\"code\":1,\"address_prefix\":\"ob_k1_\",\"transferable\":false}}," ++
            "{{\"scheme\":\"food_falcon\",\"code\":2,\"address_prefix\":\"ob_f5_\",\"transferable\":false}}," ++
            "{{\"scheme\":\"rent_ml_dsa\",\"code\":3,\"address_prefix\":\"ob_d5_\",\"transferable\":false}}," ++
            "{{\"scheme\":\"vacation_slh_dsa\",\"code\":4,\"address_prefix\":\"ob_s3_\",\"transferable\":false}}," ++
            // Canon transferable PQ-OMNI prefixes — must match
            // core/transaction.zig:prefix() and STATUS/MASTER_RULES_PQ_OMNI.md.
            "{{\"scheme\":\"pq_omni_ml_dsa\",\"code\":5,\"address_prefix\":\"obk1_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"pq_omni_falcon\",\"code\":6,\"address_prefix\":\"obf5_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"pq_omni_dilithium\",\"code\":7,\"address_prefix\":\"obd5_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"pq_omni_slh_dsa\",\"code\":8,\"address_prefix\":\"obs3_\",\"transferable\":true}}," ++
            // Hybrid uses the same address prefixes as the PQ-OMNI scheme half;
            // chain distinguishes via tx.scheme byte, not by prefix.
            "{{\"scheme\":\"hybrid_q1\",\"code\":9,\"address_prefix\":\"obk1_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"hybrid_q2\",\"code\":10,\"address_prefix\":\"obf5_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"hybrid_q3\",\"code\":11,\"address_prefix\":\"obd5_\",\"transferable\":true}}," ++
            "{{\"scheme\":\"hybrid_q4\",\"code\":12,\"address_prefix\":\"obs3_\",\"transferable\":true}}" ++
        "]}}",
        .{id});
}

/// pq_balance — balance + scheme deduse din prefixul adresei. Read-only.
/// Reuse `bc.getAddressBalance` (acelasi balanta ca pentru orice adresa).
pub fn handlePqBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const addr = rpc.extractArrayStr(body, 0) orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    const scheme_opt = isolated_wallet_mod.Scheme.fromAddress(addr);
    if (scheme_opt == null) {
        return rpc.errorJson(-32602, "Address prefix does not match any PQ scheme (ob1q/ob_k1_/ob_f5_/ob_d5_/ob_s3_)", id, alloc);
    }
    const scheme = scheme_opt.?;
    const balance = ctx.bc.getAddressBalance(addr);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"address\":\"{s}\"," ++
            "\"scheme\":\"{s}\"," ++
            "\"code\":{d}," ++
            "\"address_prefix\":\"{s}\"," ++
            "\"balance\":{d}" ++
        "}}}}",
        .{ id, addr, @tagName(scheme), @intFromEnum(scheme), scheme.prefix(), balance });
}

/// pq_verify_test — debug RPC. Apeleaza isolated_wallet.verifySignature DIRECT
/// pe (scheme, message_bytes, signature_bytes, pubkey_bytes), bypass TX hash.
/// Folosit pentru a confirma ca librariile noble (frontend) si liboqs (chain)
/// sunt interoperabile la nivel de bytes ai semnaturii.
///
/// Params (object): scheme (string sau cod 5..8), public_key (hex), message (hex), signature (hex).
/// Returns: {"verified": true|false, "scheme": "...", "msg_len": N, "pk_len": N, "sig_len": N}
pub fn handlePqVerifyTest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const scheme_str = rpc.extractStr(body, "scheme") orelse "";
    const scheme_num = rpc.extractArrayNumByKey(body, "scheme");
    const pubkey_hex = rpc.extractStr(body, "public_key") orelse rpc.extractStr(body, "publicKey") orelse
        return rpc.errorJson(-32602, "Missing public_key (hex)", id, alloc);
    const message_hex = rpc.extractStr(body, "message") orelse rpc.extractStr(body, "msg") orelse
        return rpc.errorJson(-32602, "Missing message (hex)", id, alloc);
    const signature_hex = rpc.extractStr(body, "signature") orelse rpc.extractStr(body, "sig") orelse
        return rpc.errorJson(-32602, "Missing signature (hex)", id, alloc);

    const scheme: isolated_wallet_mod.Scheme = blk: {
        if (scheme_str.len > 0) {
            if (std.mem.eql(u8, scheme_str, "pq_omni_ml_dsa")    or std.mem.eql(u8, scheme_str, "ml_dsa_87"))    break :blk .pq_omni_ml_dsa;
            if (std.mem.eql(u8, scheme_str, "pq_omni_falcon")    or std.mem.eql(u8, scheme_str, "falcon_512"))   break :blk .pq_omni_falcon;
            if (std.mem.eql(u8, scheme_str, "pq_omni_dilithium") or std.mem.eql(u8, scheme_str, "dilithium_5"))  break :blk .pq_omni_dilithium;
            if (std.mem.eql(u8, scheme_str, "pq_omni_slh_dsa")   or std.mem.eql(u8, scheme_str, "slh_dsa_256s")) break :blk .pq_omni_slh_dsa;
            return rpc.errorJson(-32602, "Unknown scheme name (use ml_dsa_87/falcon_512/dilithium_5/slh_dsa_256s)", id, alloc);
        }
        if (scheme_num >= 5 and scheme_num <= 8) break :blk @enumFromInt(@as(u8, @intCast(scheme_num)));
        return rpc.errorJson(-32602, "Provide scheme (string) or scheme code 5..8", id, alloc);
    };

    if (pubkey_hex.len % 2 != 0)    return rpc.errorJson(-32602, "public_key hex length odd", id, alloc);
    if (message_hex.len % 2 != 0)   return rpc.errorJson(-32602, "message hex length odd", id, alloc);
    if (signature_hex.len % 2 != 0) return rpc.errorJson(-32602, "signature hex length odd", id, alloc);

    const pk_bytes  = alloc.alloc(u8, pubkey_hex.len / 2)    catch return rpc.errorJson(-32603, "OOM pk", id, alloc);
    defer alloc.free(pk_bytes);
    const msg_bytes = alloc.alloc(u8, message_hex.len / 2)   catch return rpc.errorJson(-32603, "OOM msg", id, alloc);
    defer alloc.free(msg_bytes);
    const sig_bytes = alloc.alloc(u8, signature_hex.len / 2) catch return rpc.errorJson(-32603, "OOM sig", id, alloc);
    defer alloc.free(sig_bytes);

    hex_utils.hexToBytes(pubkey_hex, pk_bytes)     catch return rpc.errorJson(-32602, "public_key not valid hex", id, alloc);
    hex_utils.hexToBytes(message_hex, msg_bytes)   catch return rpc.errorJson(-32602, "message not valid hex", id, alloc);
    hex_utils.hexToBytes(signature_hex, sig_bytes) catch return rpc.errorJson(-32602, "signature not valid hex", id, alloc);

    const ok = isolated_wallet_mod.verifySignature(scheme, msg_bytes, sig_bytes, pk_bytes);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"verified\":{},\"scheme\":\"{s}\",\"msg_len\":{d},\"pk_len\":{d},\"sig_len\":{d}}}}}",
        .{ id, ok, @tagName(scheme), msg_bytes.len, pk_bytes.len, sig_bytes.len });
}

/// pq_send — construieste si submite o tranzactie semnata cu o scheme PQ.
/// Required: scheme (0..4 sau nume), from, to, amount, signature, public_key.
/// Optional: op_return, fee, nonce.
///
/// Semnatura PQ este verificata aici (chain-side) inainte de a o adauga in
/// mempool. Format mesaj canonic: hash-ul standard al TX (calculateHash).
pub fn handlePqSend(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // 1. Parametri obligatorii
    const from = rpc.extractStr(body, "from") orelse rpc.extractStr(body, "from_address") orelse
        return rpc.errorJson(-32602, "Missing param: from", id, alloc);
    const to = rpc.extractStr(body, "to") orelse rpc.extractStr(body, "to_address") orelse
        return rpc.errorJson(-32602, "Missing param: to", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature (hex pentru omni, raw bytes hex pentru PQ)", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "public_key") orelse rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: public_key", id, alloc);

    const amount = rpc.extractArrayNumByKey(body, "amount");
    if (amount == 0) {
        // Permitem amount=0 pentru op_return-only TXs, dar trebuie OP_RETURN nenul
        // (validat ulterior in tx.isValid)
    }
    const op_return = rpc.extractStr(body, "op_return") orelse rpc.extractStr(body, "opReturn") orelse "";
    const fee_raw = rpc.extractArrayNumByKey(body, "fee");
    const fee_sat: u64 = if (fee_raw > 0) fee_raw else mempool_mod.TX_MIN_FEE_SAT;

    // 2. Determina scheme — accepta nume sau cod numeric
    const scheme_str_opt = rpc.extractStr(body, "scheme");
    const scheme_num = rpc.extractArrayNumByKey(body, "scheme");
    const scheme: isolated_wallet_mod.Scheme = blk: {
        if (scheme_str_opt) |s| {
            if (std.mem.eql(u8, s, "omni_ecdsa") or std.mem.eql(u8, s, "omni")) break :blk .omni_ecdsa;
            if (std.mem.eql(u8, s, "love_dilithium") or std.mem.eql(u8, s, "love")) break :blk .love_dilithium;
            if (std.mem.eql(u8, s, "food_falcon") or std.mem.eql(u8, s, "food")) break :blk .food_falcon;
            if (std.mem.eql(u8, s, "rent_ml_dsa") or std.mem.eql(u8, s, "rent")) break :blk .rent_ml_dsa;
            if (std.mem.eql(u8, s, "vacation_slh_dsa") or std.mem.eql(u8, s, "vacation")) break :blk .vacation_slh_dsa;
            if (std.mem.eql(u8, s, "pq_omni_ml_dsa")) break :blk .pq_omni_ml_dsa;
            if (std.mem.eql(u8, s, "pq_omni_falcon")) break :blk .pq_omni_falcon;
            if (std.mem.eql(u8, s, "pq_omni_dilithium")) break :blk .pq_omni_dilithium;
            if (std.mem.eql(u8, s, "pq_omni_slh_dsa")) break :blk .pq_omni_slh_dsa;
            if (std.mem.eql(u8, s, "hybrid_q1")) break :blk .hybrid_q1;
            if (std.mem.eql(u8, s, "hybrid_q2")) break :blk .hybrid_q2;
            if (std.mem.eql(u8, s, "hybrid_q3")) break :blk .hybrid_q3;
            if (std.mem.eql(u8, s, "hybrid_q4")) break :blk .hybrid_q4;
            return rpc.errorJson(-32602, "Unknown scheme name", id, alloc);
        }
        if (scheme_num <= 12) break :blk @enumFromInt(@as(u8, @intCast(scheme_num)));
        return rpc.errorJson(-32602, "scheme must be 0..12 or a name string", id, alloc);
    };

    // 3. VACATION (KEM) nu poate semna
    if (scheme == .vacation_slh_dsa) {
        return rpc.errorJson(-32602, "vacation_slh_dsa cannot sign transactions (KEM is encapsulation-only)", id, alloc);
    }

    // 4. Verifica prefix adresa from corespunde scheme-ului
    const expected_prefix = scheme.prefix();
    if (!std.mem.startsWith(u8, from, expected_prefix)) {
        return rpc.errorJson(-32602, "from address prefix does not match scheme", id, alloc);
    }

    // 5. Construim TX. id si timestamp sunt parte din hash-ul semnat,
    //    deci trebuie sa fie EXACT cele pe care clientul le-a folosit la semnare.
    //    Acceptam ambele din body; daca lipsesc, fallback la counter/now (util doar
    //    pt. omni_ecdsa unde semnatura se recupereaza din hash, NU pt. PQ).
    const tx_id_param = rpc.extractArrayNumByKey(body, "id");
    const tx_id: u32 = if (tx_id_param > 0)
        @intCast(@min(tx_id_param, std.math.maxInt(u32)))
    else
        rpc.g_tx_counter.fetchAdd(1, .monotonic);
    const ts_param = rpc.extractArrayNumByKey(body, "timestamp");
    const ts_now: i64 = if (ts_param > 0) @as(i64, @intCast(ts_param)) else std.time.timestamp();
    const nonce_param = rpc.extractArrayNumByKey(body, "nonce");
    const nonce = if (nonce_param > 0) nonce_param else ctx.bc.getNextAvailableNonce(from);

    const from_owned = try alloc.dupe(u8, from);
    errdefer alloc.free(from_owned);
    const to_owned = try alloc.dupe(u8, to);
    errdefer alloc.free(to_owned);
    const op_owned: []const u8 = if (op_return.len > 0) try alloc.dupe(u8, op_return) else "";
    errdefer if (op_owned.len > 0) alloc.free(op_owned);
    const sig_owned = try alloc.dupe(u8, sig_hex);
    errdefer alloc.free(sig_owned);
    const pk_owned = try alloc.dupe(u8, pubkey_hex);
    errdefer alloc.free(pk_owned);

    var tx = transaction_mod.Transaction{
        .id           = tx_id,
        .scheme       = @as(transaction_mod.Scheme, @enumFromInt(@intFromEnum(scheme))),
        .from_address = from_owned,
        .to_address   = to_owned,
        .amount       = amount,
        .fee          = fee_sat,
        .timestamp    = ts_now,
        .nonce        = nonce,
        .op_return    = op_owned,
        .signature    = sig_owned,
        .hash         = "",
        .public_key   = pk_owned,
    };

    // 6. Calculeaza hash-ul TX si stocheaza-l in formă hex (verificat in validateTransaction)
    const tx_hash_bytes = tx.calculateHash();
    const tx_hash_hex = try alloc.alloc(u8, tx_hash_bytes.len * 2);
    {
        const hex_chars = "0123456789abcdef";
        for (tx_hash_bytes, 0..) |b, hi| {
            tx_hash_hex[hi * 2] = hex_chars[b >> 4];
            tx_hash_hex[hi * 2 + 1] = hex_chars[b & 0xF];
        }
    }
    tx.hash = tx_hash_hex;

    // 7. Verifica semnatura inainte de submit. Mesajul = bytes raw ai tx_hash.
    //    Pentru OMNI, signature-ul este 128 chars hex si pubkey 66 chars hex.
    //    Pentru PQ, signature/pubkey sunt hex de lungime variabila (per scheme).
    //    Pentru HYBRID (9..12), signature e "ecdsa_hex|pq_hex" si avem 2 pubkeys.
    const sig_ok = blk_verify: {
        if (scheme == .omni_ecdsa) {
            // Path OMNI: secp256k1 ECDSA pe hash-ul TX
            break :blk_verify isolated_wallet_mod.verifyOmniSignature(&tx_hash_bytes, sig_hex, pubkey_hex);
        }
        if (scheme.isHybrid()) {
            // Path HYBRID: avem nevoie si de pq_public_key in body
            const pq_pubkey_hex = rpc.extractStr(body, "pq_public_key") orelse rpc.extractStr(body, "pqPublicKey") orelse {
                return rpc.errorJson(-32602, "Missing param: pq_public_key (required for hybrid schemes 9..12)", id, alloc);
            };
            // Decode pq pubkey din hex la bytes
            if (pq_pubkey_hex.len % 2 != 0) break :blk_verify false;
            const pq_pk_bytes = alloc.alloc(u8, pq_pubkey_hex.len / 2) catch return rpc.errorJson(-32603, "OOM decoding pq_public_key", id, alloc);
            defer alloc.free(pq_pk_bytes);
            hex_utils.hexToBytes(pq_pubkey_hex, pq_pk_bytes) catch break :blk_verify false;
            // sig_hex contine "ecdsa_hex|pq_hex" ca ASCII; pubkey_hex = ECDSA pubkey hex
            break :blk_verify isolated_wallet_mod.verifyHybridSignature(
                scheme,
                &tx_hash_bytes,
                sig_hex,
                pubkey_hex,
                pq_pk_bytes,
            );
        }
        // Path PQ pur: decode hex bytes, dispatch via verifySignature
        const sig_bytes = alloc.alloc(u8, sig_hex.len / 2) catch return rpc.errorJson(-32603, "OOM decoding signature", id, alloc);
        defer alloc.free(sig_bytes);
        _ = hex_utils.hexToBytes(sig_hex, sig_bytes) catch break :blk_verify false;

        const pk_bytes = alloc.alloc(u8, pubkey_hex.len / 2) catch return rpc.errorJson(-32603, "OOM decoding public_key", id, alloc);
        defer alloc.free(pk_bytes);
        _ = hex_utils.hexToBytes(pubkey_hex, pk_bytes) catch break :blk_verify false;

        break :blk_verify isolated_wallet_mod.verifySignature(scheme, &tx_hash_bytes, sig_bytes, pk_bytes);
    };
    if (!sig_ok) {
        return rpc.errorJson(-32000, "Signature verification failed", id, alloc);
    }

    // 8. Inregistreaza pubkey si submite TX in mempool
    if (scheme == .omni_ecdsa and pubkey_hex.len == 66) {
        ctx.bc.registerPubkey(from, pubkey_hex) catch {};
    }
    ctx.bc.addTransaction(tx) catch |err| {
        return rpc.errorJson(-32000, switch (err) {
            error.InvalidTransaction => "Transaction validation failed",
            else => "Mempool error",
        }, id, alloc);
    };

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"txid\":\"{s}\"," ++
            "\"scheme\":\"{s}\"," ++
            "\"code\":{d}," ++
            "\"from\":\"{s}\"," ++
            "\"to\":\"{s}\"," ++
            "\"amount\":{d}," ++
            "\"fee\":{d}," ++
            "\"nonce\":{d}," ++
            "\"status\":\"accepted\"" ++
        "}}}}",
        .{ id, tx.hash, @tagName(scheme), @intFromEnum(scheme), tx.from_address, tx.to_address, tx.amount, tx.fee, tx.nonce });
}

/// pq_attestation — scaneaza chain-ul pentru tranzactii cu OP_RETURN
/// `pq_attest:<domain>:<pq_address>` trimise de la `omni_address`.
/// Returneaza ultima inregistrare gasita + numarul de confirmari.
pub fn handlePqAttestation(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const omni_addr = rpc.extractStr(body, "omni_address") orelse rpc.extractStr(body, "from") orelse
        return rpc.errorJson(-32602, "Missing param: omni_address", id, alloc);
    const domain = rpc.extractStr(body, "domain") orelse
        return rpc.errorJson(-32602, "Missing param: domain (love/food/rent/vacation)", id, alloc);

    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "pq_attest:{s}:", .{domain}) catch
        return rpc.errorJson(-32603, "Domain too long", id, alloc);

    // Scaneaza chain-ul invers (cele mai recente blocuri primele)
    var latest_tx_hash: []const u8 = "";
    var latest_pq_addr: []const u8 = "";
    var latest_block_height: u64 = 0;
    var latest_timestamp: i64 = 0;
    var found = false;

    var i: usize = ctx.bc.chain.items.len;
    while (i > 0) {
        i -= 1;
        const block = &ctx.bc.chain.items[i];
        for (block.transactions.items) |*tx| {
            if (!std.mem.eql(u8, tx.from_address, omni_addr)) continue;
            if (!std.mem.startsWith(u8, tx.op_return, prefix)) continue;
            // Match — extract pq_address (totul dupa prefix)
            latest_tx_hash = tx.hash;
            latest_pq_addr = tx.op_return[prefix.len..];
            latest_block_height = @intCast(i);
            latest_timestamp = tx.timestamp;
            found = true;
            break;
        }
        if (found) break;
    }

    if (!found) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    }

    const confirmations = ctx.bc.getConfirmations(latest_tx_hash) orelse 0;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"omni_address\":\"{s}\"," ++
            "\"domain\":\"{s}\"," ++
            "\"pq_address\":\"{s}\"," ++
            "\"txid\":\"{s}\"," ++
            "\"block_height\":{d}," ++
            "\"timestamp\":{d}," ++
            "\"confirmations\":{d}" ++
        "}}}}",
        .{ id, omni_addr, domain, latest_pq_addr, latest_tx_hash, latest_block_height, latest_timestamp, confirmations });
}

// ── getpqidentity ─────────────────────────────────────────────────────────────
// Returns the full PQ identity for an omni address (if registered via pq_attest_v1).

pub fn handleGetPqIdentity(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const omni_addr = rpc.extractStr(body, "address") orelse rpc.extractStr(body, "omni_address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);

    ctx.bc.mutex.lock();
    const identity = ctx.bc.pq_identity_map.get(omni_addr);
    ctx.bc.mutex.unlock();

    if (identity == null) {
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
    }
    const idt = identity.?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"omni_address\":\"{s}\"," ++
        "\"love\":\"{s}\"," ++
        "\"food\":\"{s}\"," ++
        "\"rent\":\"{s}\"," ++
        "\"vacation\":\"{s}\"," ++
        "\"btc\":\"{s}\"," ++
        "\"eth\":\"{s}\"," ++
        "\"attest_block\":{d}," ++
        "\"attest_tx\":\"{s}\"" ++
        "}}}}",
        .{ id, omni_addr,
           idt.loveSlice(), idt.foodSlice(), idt.rentSlice(), idt.vacationSlice(),
           idt.btcSlice(), idt.ethSlice(),
           idt.attest_block, idt.attestTxSlice() });
}

// ── sendpqattest ──────────────────────────────────────────────────────────────
// Broadcasts a pq_attest_v1 TX from the wallet. The frontend builds + signs
// the TX with the OMNI secp256k1 key and sends the raw op_return payload here.
// Format: { "from": "ob1q...", "love": "ob_k1_...", "food": "ob_f5_...",
//           "rent": "ob_d5_...", "vacation": "ob_s3_...",
//           "btc": "bc1q..." (opt), "eth": "0x..." (opt),
//           "signature": "hex...", "public_key": "hex...", "nonce": N }

pub fn handleSendPqAttest(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const from     = rpc.extractStr(body, "from")     orelse return rpc.errorJson(-32602, "Missing: from", id, alloc);
    const love     = rpc.extractStr(body, "love")     orelse return rpc.errorJson(-32602, "Missing: love", id, alloc);
    const food     = rpc.extractStr(body, "food")     orelse return rpc.errorJson(-32602, "Missing: food", id, alloc);
    const rent     = rpc.extractStr(body, "rent")     orelse return rpc.errorJson(-32602, "Missing: rent", id, alloc);
    const vacation = rpc.extractStr(body, "vacation") orelse return rpc.errorJson(-32602, "Missing: vacation", id, alloc);
    const sig      = rpc.extractStr(body, "signature")   orelse return rpc.errorJson(-32602, "Missing: signature", id, alloc);
    const pubkey   = rpc.extractStr(body, "public_key")  orelse return rpc.errorJson(-32602, "Missing: public_key", id, alloc);
    const nonce    = rpc.extractParamObjectU64(body, "nonce");

    // Validate soulbound prefixes
    if (!std.mem.startsWith(u8, love,     "ob_k1_")) return rpc.errorJson(-32602, "love must start with ob_k1_", id, alloc);
    if (!std.mem.startsWith(u8, food,     "ob_f5_")) return rpc.errorJson(-32602, "food must start with ob_f5_", id, alloc);
    if (!std.mem.startsWith(u8, rent,     "ob_d5_")) return rpc.errorJson(-32602, "rent must start with ob_d5_", id, alloc);
    if (!std.mem.startsWith(u8, vacation, "ob_s3_")) return rpc.errorJson(-32602, "vacation must start with ob_s3_", id, alloc);

    // First-claim check
    ctx.bc.mutex.lock();
    const already = ctx.bc.pq_identity_map.contains(from);
    ctx.bc.mutex.unlock();
    if (already) return rpc.errorJson(-32001, "Identity already registered for this address (first-claim wins)", id, alloc);

    // Build op_return payload
    const btc = rpc.extractStr(body, "btc") orelse "";
    const eth = rpc.extractStr(body, "eth") orelse "";
    const op_return = try std.fmt.allocPrint(alloc,
        "pq_attest_v1:{s}:{s}:{s}:{s}:{s}:{s}", .{ love, food, rent, vacation, btc, eth });
    defer alloc.free(op_return);

    // Build and submit TX (amount=0, self-send)
    const ts = std.time.timestamp();
    const tx_id: u32 = @intCast(std.time.milliTimestamp() & 0xFFFFFFFF);
    // Compute a provisional hash string from id+from+timestamp
    const tx_hash = try std.fmt.allocPrint(alloc, "{d}{s}{d}", .{ tx_id, from, ts });
    defer alloc.free(tx_hash);

    var tx = blockchain_mod.Transaction{
        .id           = tx_id,
        .from_address = from,
        .to_address   = from,
        .amount       = 0,
        .fee          = 1000,
        .timestamp    = ts,
        .nonce        = nonce,
        .op_return    = op_return,
        .signature    = sig,
        .public_key   = pubkey,
        .scheme       = .omni_ecdsa,
        .hash         = tx_hash,
    };
    // Replace provisional hash with canonical TX hash (hex-encoded)
    const hash_bytes = tx.calculateHash();
    const canonical = try std.fmt.allocPrint(alloc, "{s}", .{std.fmt.bytesToHex(hash_bytes, .lower)});
    tx.hash = canonical;

    ctx.bc.mutex.lock();
    ctx.bc.mempool.append(tx) catch {
        ctx.bc.mutex.unlock();
        return rpc.errorJson(-32603, "Mempool full", id, alloc);
    };
    ctx.bc.mutex.unlock();

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"status\":\"queued\",\"txid\":\"{s}\",\"op_return\":\"{s}\"}}}}",
        .{ id, canonical, op_return });
}
