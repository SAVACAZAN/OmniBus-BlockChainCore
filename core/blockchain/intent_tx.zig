//! Intent transaction handler extracted from blockchain.zig.
//!
//! Free function taking `*Blockchain`. The Blockchain struct in
//! blockchain.zig re-exposes it via a thin method shim so callers keep
//! using `bc.applyIntentTx(...)` syntax.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const tx_payload_mod = @import("../tx_payload.zig");
const intent_reg_mod = @import("../intent_registry.zig");
const main_mod = @import("../main.zig");

const Blockchain = blockchain_mod.Blockchain;
const Transaction = blockchain_mod.Transaction;

// ─── PHASE 2F.3: intent TX state transitions ─────────────────────────
//
// Intent TXs (0x40/0x41/0x43) carry signed off-chain swap commitments
// through the chain so every node converges on the same SwapBinding
// state. They do NOT move coin directly — bond locking is virtual via
// bc.balances; settlement happens through the htlc_claim that the
// taker eventually broadcasts on the destination chain. This function
// emits WS events so the UI/orderbook can react in real time.
//
// Intent semantics here are intentionally minimal — the swap_registry
// already captures full state via order_swap_link.zig, so applyIntentTx
// serves mainly as: (a) on-chain receipt for solvers, (b) WS broadcast
// surface, (c) a hook for future bond accounting. Errors are logged
// and the TX is accepted into history regardless — the caller filters.
pub fn applyIntentTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
    switch (tx.tx_type) {
        .intent_post => {
            const payload = try tx_payload_mod.IntentPostPayload.decode(tx.data);
            try payload.validate();

            // Bond accounting: maker locks `maker_amount_sat` worth of
            // collateral up-front. Without this, a malicious maker can
            // spam intents that cost them nothing and waste solver
            // bond bandwidth. We treat `maker_amount_sat` itself as
            // the maker's locked-bond size — the asset they're offering
            // — which matches how the matching engine collateralises
            // the parent order.
            //
            // We try the debit but DO NOT abort the TX on insufficient
            // funds: applyBlock is called for every TX in a block, and
            // a fork or replay must not panic the chain. If the maker
            // is broke, we emit a "warning" event and skip registry
            // entry — the order itself was already validated by mempool
            // admission, so insufficient funds at apply time means the
            // maker double-spent during the block window.
            const maker_bond = payload.maker_amount_sat;
            self.debitBalanceLocked(tx.from_address, maker_bond) catch |err| {
                std.debug.print(
                    "[INTENT] post: cannot lock maker bond {d} for {s}: {} — entry skipped\n",
                    .{ maker_bond, tx.from_address[0..@min(20, tx.from_address.len)], err },
                );
                if (main_mod.g_ws_srv) |ws| {
                    var iid_hex: [64]u8 = undefined;
                    for (payload.intent_id, 0..) |b, i| {
                        _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                    }
                    var json_buf: [256]u8 = undefined;
                    const j = std.fmt.bufPrint(&json_buf,
                        "{{\"type\":\"intent_post_failed\",\"intent_id\":\"{s}\",\"reason\":\"insufficient_bond\"}}",
                        .{ &iid_hex }) catch null;
                    if (j) |s| ws.broadcast(s);
                }
                return;
            };

            // Build the registry entry. Caller's address slice is owned
            // by the TX, but we copy into the entry's fixed buffer so
            // it survives independently.
            if (tx.from_address.len > intent_reg_mod.MAX_ADDR_LEN) {
                // Refund the bond we just took — entry can't be created.
                self.creditBalanceLocked(tx.from_address, maker_bond) catch {};
                return error.IntentAddressTooLong;
            }
            var entry: intent_reg_mod.IntentEntry = .{
                .intent_id = payload.intent_id,
                .swap_id = payload.swap_id,
                .maker_amount_sat = payload.maker_amount_sat,
                .taker_min_sat = payload.taker_min_sat,
                .maker_bond_locked_sat = maker_bond,
                .expiry_block = payload.expiry_block,
                .state = .posted,
            };
            @memcpy(entry.maker_address[0..tx.from_address.len], tx.from_address);
            entry.maker_address_len = @intCast(tx.from_address.len);
            self.intent_registry.addEntry(entry) catch |err| {
                // Refund on duplicate/full so book stays balanced.
                self.creditBalanceLocked(tx.from_address, maker_bond) catch {};
                std.debug.print("[INTENT] post addEntry failed: {} (bond refunded)\n", .{err});
                return;
            };

            if (main_mod.g_ws_srv) |ws| {
                var iid_hex: [64]u8 = undefined;
                var sid_hex: [64]u8 = undefined;
                for (payload.intent_id, 0..) |b, i| {
                    _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                }
                for (payload.swap_id, 0..) |b, i| {
                    _ = std.fmt.bufPrint(sid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                }
                var json_buf: [768]u8 = undefined;
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"intent_posted\",\"intent_id\":\"{s}\",\"swap_id\":\"{s}\",\"maker\":\"{s}\",\"taker_chain\":{d},\"expiry_block\":{d},\"maker_amount_sat\":{d},\"maker_bond_locked_sat\":{d}}}",
                    .{ &iid_hex, &sid_hex, tx.from_address, payload.taker_chain,
                       payload.expiry_block, payload.maker_amount_sat, maker_bond }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        .intent_fill_commit => {
            const payload = try tx_payload_mod.IntentFillCommitPayload.decode(tx.data);
            try payload.validate();

            // Look up the parent intent. If it doesn't exist (rogue
            // commit, or post was skipped due to insufficient bond), we
            // skip registry mutation but accept the TX into history so
            // the address index sees it.
            const parent_opt = self.intent_registry.findById(payload.intent_id);
            if (parent_opt == null) {
                std.debug.print("[INTENT] fill_commit: unknown intent_id — TX accepted, no bond locked\n", .{});
                return;
            }
            const parent = parent_opt.?;
            if (parent.state != .posted) {
                std.debug.print("[INTENT] fill_commit: intent in state {} — TX accepted, no bond locked\n",
                    .{parent.state});
                return;
            }

            // Lock the solver's bond from their on-chain balance.
            self.debitBalanceLocked(tx.from_address, payload.bond_locked_sat) catch |err| {
                std.debug.print(
                    "[INTENT] fill_commit: cannot lock taker bond {d} for {s}: {} — TX accepted, registry unchanged\n",
                    .{ payload.bond_locked_sat, tx.from_address[0..@min(20, tx.from_address.len)], err },
                );
                return;
            };

            self.intent_registry.commitFill(
                payload.intent_id,
                tx.from_address,
                payload.bond_locked_sat,
                payload.commit_block,
            ) catch |err| {
                // Roll back the debit so the taker's balance is consistent.
                self.creditBalanceLocked(tx.from_address, payload.bond_locked_sat) catch {};
                std.debug.print("[INTENT] commitFill failed: {} (bond refunded)\n", .{err});
                return;
            };

            if (main_mod.g_ws_srv) |ws| {
                var iid_hex: [64]u8 = undefined;
                for (payload.intent_id, 0..) |b, i| {
                    _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                }
                var json_buf: [512]u8 = undefined;
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"intent_committed\",\"intent_id\":\"{s}\",\"taker\":\"{s}\",\"bond_locked_sat\":{d},\"commit_block\":{d}}}",
                    .{ &iid_hex, tx.from_address, payload.bond_locked_sat, payload.commit_block }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        .intent_timeout => {
            const payload = try tx_payload_mod.IntentTimeoutPayload.decode(tx.data);
            try payload.validate();

            const parent_opt = self.intent_registry.findById(payload.intent_id);
            if (parent_opt == null) {
                std.debug.print("[INTENT] timeout: unknown intent_id — TX accepted, no slash applied\n", .{});
                return;
            }
            const parent = parent_opt.?;

            // Two valid prior states:
            //  * .committed → taker bond is slashed to maker (penalty
            //    for missing the deadline). Maker bond is also returned.
            //  * .posted    → no taker bond exists; only the maker
            //    bond is refunded (intent expired before any solver
            //    committed — no slash, just cleanup).
            // Any other state (.settled / .timed_out) is a no-op.
            if (parent.state == .committed) {
                const slash_amount = if (payload.slashed_bond_sat == 0)
                    parent.taker_bond_locked_sat
                else
                    @min(payload.slashed_bond_sat, parent.taker_bond_locked_sat);

                // Slash → maker.
                if (slash_amount > 0 and parent.maker_address_len > 0) {
                    self.creditBalanceLocked(parent.makerSlice(), slash_amount) catch |err| {
                        std.debug.print("[INTENT] timeout: slash credit failed: {}\n", .{err});
                    };
                }
                // Refund any excess taker bond back to taker (not slashed).
                const taker_refund = parent.taker_bond_locked_sat - slash_amount;
                if (taker_refund > 0 and parent.taker_address_len > 0) {
                    self.creditBalanceLocked(parent.takerSlice(), taker_refund) catch {};
                }
                // Refund maker bond to maker.
                if (parent.maker_bond_locked_sat > 0 and parent.maker_address_len > 0) {
                    self.creditBalanceLocked(parent.makerSlice(), parent.maker_bond_locked_sat) catch {};
                }
                self.intent_registry.markTimedOut(payload.intent_id) catch {};
            } else if (parent.state == .posted) {
                // Only refund maker bond — no taker exists.
                if (parent.maker_bond_locked_sat > 0 and parent.maker_address_len > 0) {
                    self.creditBalanceLocked(parent.makerSlice(), parent.maker_bond_locked_sat) catch {};
                }
                self.intent_registry.markTimedOut(payload.intent_id) catch {};
            } else {
                std.debug.print("[INTENT] timeout: state {} — no-op\n", .{parent.state});
            }

            if (main_mod.g_ws_srv) |ws| {
                var iid_hex: [64]u8 = undefined;
                for (payload.intent_id, 0..) |b, i| {
                    _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                }
                var json_buf: [512]u8 = undefined;
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"intent_timed_out\",\"intent_id\":\"{s}\",\"slashed_bond_sat\":{d},\"block_height\":{d}}}",
                    .{ &iid_hex, payload.slashed_bond_sat, block_height }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        .intent_settle => {
            // Settlement: parse intent_id from the payload (first 32 bytes
            // after the version byte — same convention as the other
            // intent payloads). Refund both bonds to their owners.
            //
            // We don't have a strict IntentSettlePayload decoder yet
            // (validatePayload accepts any non-empty bytes for this
            // type — see tx_payload.zig). The minimal field we need
            // is intent_id; tx.data layout: [0]=version, [1..33]=intent_id.
            if (tx.data.len < 33 or tx.data[0] != 1) {
                std.debug.print("[INTENT] settle: bad payload — TX accepted, no bond movement\n", .{});
                return;
            }
            var iid: [32]u8 = undefined;
            @memcpy(&iid, tx.data[1..33]);

            const parent_opt = self.intent_registry.findById(iid);
            if (parent_opt == null) {
                std.debug.print("[INTENT] settle: unknown intent_id\n", .{});
                return;
            }
            const parent = parent_opt.?;
            if (parent.state != .posted and parent.state != .committed) {
                return; // already terminal — no-op
            }
            // Refund both bonds to their owners.
            if (parent.maker_bond_locked_sat > 0 and parent.maker_address_len > 0) {
                self.creditBalanceLocked(parent.makerSlice(), parent.maker_bond_locked_sat) catch {};
            }
            if (parent.taker_bond_locked_sat > 0 and parent.taker_address_len > 0) {
                self.creditBalanceLocked(parent.takerSlice(), parent.taker_bond_locked_sat) catch {};
            }
            self.intent_registry.markSettled(iid) catch {};

            if (main_mod.g_ws_srv) |ws| {
                var iid_hex: [64]u8 = undefined;
                for (iid, 0..) |b, i| {
                    _ = std.fmt.bufPrint(iid_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                }
                var json_buf: [384]u8 = undefined;
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"intent_settled\",\"intent_id\":\"{s}\",\"maker_bond_refunded\":{d},\"taker_bond_refunded\":{d}}}",
                    .{ &iid_hex, parent.maker_bond_locked_sat, parent.taker_bond_locked_sat }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        else => {}, // not an intent TX — caller filtered already
    }
}
