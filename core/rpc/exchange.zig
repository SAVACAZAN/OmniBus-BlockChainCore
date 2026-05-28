// Exchange / grid-trading JSON-RPC handlers — native DEX matching engine,
// orderbook queries, API keys, deposits/withdrawals, grid strategy.

const std = @import("std");
const rpc = @import("../rpc_server.zig");
const blockchain_mod = @import("../blockchain.zig");
const matching_mod = @import("../matching_engine.zig");
const grid_mod = @import("../grid_engine.zig");
const fills_log_mod = @import("../fills_log.zig");
const orderbook_sync_mod = @import("../orderbook_sync.zig");
const token_whitelist = @import("../token_whitelist.zig");
const evm_escrow_mod = @import("../evm_escrow_watcher.zig");
const secp256k1_mod = @import("../secp256k1.zig");

const hex_utils = @import("../hex_utils.zig");
const swap_link_mod = @import("../order_swap_link.zig");
const registrar_mod = @import("../registrar_addresses.zig");
const transaction_mod = @import("../transaction.zig");
const kyc_mod = @import("../kyc.zig");
const main_mod = @import("../main.zig");
const ServerCtx = rpc.ServerCtx;

/// exchange_placeOrder — plaseaza o ordine semnata pe DEX-ul nativ.
/// Required: trader, side ("buy"|"sell"), pair, price, amount, nonce,
///           signature, publicKey. Optional: pairId (in lieu of pair).
/// Pretul e in micro-USD (u64), amount in SAT (u64).
pub fn handleExchangePlaceOrder(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = rpc.isPaperMode(body);
    const engine = rpc.pickEngine(ctx, is_paper) orelse
        return rpc.errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    const trader = rpc.extractStr(body, "trader") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: trader", id, alloc);
    const side_str = rpc.extractStr(body, "side") orelse
        return rpc.errorJson(-32602, "Missing param: side (buy|sell)", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);

    const price = rpc.extractArrayNumByKey(body, "price");
    const amount = rpc.extractArrayNumByKey(body, "amount");
    const nonce = rpc.extractArrayNumByKey(body, "nonce");

    if (price == 0) return rpc.errorJson(-32602, "Missing or zero: price", id, alloc);
    if (amount == 0) return rpc.errorJson(-32602, "Missing or zero: amount", id, alloc);
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // Determina pair_id: prefer "pair" label (string) când e prezent —
    // pairId=0 (OMNI/USD) e perfect valid și nu trebuie tratat ca "missing",
    // dar `rpc.extractArrayNumByKey` nu distinge missing de zero. Așa că prima
    // dată căutăm string-ul `pair`, apoi numărul.
    var pair_id: u16 = 0;
    if (rpc.extractStr(body, "pair")) |label| {
        pair_id = rpc.exchangePairLookup(label) orelse
            return rpc.errorJson(-32602, "Unknown pair (try OMNI/USD, BTC/USD, LCX/USD, ETH/USD)", id, alloc);
    } else {
        const pair_id_u = rpc.extractArrayNumByKey(body, "pairId");
        // pairId 0..MAX_PAIRS-1 valid. Nu putem verifica "missing" cu
        // sentinel 0 (e indistinct de pairId 0 = OMNI/USD), deci dacă nici
        // "pair" nici "pairId" key nu există, trebuie să detectăm asta
        // explicit prin substring match.
        const has_pair_id_key = std.mem.indexOf(u8, body, "\"pairId\"") != null;
        if (!has_pair_id_key) {
            return rpc.errorJson(-32602, "Missing param: pair or pairId", id, alloc);
        }
        pair_id = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    }

    // Oracle price-band: reject orders priced > rpc.ORDER_BAND_BPS bps from
    // the consensus oracle. Skip when oracle is unavailable, the pair has
    // no oracle feed (e.g. LCX), or the consensus price isn't valid yet.
    if (!is_paper) if (ctx.oracle) |oracle_ptr| {
        if (rpc.oracleChainForPair(pair_id)) |chain| {
            if (oracle_ptr.getPrice(chain)) |ref| {
                if (ref.is_valid and ref.price_micro_usd > 0) {
                    const ref_p = ref.price_micro_usd;
                    const diff = if (price > ref_p) price - ref_p else ref_p - price;
                    const dev_bps = (@as(u128, diff) * 10_000) / @as(u128, ref_p);
                    if (dev_bps > rpc.ORDER_BAND_BPS) {
                        const msg = std.fmt.allocPrint(alloc,
                            "oracle_band_exceeded: ref={d} price={d} band_bps={d} dev_bps={d}",
                            .{ ref_p, price, rpc.ORDER_BAND_BPS, dev_bps },
                        ) catch return rpc.errorJson(-32098, "oracle_band_exceeded", id, alloc);
                        defer alloc.free(msg);
                        return rpc.errorJson(-32098, msg, id, alloc);
                    }
                }
            }
        }
    };

    const side: matching_mod.Side =
        if (rpc.asciiEqIgnoreCase(side_str, "buy")) .buy
        else if (rpc.asciiEqIgnoreCase(side_str, "sell")) .sell
        else return rpc.errorJson(-32602, "side must be 'buy' or 'sell'", id, alloc);

    if (trader.len > 64) return rpc.errorJson(-32602, "trader address too long", id, alloc);

    // PHASE 1: REST HMAC-authenticated requests bypass ECDSA by sending
    // signature="REST_HMAC_BYPASS". The REST layer already verified HMAC-SHA512
    // before dispatching to this handler, so we trust the trader identity.
    const side_canon: []const u8 = if (side == .buy) "buy" else "sell";
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (!is_hmac_bypass) {
        var msg_buf: [256]u8 = undefined;
        const msg = rpc.buildOrderSignMessage(side_canon, pair_id, price, amount, nonce, trader, &msg_buf) catch
            return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
            return rpc.errorJson(-32000, "Signature verify failed (bad sig or pubkey/address mismatch)", id, alloc);
        }

        // 2) Verify pubkey -> address (so a stranger can't sign for someone else's address).
        //    Reuse existing chain helper that derives `ob1q...` from compressed pubkey.
        var pk_bytes: [33]u8 = undefined;
        _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
            return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
        const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
            return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
        defer alloc.free(derived_addr);
        if (!std.mem.eql(u8, derived_addr, trader)) {
            return rpc.errorJson(-32000, "Public key does not match trader address", id, alloc);
        }
    }

    // 3) Lock + nonce check (replay protection) + balance check + place
    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = rpc.nonceLookup(ctx, trader);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    // Balance check for SELL orders:
    // - OMNI base pairs (0,4,5,6): verify on-chain OMNI balance via getAddressBalance.
    // - Non-OMNI base pairs (1=BTC,2=LCX,3=ETH): balance lives on external chain —
    //   verification happens at HTLC fill time, not here. Skip check.
    // BUY side: skip (buyer locks quote asset at fill via HTLC, not at order placement).
    const base_is_omni = (pair_id == 0 or pair_id == 4 or pair_id == 5 or pair_id == 6);

    if (side == .sell and base_is_omni) {
        const balance = if (is_paper) blk: {
            const b = rpc.balanceLookup(ctx, trader, "OMNI_DEMO");
            break :blk if (b) |bal| bal.available_sat else 0;
        } else
            ctx.bc.getAddressBalance(trader);

        const reserved = if (is_paper)
            0
        else
            rpc.computeReservedFromOrderbook(engine, trader);

        const available = if (balance < reserved) 0 else (balance - reserved);

        if (available < amount) {
            return rpc.errorJson(-32000, "Insufficient available balance for sell", id, alloc);
        }
    }
    // BUY notional check skipped — quote asset lives on external chain (USDC/ETH/LCX),
    // verified at HTLC fill time, not at order placement.

    // KYC tier cap: gate per-order notional. `none` blocked, `pro` unlimited.
    // Skipped in paper mode, when no KYC store is wired (dev/local), and on
    // testnet/regtest (chain_id != 1) so testers can place orders freely.
    const is_mainnet = (ctx.chain_id == 1);
    if (!is_paper and is_mainnet) if (ctx.kyc_store) |ks| {
        const tier: kyc_mod.Level =
            if (ks.highest(trader, std.time.milliTimestamp())) |att| att.level else .none;
        const cap = rpc.kycMaxNotionalMicro(tier);
        const order_notional = rpc.orderNotionalMicro(price, amount);
        if (order_notional > cap) {
            const msg = std.fmt.allocPrint(alloc,
                "kyc_tier_exceeded: tier={s} max={d} requested={d}",
                .{ tier.label(), cap, order_notional },
            ) catch return rpc.errorJson(-32099, "kyc_tier_exceeded", id, alloc);
            defer alloc.free(msg);
            return rpc.errorJson(-32099, msg, id, alloc);
        }
    };

    var order = matching_mod.Order.empty();
    order.side = side;
    order.pair_id = pair_id;
    order.price_micro_usd = price;
    order.amount_sat = amount;
    order.timestamp_ms = std.time.milliTimestamp();
    const tn = @min(trader.len, order.trader_address.len);
    @memcpy(order.trader_address[0..tn], trader[0..tn]);
    order.trader_addr_len = @intCast(tn);
    order.status = .active;

    // EVM-leg validation for OMNI/<EVM-token> pairs. Atomic-swap-style:
    //   SELL must provide sellerEvm so the settler knows where to deliver.
    //   BUY  must provide evmOrderId, and the chain MUST already have seen
    //        an OrderPlaced event with that id on the EVM contract (via
    //        evm_escrow_watcher) with amount matching this BID's quote.
    // Without these checks, OMNI moves at fill but the quote stays untouched
    // (cf. testnet fill #10 2026-05-15 — buyer paid nothing, seller lost
    // 95 OMNI). Refuse unbacked orders up front.
    //
    // pair_id 0 = OMNI/USDC, 6 = OMNI/ETH, 7 = OMNI/LINK — all settle on
    // an EVM chain via OmnibusDEX. Add more pair_ids here when new
    // OMNI/<EVM-asset> pairs come online (LCX, EURC, etc.). Without this
    // guard a SELL with no sellerEvm crosses fine on OmniBus but the
    // settler skips it silently — buyer's escrow stays locked forever
    // (cf. testnet LINK fill #13 2026-05-16).
    const omni_evm_pair = (pair_id == 0 or pair_id == 6 or pair_id == 7);
    if (omni_evm_pair) {
        if (side == .sell) {
            const evm_str_raw = rpc.extractStr(body, "sellerEvm") orelse
                return rpc.errorJson(-32602, "Missing param: sellerEvm (required for OMNI/<EVM> SELL)", id, alloc);
            var evm_str = evm_str_raw;
            if (std.mem.startsWith(u8, evm_str, "0x") or std.mem.startsWith(u8, evm_str, "0X")) {
                evm_str = evm_str[2..];
            }
            if (evm_str.len != 40) return rpc.errorJson(-32602, "sellerEvm must be 0x + 40 hex chars", id, alloc);
            hex_utils.hexToBytes(evm_str, &order.seller_evm) catch
                return rpc.errorJson(-32602, "sellerEvm: invalid hex", id, alloc);
        } else { // .buy
            const evm_order_id = rpc.extractArrayNumByKey(body, "evmOrderId");
            if (evm_order_id == 0) {
                return rpc.errorJson(-32602,
                    "Missing param: evmOrderId (BUY on OMNI/<EVM> must reference an on-chain escrow)",
                    id, alloc);
            }
            // Verify the chain has seen this escrow via the watcher.
            if (ctx.evm_escrow_watcher) |w| {
                const esc = w.getOpen(evm_order_id) orelse {
                    return rpc.errorJson(-32000,
                        "No open OmnibusDEX escrow with this evmOrderId on Sepolia — did your placeBuyOrderNative tx mine?",
                        id, alloc);
                };
                // Amount sanity: the escrow amount must cover price * amount
                // in the quote token's smallest unit.
                //
                // For OMNI/USDC (pair_id 0): both micro-USD and USDC use 1e-6,
                // so expected_smallest = price_micro_usd * amount_sat / 1e9.
                // We enforce that exactly (with a 1-wei tolerance for rounding).
                //
                // For OMNI/ETH (6) and OMNI/LINK (7): the quote is an 18-dec
                // token whose USD value floats, so we can't compute the exact
                // expected amount without an oracle price for ETH/LINK. We
                // fall back to "non-zero" here; the EVM contract's own
                // settle() enforces the per-fill amount against the buyer's
                // signed intent, so an under-funded escrow won't actually pay
                // the seller. TODO when an oracle quote is wired here, swap
                // this branch for the same exact-match logic as USDC.
                if (esc.amount == 0) {
                    return rpc.errorJson(-32000, "Escrow amount is zero", id, alloc);
                }
                if (pair_id == 0) {
                    // price (micro-USD) * amount (SAT) / 1e9 = micro-USD owed
                    // = USDC smallest-unit owed (since 1 micro-USD = 1e-6 USDC
                    // and USDC has 6 decimals). u128 is wide enough: max
                    // 21M OMNI × $1e9 ≈ 2e25.
                    const expected_u128: u128 =
                        @as(u128, price) * @as(u128, amount) / 1_000_000_000;
                    if (esc.amount >> 128 != 0) {
                        return rpc.errorJson(-32000, "Escrow amount > 2^128 micro-USD — refusing", id, alloc);
                    }
                    const escrow_u128: u128 = @intCast(esc.amount & ((@as(u256, 1) << 128) - 1));
                    if (escrow_u128 < expected_u128) {
                        return rpc.errorJson(-32000,
                            "Escrow underfunded — locked amount is less than price * size in USDC smallest units",
                            id, alloc);
                    }
                }
                // SECURITY: refuse escrows that lock a token not on the
                // hard-coded whitelist for this pair_id + chain. Without
                // this gate, a malicious buyer could deploy a fake-USDC
                // contract and lock 5 units of it to claim 5 OMNI of real
                // liquidity. The whitelist binds (pair_id, chain_id, token)
                // tuples to Circle's official USDC, native ETH, etc.
                if (token_whitelist.check(pair_id, esc.chain_id, esc.token)) |label| {
                    std.debug.print(
                        "[token_whitelist] OK pair={d} chain={d} token={s}\n",
                        .{ pair_id, esc.chain_id, label },
                    );
                } else {
                    var token_hex_buf: [42]u8 = undefined;
                    token_hex_buf[0] = '0';
                    token_hex_buf[1] = 'x';
                    const hex_chars = "0123456789abcdef";
                    for (esc.token, 0..) |b, bi| {
                        token_hex_buf[2 + bi * 2] = hex_chars[b >> 4];
                        token_hex_buf[2 + bi * 2 + 1] = hex_chars[b & 0x0F];
                    }
                    std.debug.print(
                        "[token_whitelist] REJECT pair={d} chain={d} token={s}\n",
                        .{ pair_id, esc.chain_id, &token_hex_buf },
                    );
                    const msg = std.fmt.allocPrint(alloc,
                        "Escrow token not whitelisted for this pair (chain={d} token={s}). " ++
                        "Only Circle USDC / native ETH on supported chains are accepted.",
                        .{ esc.chain_id, &token_hex_buf },
                    ) catch return rpc.errorJson(-32000, "Escrow token not whitelisted", id, alloc);
                    defer alloc.free(msg);
                    return rpc.errorJson(-32000, msg, id, alloc);
                }
            } else {
                // Watcher disabled → refuse to be safe.
                return rpc.errorJson(-32000,
                    "evm_escrow_watcher not running — cannot verify on-chain escrow",
                    id, alloc);
            }
            order.evm_order_id = evm_order_id;
        }
    }

    const fills_before = engine.fill_count;
    engine.placeOrder(order) catch |err| {
        return rpc.errorJson(-32000, switch (err) {
            error.OrderbookFull => "Orderbook full",
            error.FillBufferFull => "Fill buffer full",
            error.InvalidPrice => "Invalid price",
            error.InvalidAmount => "Invalid amount",
            error.InvalidPair => "Invalid pair",
            else => "Order rejected",
        }, id, alloc);
    };
    const new_order_id = engine.next_order_id - 1;

    // Move newly produced fills into rolling trade_log + accumulate fees.
    // Maker = the trader whose order was already in the book.
    //         Taker = the incoming order (the one we just placed).
    // For a BUY incoming, the matched ask was the resting maker; for a
    // SELL incoming, the matched bid was the resting maker. So the
    // taker_id below is always our just-placed `new_order_id`.
    var total_network_fee_sat: u64 = 0;
    var total_taker_fee_micro: u64 = 0;
    var total_maker_fee_micro: u64 = 0;
    const block_height_now: u64 = ctx.bc.chain.items.len;
    var fi = fills_before;
    while (fi < engine.fill_count) : (fi += 1) {
        const f = engine.fills[fi];
        rpc.tradeLogPush(ctx, f, is_paper);

        const taker_fee = rpc.computeExchangeFeeMicro(
            f.price_micro_usd, f.amount_sat, rpc.EXCHANGE_FEE_TAKER_BPS);
        const maker_fee = rpc.computeExchangeFeeMicro(
            f.price_micro_usd, f.amount_sat, rpc.EXCHANGE_FEE_MAKER_BPS);
        const quote_micro = rpc.orderNotionalMicro(f.price_micro_usd, f.amount_sat);

        total_network_fee_sat += rpc.FILL_NETWORK_FEE_SAT;
        total_taker_fee_micro += taker_fee;
        total_maker_fee_micro += maker_fee;

        // Settle fees on chain — the taker is always our newly-placed
        // order; the maker is the resting opposite-side order.
        const buyer_addr = f.getBuyerAddress();
        const seller_addr = f.getSellerAddress();
        const taker_addr = if (side == .buy) buyer_addr else seller_addr;
        const maker_addr = if (side == .buy) seller_addr else buyer_addr;
        if (!is_paper) {
            // For OMNI-base pairs (0=OMNI/USDC, 4=OMNI/BTC, 5=OMNI/LCX,
            // 6=OMNI/ETH) we move OMNI on-chain from seller → buyer at
            // fill time. Quote leg lives on a foreign chain (USDC/BTC/
            // LCX/ETH) and is handled by dex_settler.zig if/when needed.
            const omni_base_fill = (f.pair_id == 0 or f.pair_id == 4 or f.pair_id == 5 or f.pair_id == 6);
            if (omni_base_fill) {
                ctx.bc.applyFillTransferOmniBase(
                    buyer_addr, seller_addr, f.amount_sat, f.fill_id,
                ) catch |err| {
                    std.debug.print(
                        "[FILL-TRANSFER] OMNI debit/credit failed for fill {d}: {} — buyer not credited!\n",
                        .{ f.fill_id, err },
                    );
                };
            }

            ctx.bc.applyExchangeFees(
                taker_addr, maker_addr, taker_fee, maker_fee, rpc.FILL_NETWORK_FEE_SAT,
            ) catch |err| {
                std.debug.print(
                    "[EXCHANGE-FEE] settlement failed for fill {d}: {} — fees not collected on this fill\n",
                    .{ f.fill_id, err },
                );
            };
        }

        // Persist fill receipt for "My Trades" UI + audit. Local to this
        // node; not propagated through P2P. Failure here is non-fatal —
        // the fill itself already succeeded.
        if (ctx.fills_log) |flog| {
            const taker_side_byte: u8 = if (side == .buy) 0 else 1;
            // Read the actual chain_id from the EVM escrow (watcher tagged
            // it at OrderPlaced time). Falls back to 0 (= OMNI-only fill)
            // for non-cross-chain pairs or when watcher isn't running.
            var evm_chain_id: u64 = 0;
            if (f.evm_order_id != 0) {
                if (ctx.evm_escrow_watcher) |w| {
                    if (w.getOpen(f.evm_order_id)) |esc| {
                        evm_chain_id = esc.chain_id;
                    }
                }
            }
            flog.append(f, taker_side_byte, block_height_now, evm_chain_id) catch |err| {
                std.debug.print(
                    "[FILLS-LOG] append failed for fill {d}: {} — entry skipped\n",
                    .{ f.fill_id, err },
                );
            };
        }

        // Per-fill audit log (forensics — taker/maker addrs, fees, height).
        var fbuf: [512]u8 = undefined;
        const fline = std.fmt.bufPrint(&fbuf,
            "\"fillId\":{d},\"pairId\":{d},\"taker\":\"{s}\",\"maker\":\"{s}\"," ++
            "\"price\":{d},\"amount\":{d},\"quote\":{d}," ++
            "\"takerFee\":{d},\"makerFee\":{d},\"networkFee\":{d}," ++
            "\"blockHeight\":{d},\"ts\":{d},\"paper\":{}",
            .{
                f.fill_id, f.pair_id, taker_addr, maker_addr,
                f.price_micro_usd, f.amount_sat, quote_micro,
                taker_fee, maker_fee, rpc.FILL_NETWORK_FEE_SAT,
                block_height_now, f.timestamp_ms, is_paper,
            },
        ) catch "";
        if (fline.len > 0) rpc.ordersAppendJournal(ctx, "fill", fline);

        // Push new_trade event to WebSocket subscribers.
        if (main_mod.g_ws_srv) |ws| {
            const pair_label = rpc.pairIdToLabel(f.pair_id);
            const trade_side = if (side == .buy) "buy" else "sell";
            ws.broadcastTrade(f.pair_id, pair_label, f.price_micro_usd,
                f.amount_sat, trade_side, block_height_now);
        }
    }

    // Push orderbook_update after all fills so subscribers see final state.
    if (main_mod.g_ws_srv) |ws| {
        const pair_label = rpc.pairIdToLabel(pair_id);
        ws.broadcastOrderbook(
            pair_id, pair_label,
            engine.bestBid(pair_id) orelse 0,
            engine.bestAsk(pair_id) orelse 0,
            engine.spread(pair_id) orelse 0,
            engine.orderCountForPair(pair_id),
            @intCast(ctx.bc.chain.items.len),
        );
    }

    rpc.nonceSet(ctx, trader, nonce);

    // Note: reservation is derived from `engine.asks[]` directly (single source
    // of truth — see computeReservedFromOrderbook). No separate state to update.

    // ── Submit canonical typed `order_place` TX into the chain mempool ──
    // The in-memory matching engine path above is now a *preview* — the
    // authoritative orderbook is rebuilt deterministically by every node
    // from on-chain `order_place` TXs via `applyOrderTxs`. Skip in paper
    // mode (paper trades never touch chain). On submission failure we log
    // but don't fail the RPC — the user-facing orderbook still saw the
    // order place via the preview engine.
    if (!is_paper) {
        rpc.submitOrderPlaceTx(ctx, trader, side, pair_id, price, amount) catch |sub_err| {
            std.debug.print("[EXCHANGE] order_place chain TX submit failed: {} (orderbook will rebuild from preview-only on this node)\n",
                .{sub_err});
        };
    }

    // Create on-chain order TX with hash
    const tx_result = rpc.createOrderTransaction(
        alloc,
        trader,
        side_canon,
        pair_id,
        price,
        amount,
        nonce,
        new_order_id,
        sig_hex,
        pubkey_hex,
    ) catch |err| {
        std.debug.print("[EXCHANGE] TX creation failed: {}\n", .{err});
        return rpc.errorJson(-32603, "Failed to create order TX", id, alloc);
    };
    defer alloc.free(tx_result.tx_json);
    defer alloc.free(tx_result.tx_hash);

    // Persist the place event with TX hash
    var jbuf: [1024]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"trader\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d},\"price\":{d},\"amount\":{d},\"orderId\":{d},\"ts\":{d},\"txHash\":\"{s}\"",
        .{ trader, side_canon, pair_id, price, amount, new_order_id, order.timestamp_ms, tx_result.tx_hash },
    ) catch "";
    if (jline.len > 0) rpc.ordersAppendJournal(ctx, "place", jline);

    // Compute filled amount this order achieved (sum of new fills where this order_id appears)
    var filled_total: u64 = 0;
    var k = fills_before;
    while (k < engine.fill_count) : (k += 1) {
        const f = engine.fills[k];
        if (f.buy_order_id == new_order_id or f.sell_order_id == new_order_id) {
            filled_total += f.amount_sat;
        }
    }
    const remaining: u64 = if (filled_total >= amount) 0 else amount - filled_total;

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"mode\":\"{s}\"," ++
            "\"orderId\":{d},\"txHash\":\"{s}\",\"side\":\"{s}\",\"pairId\":{d}," ++
            "\"price\":{d},\"amount\":{d}," ++
            "\"filled\":{d},\"remaining\":{d},\"status\":\"{s}\"," ++
            "\"fees\":{{" ++
                "\"networkFeeSat\":{d}," ++
                "\"exchangeTakerFeeMicroUsd\":{d}," ++
                "\"exchangeMakerFeeMicroUsd\":{d}," ++
                "\"takerBps\":{d},\"makerBps\":{d}" ++
            "}}" ++
        "}}}}",
        .{ id, if (is_paper) "paper" else "real",
           new_order_id, tx_result.tx_hash, side_canon, pair_id,
           price, amount, filled_total, remaining,
           if (remaining == 0) "filled" else if (filled_total > 0) "partial" else "active",
           total_network_fee_sat, total_taker_fee_micro, total_maker_fee_micro,
           rpc.EXCHANGE_FEE_TAKER_BPS, rpc.EXCHANGE_FEE_MAKER_BPS });
}

/// exchange_cancelOrder — anuleaza o ordine. Required: orderId, trader,
/// nonce, signature, publicKey. Verifica pe lant ca trader == owner.
pub fn handleExchangeCancelOrder(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = rpc.isPaperMode(body);
    const engine = rpc.pickEngine(ctx, is_paper) orelse
        return rpc.errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    var order_id = rpc.extractArrayNumByKey(body, "orderId");
    if (order_id == 0) order_id = rpc.extractArrayNumByKey(body, "order_id");
    if (order_id == 0) return rpc.errorJson(-32602, "Missing param: orderId (or order_id)", id, alloc);
    const trader = rpc.extractStr(body, "trader") orelse
        return rpc.errorJson(-32602, "Missing param: trader", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // Verify signature (skip for REST HMAC-authenticated requests)
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (!is_hmac_bypass) {
        var msg_buf: [128]u8 = undefined;
        const msg = rpc.buildCancelSignMessage(order_id, nonce, trader, &msg_buf) catch
            return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
        if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
            return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
        }

        // Pubkey -> trader address must match
        var pk_bytes: [33]u8 = undefined;
        _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
            return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
        const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
            return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
        defer alloc.free(derived_addr);
        if (!std.mem.eql(u8, derived_addr, trader)) {
            return rpc.errorJson(-32000, "Public key does not match trader address", id, alloc);
        }
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    // Look up order, verify ownership BEFORE cancelling
    const order = engine.getOrder(order_id) orelse
        return rpc.errorJson(-32000, "Order not found", id, alloc);
    if (!std.mem.eql(u8, order.getTraderAddress(), trader)) {
        return rpc.errorJson(-32000, "Not order owner", id, alloc);
    }

    const last_nonce = rpc.nonceLookup(ctx, trader);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    engine.cancelOrder(order_id) catch |err| {
        return rpc.errorJson(-32000, switch (err) {
            error.OrderNotFound => "Order not found",
            else => "Cancel failed",
        }, id, alloc);
    };

    // Note: cancelOrder marks the order .cancelled, so it's automatically
    // excluded from computeReservedFromOrderbook on next balance check.

    // ── Submit canonical typed `order_cancel` TX into the chain mempool ──
    // Replaying nodes apply this via `applyOrderTxs`, which removes the
    // order from the deterministic book.
    if (!is_paper) {
        rpc.submitOrderCancelTx(ctx, trader, order_id) catch |sub_err| {
            std.debug.print("[EXCHANGE] order_cancel chain TX submit failed: {}\n", .{sub_err});
        };
    }

    rpc.nonceSet(ctx, trader, nonce);

    var jbuf: [128]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"trader\":\"{s}\",\"orderId\":{d},\"ts\":{d}",
        .{ trader, order_id, std.time.milliTimestamp() },
    ) catch "";
    if (jline.len > 0) rpc.ordersAppendJournal(ctx, "cancel", jline);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"orderId\":{d},\"cancelled\":true}}}}",
        .{ id, order_id });
}

/// exchange_getOrderbook — top N bids/asks pentru o pereche.
/// Params: pair sau pairId, optional depth (default 25, max 50).
pub fn handleExchangeGetOrderbook(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = rpc.isPaperMode(body);
    const engine = rpc.pickEngine(ctx, is_paper) orelse
        return rpc.errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    var pair_id: u16 = 0;
    const pair_id_u = rpc.extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        pair_id = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (rpc.extractStr(body, "pair")) |label| {
        pair_id = rpc.exchangePairLookup(label) orelse 0;
    }

    const depth_raw = rpc.extractArrayNumByKey(body, "depth");
    const depth: u32 = if (depth_raw == 0) 25 else @intCast(@min(depth_raw, @as(u64, 50)));

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":{\"pairId\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{pair_id});
    try out.appendSlice(alloc, ",\"bids\":[");

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var emitted: u32 = 0;
    var first = true;
    var i: u32 = 0;
    while (i < engine.bid_count and emitted < depth) : (i += 1) {
        const o = engine.bids[i];
        if (o.pair_id != pair_id) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"orderId\":{d},\"price\":{d},\"amount\":{d},\"remaining\":{d},\"trader\":\"{s}\",\"ts\":{d}}}",
            .{ o.order_id, o.price_micro_usd, o.amount_sat, o.remainingSat(),
               o.trader_address[0..o.trader_addr_len], o.timestamp_ms });
        emitted += 1;
    }

    try out.appendSlice(alloc, "],\"asks\":[");
    emitted = 0;
    first = true;
    i = 0;
    while (i < engine.ask_count and emitted < depth) : (i += 1) {
        const o = engine.asks[i];
        if (o.pair_id != pair_id) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"orderId\":{d},\"price\":{d},\"amount\":{d},\"remaining\":{d},\"trader\":\"{s}\",\"ts\":{d}}}",
            .{ o.order_id, o.price_micro_usd, o.amount_sat, o.remainingSat(),
               o.trader_address[0..o.trader_addr_len], o.timestamp_ms });
        emitted += 1;
    }

    const best_bid = engine.bestBid(pair_id) orelse 0;
    const best_ask = engine.bestAsk(pair_id) orelse 0;
    const spread_v = engine.spread(pair_id) orelse 0;

    try std.fmt.format(out.writer(alloc),
        "],\"bestBid\":{d},\"bestAsk\":{d},\"spread\":{d},\"orderCount\":{d}}}}}",
        .{ best_bid, best_ask, spread_v, engine.orderCountForPair(pair_id) });

    return alloc.dupe(u8, out.items);
}

/// exchange_getUserOrders — toate ordinele active ale unei adrese.
/// Params: trader. Optional: pairId / pair (filtru).
pub fn handleExchangeGetUserOrders(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = rpc.isPaperMode(body);
    const engine = rpc.pickEngine(ctx, is_paper) orelse
        return rpc.errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);
    const trader = rpc.extractStr(body, "trader") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: trader", id, alloc);

    var filter_pair: ?u16 = null;
    const pair_id_u = rpc.extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        filter_pair = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (rpc.extractStr(body, "pair")) |label| {
        filter_pair = rpc.exchangePairLookup(label);
    }

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var first = true;
    inline for (.{ "bids", "asks" }) |which| {
        const count = if (comptime std.mem.eql(u8, which, "bids")) engine.bid_count else engine.ask_count;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const o = if (comptime std.mem.eql(u8, which, "bids")) engine.bids[i] else engine.asks[i];
            if (!std.mem.eql(u8, o.getTraderAddress(), trader)) continue;
            if (filter_pair) |fp| if (o.pair_id != fp) continue;
            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            try std.fmt.format(out.writer(alloc),
                "{{\"orderId\":{d},\"side\":\"{s}\",\"pairId\":{d},\"price\":{d},\"amount\":{d},\"filled\":{d},\"remaining\":{d},\"status\":\"{s}\",\"ts\":{d}}}",
                .{ o.order_id, o.side.name(), o.pair_id, o.price_micro_usd, o.amount_sat,
                   o.filled_sat, o.remainingSat(),
                   switch (o.status) { .active => "active", .partial => "partial", .filled => "filled", .cancelled => "cancelled" },
                   o.timestamp_ms });
        }
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getUserTrades — istoricul on-chain de fills al unui trader.
///
/// Spre deosebire de exchange_getUserOrders care arata doar ordinele active in
/// matching engine, asta citeste fills_log.bin persistent. Astfel restart-ul
/// nodului nu pierde istoricul. Apare in "My Trades" panel pentru ambii
/// participanti (buyer + seller).
///
/// Params: trader (omni address required). Optional: limit (default 100,
/// max 500), pairId/pair (filtru).
///
/// Result: [
///   { fillId, pairId, side: "buy"|"sell" (rolul traderului in trade),
///     counterparty, price, amount, blockHeight, ts, fillId,
///     evmChainId (0 if no EVM leg), evmSettleTxHash (null pana la settle) },
///   ...
/// ]
pub fn handleExchangeGetUserTrades(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const flog = ctx.fills_log orelse
        return rpc.errorJson(-32601, "Fills log not enabled on this node", id, alloc);
    const trader = rpc.extractStr(body, "trader") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: trader", id, alloc);

    var filter_pair: ?u16 = null;
    const pair_id_u = rpc.extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        filter_pair = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (rpc.extractStr(body, "pair")) |label| {
        filter_pair = rpc.exchangePairLookup(label);
    }
    const limit_raw = rpc.extractArrayNumByKey(body, "limit");
    const limit: usize = if (limit_raw == 0) 100 else @intCast(@min(limit_raw, 500));

    const recs = flog.readForTrader(alloc, trader, 0) catch &.{};
    defer if (recs.len > 0) alloc.free(recs);

    // Merge settle map so we can attach EVM tx hash where available.
    var settle_map = flog.loadSettleMap() catch fills_log_mod.SettleMap.init(alloc);
    defer settle_map.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    // Walk newest-first so the UI shows latest trade at the top.
    var emitted: usize = 0;
    var idx: usize = recs.len;
    while (idx > 0 and emitted < limit) {
        idx -= 1;
        const r = &recs[idx];
        if (filter_pair) |fp| if (r.pair_id != fp) continue;

        const is_buyer = std.mem.eql(u8, r.buyerAddrSlice(), trader);
        // Trader's perspective of the trade — if they're the buyer they
        // "bought" base; otherwise they "sold" it.
        const role = if (is_buyer) "buy" else "sell";
        const counterparty = if (is_buyer) r.sellerAddrSlice() else r.buyerAddrSlice();

        if (emitted > 0) try out.appendSlice(alloc, ",");
        emitted += 1;

        try std.fmt.format(out.writer(alloc),
            "{{\"fillId\":{d},\"pairId\":{d},\"side\":\"{s}\",\"counterparty\":\"{s}\"," ++
            "\"price\":{d},\"amount\":{d},\"buyOrderId\":{d},\"sellOrderId\":{d}," ++
            "\"blockHeight\":{d},\"ts\":{d},\"evmChainId\":{d}",
            .{
                r.fill_id, r.pair_id, role, counterparty,
                r.price_micro_usd, r.amount_sat, r.buy_order_id, r.sell_order_id,
                r.block_height, r.timestamp_ms, r.evm_chain_id,
            },
        );

        if (settle_map.get(r.fill_id)) |s| {
            try out.appendSlice(alloc, ",\"evmSettleTxHash\":\"0x");
            for (s.tx_hash) |b| try std.fmt.format(out.writer(alloc), "{x:0>2}", .{b});
            try out.appendSlice(alloc, "\"");
        } else {
            try out.appendSlice(alloc, ",\"evmSettleTxHash\":null");
        }

        try out.appendSlice(alloc, "}");
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getTrades — ultimele N fills. Optional: pair/pairId, address (filtru),
/// limit (default 50, max 256).
pub fn handleExchangeGetTrades(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = rpc.isPaperMode(body);
    if (rpc.pickEngine(ctx, is_paper) == null) return rpc.errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    var filter_pair: ?u16 = null;
    const pair_id_u = rpc.extractArrayNumByKey(body, "pairId");
    if (pair_id_u > 0) {
        filter_pair = @intCast(@min(pair_id_u, std.math.maxInt(u16)));
    } else if (rpc.extractStr(body, "pair")) |label| {
        filter_pair = rpc.exchangePairLookup(label);
    }
    const filter_addr = rpc.extractStr(body, "address") orelse rpc.extractStr(body, "trader");
    const limit_raw = rpc.extractArrayNumByKey(body, "limit");
    const limit: u32 = if (limit_raw == 0) 50 else @intCast(@min(limit_raw, 256));

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    // Walk newest-to-oldest in circular buffer (per-mode log).
    const es = ctx.exstate.?;
    const log_count = if (is_paper) es.trade_count_paper else es.trade_count;
    const log_head = if (is_paper) es.trade_head_paper else es.trade_head;
    var emitted: u32 = 0;
    var first = true;
    var c: u32 = 0;
    while (c < log_count and emitted < limit) : (c += 1) {
        // Most recent index = (head - 1 - c) mod len
        const len_u: u32 = 256;
        const idx = (log_head + len_u - 1 - c) % len_u;
        const f = if (is_paper) es.trade_log_paper[idx] else es.trade_log[idx];
        if (filter_pair) |fp| if (f.pair_id != fp) continue;
        if (filter_addr) |a| {
            const buyer = f.getBuyerAddress();
            const seller = f.getSellerAddress();
            if (!std.mem.eql(u8, buyer, a) and !std.mem.eql(u8, seller, a)) continue;
        }
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"fillId\":{d},\"pairId\":{d},\"price\":{d},\"amount\":{d},\"buyer\":\"{s}\",\"seller\":\"{s}\",\"buyOrderId\":{d},\"sellOrderId\":{d},\"ts\":{d}}}",
            .{ f.fill_id, f.pair_id, f.price_micro_usd, f.amount_sat,
               f.buyer_address[0..f.buyer_addr_len], f.seller_address[0..f.seller_addr_len],
               f.buy_order_id, f.sell_order_id, f.timestamp_ms });
        emitted += 1;
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_listPairs — perechi suportate. Static (definite la compile-time).
/// exchange_pairInfo — returns multi-chain routing + HTLC contract addresses for a pair.
/// Params: { "pair_id": N }
/// Result: { pair_id, base, quote,
///            maker_chains: [{chain, chain_id, contract}...],
///            taker_chains: [{chain, chain_id, contract}...] }
pub fn handleExchangePairInfo(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pair_id_u = rpc.extractU64Param(body, "\"pair_id\"") orelse
        return rpc.errorJson(-32602, "Missing param: pair_id", id, alloc);
    const route = swap_link_mod.routeForPair(@intCast(pair_id_u)) orelse
        return rpc.errorJson(-32602, "Unknown pair_id", id, alloc);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try std.fmt.format(out.writer(alloc),
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"pair_id\":{d},\"base\":\"{s}\",\"quote\":\"{s}\"," ++
        "\"maker_chains\":[",
        .{ id, route.pair_id, route.base_asset, route.quote_asset });

    const maker_chains = swap_link_mod.chainsForAsset(route.base_asset);
    var first: bool = true;
    for (maker_chains) |ch| {
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"chain\":\"{s}\",\"chain_id\":{d},\"contract\":\"{s}\"}}",
            .{ ch.label(), ch.evmChainId(), swap_link_mod.htlcContractFor(ch) });
    }
    try out.appendSlice(alloc, "],\"taker_chains\":[");

    const taker_chains = swap_link_mod.chainsForAsset(route.quote_asset);
    first = true;
    for (taker_chains) |ch| {
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"chain\":\"{s}\",\"chain_id\":{d},\"contract\":\"{s}\"}}",
            .{ ch.label(), ch.evmChainId(), swap_link_mod.htlcContractFor(ch) });
    }
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

pub fn handleExchangeListPairs(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");
    var first = true;
    for (rpc.EXCHANGE_PAIRS) |p| {
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"id\":{d},\"base\":\"{s}\",\"quote\":\"{s}\",\"label\":\"{s}/{s}\"}}",
            .{ p.id, p.base, p.quote, p.base, p.quote });
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getStats — sumar global: total ordine, total fills, best/spread per pereche.
pub fn handleExchangeGetStats(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const is_paper = rpc.isPaperMode(body);
    const engine = rpc.pickEngine(ctx, is_paper) orelse
        return rpc.errorJson(-32601, if (is_paper) "Paper trader not enabled" else "Exchange not enabled on this node", id, alloc);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const trade_count = if (is_paper) ctx.exstate.?.trade_count_paper else ctx.exstate.?.trade_count;

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try std.fmt.format(out.writer(alloc),
        ",\"result\":{{\"mode\":\"{s}\",\"totalOrders\":{d},\"bidCount\":{d},\"askCount\":{d},\"trades\":{d},\"pairs\":[",
        .{ if (is_paper) "paper" else "real", engine.orderCount(), engine.bid_count, engine.ask_count, trade_count });
    var first = true;
    for (rpc.EXCHANGE_PAIRS) |p| {
        const bb = engine.bestBid(p.id) orelse 0;
        const ba = engine.bestAsk(p.id) orelse 0;
        const sp = engine.spread(p.id) orelse 0;
        const oc = engine.orderCountForPair(p.id);
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        try std.fmt.format(out.writer(alloc),
            "{{\"id\":{d},\"label\":\"{s}/{s}\",\"bestBid\":{d},\"bestAsk\":{d},\"spread\":{d},\"orderCount\":{d}}}",
            .{ p.id, p.base, p.quote, bb, ba, sp, oc });
    }
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getAuthNonce — generates a 32-byte random nonce (hex) bound
/// to the caller's address. The user signs "OmniBus Exchange Login: <nonce>"
/// and submits via `exchange_login` to prove key ownership.
pub fn handleExchangeGetAuthNonce(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse rpc.extractArrayStr(body, 0) orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    if (address.len > 64) return rpc.errorJson(-32602, "address too long", id, alloc);

    var nonce_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&nonce_bytes);
    var nonce_hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        nonce_hex[i * 2] = hex_chars[nonce_bytes[i] >> 4];
        nonce_hex[i * 2 + 1] = hex_chars[nonce_bytes[i] & 0xF];
    }

    const now_ms = std.time.milliTimestamp();
    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();
    rpc.authNoncePurge(ctx, now_ms);
    rpc.authNoncePut(ctx, address, &nonce_hex, now_ms);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"nonce\":\"{s}\",\"message\":\"OmniBus Exchange Login: {s}\",\"ttlMs\":{d}}}}}",
        .{ id, nonce_hex, nonce_hex, rpc.AUTH_NONCE_TTL_MS });
}

/// exchange_login — verify nonce signature, mark the address as a known
/// exchange user (just allocates a default OMNI balance row if missing).
/// Returns the address + a list of currently active api keys (without
/// revealing secrets). Stateless — no JWT; future calls re-prove
/// ownership either via signature or via api-key+secret headers.
pub fn handleExchangeLogin(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const nonce_hex = rpc.extractStr(body, "nonce") orelse
        return rpc.errorJson(-32602, "Missing param: nonce", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "OmniBus Exchange Login: {s}", .{nonce_hex}) catch
        return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, address)) {
        return rpc.errorJson(-32000, "Public key does not match address", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    if (!rpc.authNonceConsume(ctx, address, nonce_hex)) {
        return rpc.errorJson(-32000, "Nonce expired or unknown — request a fresh one", id, alloc);
    }

    // Allocate a default OMNI balance row so the user appears in
    // exchange_get_balances even before depositing.
    _ = rpc.balanceGetOrCreate(ctx, address, "OMNI");

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"loggedIn\":true,\"sessionTtlMs\":{d}}}}}",
        .{ id, address, rpc.AUTH_NONCE_TTL_MS });
}

/// exchange_createApiKey — generate a fresh (key_id, secret) pair owned
/// by the caller. The secret is returned ONCE (plaintext) and stored as
/// SHA256 hash. Caller must prove address ownership via signature on
/// the canonical message "EXCHANGE_APIKEY_V1\n<name>\n<address>\n<nonce>".
pub fn handleExchangeCreateApiKey(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const name = rpc.extractStr(body, "name") orelse "default";
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    if (name.len > 32) return rpc.errorJson(-32602, "name too long (max 32)", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "EXCHANGE_APIKEY_V1\n{s}\n{s}\n{d}", .{ name, owner, nonce }) catch
        return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, owner)) {
        return rpc.errorJson(-32000, "Public key does not match owner address", id, alloc);
    }

    // Generate key + secret
    var key_random: [12]u8 = undefined;
    var secret_random: [32]u8 = undefined;
    std.crypto.random.bytes(&key_random);
    std.crypto.random.bytes(&secret_random);
    const hex_chars = "0123456789abcdef";
    var key_id: [28]u8 = undefined; // "obx_" + 24 hex chars
    @memcpy(key_id[0..4], "obx_");
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        key_id[4 + i * 2] = hex_chars[key_random[i] >> 4];
        key_id[4 + i * 2 + 1] = hex_chars[key_random[i] & 0xF];
    }
    var secret_str: [68]u8 = undefined; // "obs_" + 64 hex chars
    @memcpy(secret_str[0..4], "obs_");
    i = 0;
    while (i < 32) : (i += 1) {
        secret_str[4 + i * 2] = hex_chars[secret_random[i] >> 4];
        secret_str[4 + i * 2 + 1] = hex_chars[secret_random[i] & 0xF];
    }

    var sec_hash: [64]u8 = undefined;
    rpc.sha256Hex(&secret_str, &sec_hash);

    // Base64-encode the raw secret for Kraken-compatible HMAC signing
    var secret_b64_buf: [64]u8 = undefined;
    const secret_b64 = std.base64.standard.Encoder.encode(&secret_b64_buf, &secret_random);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = rpc.nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used (replay rejected)", id, alloc);
    }

    const now_ms = std.time.milliTimestamp();
    rpc.apiKeyInsert(ctx, &key_id, &secret_random, &sec_hash, name, owner, now_ms);
    rpc.nonceSet(ctx, owner, nonce);

    var jbuf: [512]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"keyId\":\"{s}\",\"secretHash\":\"{s}\",\"name\":\"{s}\",\"owner\":\"{s}\",\"ts\":{d}",
        .{ key_id, sec_hash, name, owner, now_ms },
    ) catch "";
    if (jline.len > 0) rpc.usersAppendJournal(ctx, "apikey", jline);

    const apikey_name_safe = try rpc.jsonSanitize(alloc, name);
    defer alloc.free(apikey_name_safe);
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"keyId\":\"{s}\",\"secret\":\"{s}\",\"secretB64\":\"{s}\",\"name\":\"{s}\",\"warning\":\"Save the secret — it is only shown once. Use secretB64 for HMAC-SHA512 signing.\",\"createdMs\":{d}}}}}",
        .{ id, key_id, secret_str, secret_b64, apikey_name_safe, now_ms });
}

/// exchange_listApiKeys — list keys owned by an address. Secrets are
/// never returned (only the SHA256 hash for transparency).
pub fn handleExchangeListApiKeys(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");
    var first = true;
    var i: u16 = 0;
    while (i < ctx.exstate.?.api_key_count) : (i += 1) {
        const k = &ctx.exstate.?.api_keys[i];
        if (k.owner_len != owner.len) continue;
        if (!std.mem.eql(u8, k.owner[0..k.owner_len], owner)) continue;
        if (!first) try out.appendSlice(alloc, ",");
        first = false;
        const kname_safe = try rpc.jsonSanitize(alloc, k.name[0..k.name_len]);
        defer alloc.free(kname_safe);
        try std.fmt.format(out.writer(alloc),
            "{{\"keyId\":\"{s}\",\"name\":\"{s}\",\"createdMs\":{d},\"lastUsedMs\":{d},\"revoked\":{s}}}",
            .{ k.key_id[0..k.key_id_len], kname_safe, k.created_ms, k.last_used_ms,
               if (k.revoked) "true" else "false" });
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_revokeApiKey — owner revokes one of their keys.
/// Verified by signature on "EXCHANGE_APIKEY_REVOKE_V1\n<keyId>\n<owner>\n<nonce>".
pub fn handleExchangeRevokeApiKey(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const key_id = rpc.extractStr(body, "keyId") orelse
        return rpc.errorJson(-32602, "Missing param: keyId", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "EXCHANGE_APIKEY_REVOKE_V1\n{s}\n{s}\n{d}", .{ key_id, owner, nonce }) catch
        return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, owner)) {
        return rpc.errorJson(-32000, "Public key does not match owner", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const k = rpc.apiKeyLookup(ctx, key_id) orelse
        return rpc.errorJson(-32000, "Key not found or already revoked", id, alloc);
    if (k.owner_len != owner.len or !std.mem.eql(u8, k.owner[0..k.owner_len], owner)) {
        return rpc.errorJson(-32000, "Not owner of this key", id, alloc);
    }
    const last_nonce = rpc.nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used", id, alloc);
    }
    rpc.apiKeyRevoke(ctx, key_id);
    rpc.nonceSet(ctx, owner, nonce);

    var jbuf: [128]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf, "\"keyId\":\"{s}\",\"ts\":{d}", .{ key_id, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) rpc.usersAppendJournal(ctx, "revoke", jline);

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"keyId\":\"{s}\",\"revoked\":true}}}}",
        .{ id, key_id });
}

/// exchange_deposit — credit internal exchange balance.
/// On testnet/regtest: credits directly (no on-chain proof required).
/// On mainnet (chain_id == 1): requires a `txid` that actually sent OMNI
/// to the exchange escrow address — use exchange_depositReal instead.
pub fn handleExchangeDeposit(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;

    // Block fake-credit on mainnet — callers must use exchange_depositReal.
    if (ctx.chain_id == 1) {
        return rpc.errorJson(-32000,
            "exchange_deposit disabled on mainnet; use exchange_depositReal with a confirmed txid",
            id, alloc);
    }

    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const token = rpc.extractStr(body, "token") orelse "OMNI";
    const amount = rpc.extractArrayNumByKey(body, "amount");
    if (amount == 0) return rpc.errorJson(-32602, "Missing or zero: amount", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf,
        "EXCHANGE_DEPOSIT_V1\n{s}\n{s}\n{d}\n{d}",
        .{ owner, token, amount, nonce }) catch
        return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);
    if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
        return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
    }
    var pk_bytes: [33]u8 = undefined;
    _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
        return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
    const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
        return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
    defer alloc.free(derived_addr);
    if (!std.mem.eql(u8, derived_addr, owner)) {
        return rpc.errorJson(-32000, "Public key does not match owner", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = rpc.nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used", id, alloc);
    }

    if (!rpc.balanceCredit(ctx, owner, token, amount)) {
        return rpc.errorJson(-32000, "Balance table full", id, alloc);
    }
    rpc.nonceSet(ctx, owner, nonce);

    var jbuf: [256]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"{s}\",\"amount\":{d},\"ts\":{d}",
        .{ owner, token, amount, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) rpc.usersAppendJournal(ctx, "deposit", jline);

    const b = rpc.balanceLookup(ctx, owner, token).?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"{s}\",\"available\":{d},\"locked\":{d}}}}}",
        .{ id, owner, token, b.available_sat, b.locked_sat });
}

/// exchange_withdraw — debit internal balance. Symmetric to deposit;
/// on mainnet the chain would also credit the user's on-chain wallet
/// here (atomic transfer). Testnet: just debits the internal pool.
pub fn handleExchangeWithdraw(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const is_paper = rpc.isPaperMode(body);

    // Phase 1E: destination required for real mode (on-chain TX)
    const destination = if (!is_paper)
        (rpc.extractStr(body, "destination") orelse
            return rpc.errorJson(-32602, "Missing param: destination (for real mode)", id, alloc))
    else
        owner;  // paper mode: withdraw to self (internal debit only)

    const amount = rpc.extractArrayNumByKey(body, "amount");
    if (amount == 0) return rpc.errorJson(-32602, "Missing or zero: amount", id, alloc);
    const sig_hex = rpc.extractStr(body, "signature") orelse
        return rpc.errorJson(-32602, "Missing param: signature", id, alloc);
    const pubkey_hex = rpc.extractStr(body, "publicKey") orelse rpc.extractStr(body, "pubkey") orelse
        return rpc.errorJson(-32602, "Missing param: publicKey", id, alloc);
    const nonce = rpc.extractArrayNumByKey(body, "nonce");
    if (nonce == 0) return rpc.errorJson(-32602, "Missing or zero: nonce", id, alloc);

    // PHASE 1: REST HMAC-authenticated requests bypass ECDSA.
    const is_hmac_bypass = std.mem.eql(u8, sig_hex, "REST_HMAC_BYPASS");
    if (!is_hmac_bypass) {
        var msg_buf: [512]u8 = undefined;
        const msg_result = if (is_paper)
            std.fmt.bufPrint(&msg_buf,
                "EXCHANGE_WITHDRAW_V1\n{s}\nOMNI_DEMO\n{d}\n{d}",
                .{ owner, amount, nonce })
        else
            std.fmt.bufPrint(&msg_buf,
                "EXCHANGE_WITHDRAW_V1\n{s}\n{s}\nOMNI\n{d}\n{d}",
                .{ owner, destination, amount, nonce });

        const msg = msg_result catch
            return rpc.errorJson(-32603, "Failed to build sign message", id, alloc);

        if (!rpc.verifyOrderSig(msg, sig_hex, pubkey_hex)) {
            return rpc.errorJson(-32000, "Signature verify failed", id, alloc);
        }
        var pk_bytes: [33]u8 = undefined;
        _ = hex_utils.hexToBytes(pubkey_hex, &pk_bytes) catch
            return rpc.errorJson(-32000, "Bad pubkey hex", id, alloc);
        const derived_addr = rpc.deriveOBAddressFromPubkey(pk_bytes, alloc) catch
            return rpc.errorJson(-32000, "Cannot derive address from pubkey", id, alloc);
        defer alloc.free(derived_addr);
        if (!std.mem.eql(u8, derived_addr, owner)) {
            return rpc.errorJson(-32000, "Public key does not match owner", id, alloc);
        }
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const last_nonce = rpc.nonceLookup(ctx, owner);
    if (last_nonce >= 0 and @as(u64, @intCast(last_nonce)) >= nonce) {
        return rpc.errorJson(-32000, "Nonce already used", id, alloc);
    }

    // Phase 1E: Real mode creates on-chain TX, paper mode debits internal table
    if (is_paper) {
        const token = "OMNI_DEMO";
        if (!rpc.balanceDebit(ctx, owner, token, amount)) {
            return rpc.errorJson(-32000, "Insufficient balance", id, alloc);
        }
        rpc.nonceSet(ctx, owner, nonce);

        var jbuf: [256]u8 = undefined;
        const jline = std.fmt.bufPrint(&jbuf,
            "\"owner\":\"{s}\",\"token\":\"{s}\",\"amount\":{d},\"ts\":{d}",
            .{ owner, token, amount, std.time.milliTimestamp() }) catch "";
        if (jline.len > 0) rpc.usersAppendJournal(ctx, "withdraw", jline);

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"destination\":\"{s}\",\"amount\":{d},\"status\":\"completed\"}}}}",
            .{ id, owner, owner, amount });
    } else {
        // Real mode: check blockchain balance and create on-chain TX
        const balance = ctx.bc.getAddressBalance(owner);
        if (balance < amount) {
            return rpc.errorJson(-32000, "Insufficient blockchain balance", id, alloc);
        }

        // Create on-chain TX: owner -> destination
        var tx = transaction_mod.Transaction{
            .id = @intCast(@min(ctx.bc.chain.items.len, std.math.maxInt(u32))),
            .scheme = .omni_ecdsa,
            .from_address = try alloc.dupe(u8, owner),
            .to_address = try alloc.dupe(u8, destination),
            .amount = amount,
            .fee = 0,
            .timestamp = std.time.milliTimestamp(),
            .nonce = nonce,
            .op_return = "",
            .locktime = 0,
            .sequence = 0xFFFFFFFF,
            .script_pubkey = "",
            .script_sig = "",
            .signature = try alloc.dupe(u8, sig_hex),
            .hash = try alloc.dupe(u8, "pending"),  // will be computed during addTransaction
            .public_key = try alloc.dupe(u8, pubkey_hex),
        };

        // Add to blockchain
        ctx.bc.addTransaction(tx) catch |err| {
            alloc.free(tx.from_address);
            alloc.free(tx.to_address);
            alloc.free(tx.signature);
            alloc.free(tx.hash);
            alloc.free(tx.public_key);
            std.debug.print("[EXCHANGE] Withdraw TX creation failed: {}\n", .{err});
            return rpc.errorJson(-32603, "Failed to create withdraw TX", id, alloc);
        };
        defer {
            alloc.free(tx.from_address);
            alloc.free(tx.to_address);
            alloc.free(tx.signature);
            alloc.free(tx.hash);
            alloc.free(tx.public_key);
        }

        rpc.nonceSet(ctx, owner, nonce);

        var jbuf: [512]u8 = undefined;
        const jline = std.fmt.bufPrint(&jbuf,
            "\"owner\":\"{s}\",\"destination\":\"{s}\",\"amount\":{d},\"txHash\":\"{s}\",\"ts\":{d}",
            .{ owner, destination, amount, tx.hash[0..@min(64, tx.hash.len)], std.time.milliTimestamp() }) catch "";
        if (jline.len > 0) rpc.usersAppendJournal(ctx, "withdraw", jline);

        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"destination\":\"{s}\",\"amount\":{d},\"txHash\":\"{s}\",\"status\":\"pending\"}}}}",
            .{ id, owner, destination, amount, tx.hash[0..@min(64, tx.hash.len)] });
    }
}

/// exchange_getBalance — returns single address balance with reservation info (Phase 1B).
/// For real mode: balance from blockchain, reserved from orders.
/// For paper mode: balance from OMNI_DEMO internal table.
pub fn handleExchangeGetBalance(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const address = rpc.extractStr(body, "address") orelse rpc.extractStr(body, "owner") orelse
        return rpc.errorJson(-32602, "Missing param: address", id, alloc);
    const is_paper = rpc.isPaperMode(body);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    if (is_paper) {
        const b = rpc.balanceLookup(ctx, address, "OMNI_DEMO");
        const balance_amt = if (b) |bal| bal.available_sat else 0;
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"reserved\":0,\"available\":{d},\"mode\":\"paper\"}}}}",
            .{ id, address, balance_amt, balance_amt });
    } else {
        const balance = ctx.bc.getAddressBalance(address);
        const reserved = if (ctx.exchange) |eng|
            rpc.computeReservedFromOrderbook(eng, address)
        else
            0;
        const available = if (balance < reserved) 0 else (balance - reserved);
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"balance\":{d},\"reserved\":{d},\"available\":{d},\"mode\":\"real\"}}}}",
            .{ id, address, balance, reserved, available });
    }
}

/// exchange_getBalances — read-only listing of balances for an owner.
///
/// Real mode: balance comes from on-chain UTXO state (`getAddressBalance`),
/// `locked` = sum of remaining amounts in active sell orders for this address
/// (derived from orderbook, see computeReservedFromOrderbook). Single source
/// of truth — no internal balance table for real OMNI.
///
/// Paper mode: balance comes from internal `_DEMO`-suffixed table (sandbox
/// credits issued by exchange_depositDemo, never on-chain).
pub fn handleExchangeGetBalances(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);

    const is_paper = rpc.isPaperMode(body);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try std.fmt.format(out.writer(alloc), "{d}", .{id});
    try out.appendSlice(alloc, ",\"result\":[");

    if (is_paper) {
        // Paper mode: walk internal table for `_DEMO`-suffixed tokens only.
        var first = true;
        var i: u16 = 0;
        while (i < ctx.exstate.?.balance_count) : (i += 1) {
            const b = &ctx.exstate.?.balances[i];
            if (b.owner_len != owner.len) continue;
            if (!std.mem.eql(u8, b.owner[0..b.owner_len], owner)) continue;
            const token = b.token[0..b.token_len];
            if (!std.mem.endsWith(u8, token, "_DEMO")) continue;

            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            try std.fmt.format(out.writer(alloc),
                "{{\"token\":\"{s}\",\"available\":{d},\"locked\":{d}}}",
                .{ token, b.available_sat, b.locked_sat });
        }
    } else {
        // Real mode: OMNI balance from on-chain UTXO + orderbook-derived lock.
        const balance = ctx.bc.getAddressBalance(owner);
        const locked = if (ctx.exchange) |eng|
            rpc.computeReservedFromOrderbook(eng, owner)
        else
            0;
        const available = if (balance < locked) 0 else (balance - locked);
        try std.fmt.format(out.writer(alloc),
            "{{\"token\":\"OMNI\",\"available\":{d},\"locked\":{d}}}",
            .{ available, locked });
    }

    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// exchange_getEscrowAddress — return the on-chain address users send
/// real deposits to. Always the canonical exchange.omnibus registrar
/// wallet (slot #2). Never the local node's wallet.
pub fn handleExchangeGetEscrowAddress(ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const escrow = registrar_mod.addressOf(.exchange) orelse ctx.wallet.address;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"address\":\"{s}\",\"note\":\"Send OMNI to this address, then call exchange_depositReal with the txid\"}}}}",
        .{ id, escrow });
}

/// grid_create — pornește un grid nou pentru un owner pe o pereche.
/// Params: { pair_id, price_low, price_high, levels, total_base, total_quote, owner }
pub fn handleGridCreate(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const pair_id_u   = rpc.extractU64Param(body, "\"pair_id\"")    orelse return rpc.errorJson(-32602, "Missing pair_id", id, alloc);
    const price_low   = rpc.extractU64Param(body, "\"price_low\"")  orelse return rpc.errorJson(-32602, "Missing price_low", id, alloc);
    const price_high  = rpc.extractU64Param(body, "\"price_high\"") orelse return rpc.errorJson(-32602, "Missing price_high", id, alloc);
    const levels_u    = rpc.extractU64Param(body, "\"levels\"")     orelse return rpc.errorJson(-32602, "Missing levels", id, alloc);
    const total_base  = rpc.extractU64Param(body, "\"total_base\"") orelse return rpc.errorJson(-32602, "Missing total_base", id, alloc);
    const total_quote = rpc.extractU64Param(body, "\"total_quote\"") orelse return rpc.errorJson(-32602, "Missing total_quote", id, alloc);
    const owner      = rpc.extractStr(body, "owner") orelse return rpc.errorJson(-32602, "Missing owner", id, alloc);

    if (levels_u > grid_mod.MAX_LEVELS) return rpc.errorJson(-32602, "levels too large (max 100)", id, alloc);

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    const reg = ctx.grid_registry orelse return rpc.errorJson(-32000, "Grid engine not initialized", id, alloc);

    const current_block: u64 = ctx.bc.getBlockCount();
    const grid_id = reg.create(
        owner, @intCast(pair_id_u), price_low, price_high,
        @intCast(levels_u), total_base, total_quote, current_block,
    ) catch |err| return rpc.errorJson(-32000, @errorName(err), id, alloc);

    // Wire grid orders into the matching engine so they appear in the orderbook.
    if (ctx.exchange) |eng| reg.placeLevelOrders(grid_id, eng);

    if (rpc.gridPathSlice(ctx)) |p| reg.saveToFile(p) catch {};

    const g = reg.find(grid_id).?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
        "\"grid_id\":{d},\"pair_id\":{d},\"levels_generated\":{d}," ++
        "\"buy_orders\":{d},\"sell_orders\":{d},\"price_step\":{d}}}}}",
        .{ id, grid_id, pair_id_u, @as(u32, g.levels) * 2,
           g.levels, g.levels, g.priceStep() });
}

/// grid_list — listează grid-urile active (opțional filtrate după owner).
/// Params: { owner? }
pub fn handleGridList(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const filter_owner = rpc.extractStr(body, "owner");

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try std.fmt.format(out.writer(alloc), "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});

    var first = true;
    if (ctx.grid_registry) |reg| {
        var i: u32 = 0;
        while (i < reg.count) : (i += 1) {
            const g = &reg.grids[i];
            if (filter_owner) |fo| {
                if (!std.mem.eql(u8, g.owner[0..g.owner_len], fo)) continue;
            }
            if (!first) try out.appendSlice(alloc, ",");
            first = false;
            try grid_mod.writeGridJson(g, &out, alloc);
        }
    }
    try out.appendSlice(alloc, "]}");
    return alloc.dupe(u8, out.items);
}

/// grid_status — detalii complete pentru un grid (inclusiv levels calculate).
/// Params: { grid_id }
pub fn handleGridStatus(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const grid_id = rpc.extractU64Param(body, "\"grid_id\"") orelse
        return rpc.errorJson(-32602, "Missing grid_id", id, alloc);

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    const reg = ctx.grid_registry orelse return rpc.errorJson(-32000, "Grid engine not initialized", id, alloc);
    const g = reg.find(grid_id) orelse return rpc.errorJson(-32602, "Grid not found", id, alloc);

    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    // Open the JSON-RPC envelope and result object inline so we can append
    // buy_levels/sell_levels INSIDE the same result object.
    // We do NOT call writeGridJson here because that emits a complete {...} object
    // and appending after its closing brace produces invalid JSON.
    {
        const w = out.writer(alloc);
        try std.fmt.format(w,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{" ++
            "\"grid_id\":{d},\"pair_id\":{d},\"owner\":\"",
            .{ id, g.id, g.pair_id });
        try rpc.writeJsonSafeStr(w, g.owner[0..g.owner_len]);
        try std.fmt.format(w,
            "\"," ++
            "\"price_low\":{d},\"price_high\":{d},\"levels\":{d}," ++
            "\"total_base\":{d},\"total_quote\":{d}," ++
            "\"filled_count\":{d},\"profit_quote\":{d},\"active\":{s}," ++
            "\"created_block\":{d}",
            .{
                g.price_low, g.price_high, g.levels,
                g.total_base, g.total_quote,
                g.filled_count, g.profit_quote,
                if (g.active) "true" else "false",
                g.created_block,
            });
    }

    // Adaugă levels calculate (still inside the result object)
    try out.appendSlice(alloc, ",\"buy_levels\":[");
    var lvl: u16 = 0;
    while (lvl < g.levels) : (lvl += 1) {
        if (lvl > 0) try out.appendSlice(alloc, ",");
        try std.fmt.format(out.writer(alloc),
            "{{\"level\":{d},\"price\":{d},\"amount\":{d}}}",
            .{ lvl, g.buyPrice(lvl), g.basePerLevel() });
    }
    try out.appendSlice(alloc, "],\"sell_levels\":[");
    lvl = 0;
    while (lvl < g.levels) : (lvl += 1) {
        if (lvl > 0) try out.appendSlice(alloc, ",");
        try std.fmt.format(out.writer(alloc),
            "{{\"level\":{d},\"price\":{d},\"amount\":{d}}}",
            .{ lvl, g.sellPrice(lvl), g.basePerLevel() });
    }
    // Close: sell_levels array "]", result object "}", envelope "}"
    try out.appendSlice(alloc, "]}}");
    return alloc.dupe(u8, out.items);
}

/// grid_cancel — oprește un grid activ.
/// Params: { grid_id, owner }
pub fn handleGridCancel(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    const grid_id = rpc.extractU64Param(body, "\"grid_id\"") orelse
        return rpc.errorJson(-32602, "Missing grid_id", id, alloc);
    const owner = rpc.extractStr(body, "owner") orelse
        return rpc.errorJson(-32602, "Missing owner", id, alloc);

    ctx.grid_mutex.lock();
    defer ctx.grid_mutex.unlock();

    const reg = ctx.grid_registry orelse return rpc.errorJson(-32000, "Grid engine not initialized", id, alloc);
    reg.cancel(grid_id, owner) catch |err| return rpc.errorJson(-32000, @errorName(err), id, alloc);

    if (rpc.gridPathSlice(ctx)) |p| reg.saveToFile(p) catch {};

    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"grid_id\":{d},\"cancelled\":true}}}}",
        .{ id, grid_id });
}

/// exchange_depositDemo — credit testnet/sandbox demo OMNI to internal
/// exchange balance. Per-address rate-limited (max 10 OMNI per request,
/// max 100 OMNI / 24h rolling window). Marks the credited balance row
/// with token "OMNI_DEMO" so demo and real money are visibly separate
/// and never mixed when settling trades. No on-chain TX needed.
pub fn handleExchangeDepositDemo(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.exstate == null) return rpc.errorJson(-32601, "Exchange not enabled on this node", id, alloc);

    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const amount = rpc.extractArrayNumByKey(body, "amount");
    if (amount == 0) return rpc.errorJson(-32602, "Missing or zero: amount", id, alloc);
    if (amount > rpc.DEMO_MAX_PER_REQUEST_SAT) {
        return rpc.errorJson(-32000, "Demo deposit too large (max 10 OMNI per request)", id, alloc);
    }
    if (owner.len > 64 or owner.len < 4) return rpc.errorJson(-32602, "Bad owner address", id, alloc);

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const es = ctx.exstate.?;
    const now_ms = std.time.milliTimestamp();
    const q = rpc.demoQuotaGetOrCreate(es, owner) orelse
        return rpc.errorJson(-32000, "Demo quota table full", id, alloc);

    // Reset the rolling window if it's been 24h since first grant.
    if (now_ms - q.window_start_ms > rpc.DEMO_WINDOW_MS) {
        q.granted_sat = 0;
        q.window_start_ms = now_ms;
    }
    if (q.granted_sat + amount > rpc.DEMO_MAX_PER_24H_SAT) {
        const remaining = if (q.granted_sat >= rpc.DEMO_MAX_PER_24H_SAT) 0
            else rpc.DEMO_MAX_PER_24H_SAT - q.granted_sat;
        return std.fmt.allocPrint(alloc,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32000,\"message\":\"Daily demo limit reached. {d} SAT remaining in this 24h window.\"}}}}",
            .{ id, remaining });
    }

    if (!rpc.balanceCredit(ctx, owner, "OMNI_DEMO", amount)) {
        return rpc.errorJson(-32000, "Balance table full", id, alloc);
    }
    q.granted_sat += amount;

    var jbuf: [256]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"OMNI_DEMO\",\"amount\":{d},\"ts\":{d}",
        .{ owner, amount, now_ms }) catch "";
    if (jline.len > 0) rpc.usersAppendJournal(ctx, "deposit", jline);

    const b = rpc.balanceLookup(ctx, owner, "OMNI_DEMO").?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"OMNI_DEMO\",\"amount\":{d},\"available\":{d},\"locked\":{d},\"granted24h\":{d},\"max24h\":{d},\"kind\":\"demo\"}}}}",
        .{ id, owner, amount, b.available_sat, b.locked_sat, q.granted_sat, rpc.DEMO_MAX_PER_24H_SAT });
}

/// exchange_depositReal — credit a deposit ONLY after verifying that an
/// on-chain TX really transferred OMNI from the user to the escrow
/// address. Idempotent (each txid usable exactly once). The credited
/// row uses token "OMNI" (real money) so trades against demo balances
/// can be kept separate.
pub fn handleExchangeDepositReal(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8 {
    const alloc = ctx.allocator;
    if (ctx.exstate == null) return rpc.errorJson(-32601, "Exchange not enabled on this node", id, alloc);

    const owner = rpc.extractStr(body, "owner") orelse rpc.extractStr(body, "address") orelse
        return rpc.errorJson(-32602, "Missing param: owner", id, alloc);
    const txid = rpc.extractStr(body, "txid") orelse rpc.extractStr(body, "txHash") orelse
        return rpc.errorJson(-32602, "Missing param: txid", id, alloc);
    if (txid.len != 64) return rpc.errorJson(-32602, "txid must be 64 hex chars", id, alloc);

    const escrow = ctx.wallet.address;

    // Look the TX up on-chain. Mirrors handleGetTx logic — same indexes.
    ctx.bc.mutex.lock();
    defer ctx.bc.mutex.unlock();

    var found_tx: ?transaction_mod.Transaction = null;
    var confirmations: u64 = 0;
    if (ctx.bc.tx_block_height.get(txid)) |bh| {
        if (bh < ctx.bc.chain.items.len) {
            const blk = ctx.bc.chain.items[bh];
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    const tip: u64 = @intCast(ctx.bc.chain.items.len);
                    confirmations = if (tip > bh) tip - bh else 0;
                    break;
                }
            }
        }
    }
    if (found_tx == null) {
        // Linear scan fallback — older TXs not in index.
        outer: for (ctx.bc.chain.items) |blk| {
            for (blk.transactions.items) |tx| {
                if (std.mem.eql(u8, tx.hash, txid)) {
                    found_tx = tx;
                    const tip: u64 = @intCast(ctx.bc.chain.items.len);
                    const bh: u64 = @intCast(blk.index);
                    confirmations = if (tip > bh) tip - bh else 0;
                    break :outer;
                }
            }
        }
    }
    const tx = found_tx orelse return rpc.errorJson(-32000, "Transaction not found in chain (still pending? wait for confirmation)", id, alloc);

    if (!std.mem.eql(u8, tx.from_address, owner)) {
        return rpc.errorJson(-32000, "TX sender does not match owner address", id, alloc);
    }
    if (!std.mem.eql(u8, tx.to_address, escrow)) {
        return rpc.errorJson(-32000, "TX recipient is not the exchange escrow address", id, alloc);
    }
    if (confirmations < 1) {
        return rpc.errorJson(-32000, "TX not yet confirmed (need >= 1 block)", id, alloc);
    }

    ctx.exchange_mutex.lock();
    defer ctx.exchange_mutex.unlock();

    const es = ctx.exstate.?;
    if (rpc.realDepositTxidUsed(es, txid)) {
        return rpc.errorJson(-32000, "This txid has already been credited", id, alloc);
    }

    if (!rpc.balanceCredit(ctx, owner, "OMNI", tx.amount)) {
        return rpc.errorJson(-32000, "Balance table full", id, alloc);
    }
    _ = rpc.realDepositTxidRecord(es, txid);

    var jbuf: [320]u8 = undefined;
    const jline = std.fmt.bufPrint(&jbuf,
        "\"owner\":\"{s}\",\"token\":\"OMNI\",\"amount\":{d},\"txid\":\"{s}\",\"ts\":{d}",
        .{ owner, tx.amount, txid, std.time.milliTimestamp() }) catch "";
    if (jline.len > 0) rpc.usersAppendJournal(ctx, "deposit", jline);

    const b = rpc.balanceLookup(ctx, owner, "OMNI").?;
    return std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"owner\":\"{s}\",\"token\":\"OMNI\",\"amount\":{d},\"available\":{d},\"locked\":{d},\"txid\":\"{s}\",\"confirmations\":{d},\"kind\":\"real\"}}}}",
        .{ id, owner, tx.amount, b.available_sat, b.locked_sat, txid, confirmations });
}
