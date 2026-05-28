//! HTLC transaction handler extracted from blockchain.zig.
//!
//! Free function taking `*Blockchain`. The Blockchain struct in
//! blockchain.zig re-exposes it via a thin method shim so callers keep
//! using `bc.applyHtlcTx(...)` syntax.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const tx_payload_mod = @import("../tx_payload.zig");
const htlc_mod = @import("../htlc.zig");
const main_mod = @import("../main.zig");

const Blockchain = blockchain_mod.Blockchain;
const Transaction = blockchain_mod.Transaction;

// ─── PHASE 2F.2 — HTLC state transitions ────────────────────────────
//
// Dispatch a single HTLC-typed TX (htlc_init / htlc_claim / htlc_refund).
// Called from applyBlock for every TX whose `tx_type` is in the HTLC
// group. Funds are tracked virtually: bc.balances is the only ledger
// touched. UTXO state is intentionally left alone — htlc_init carries
// amount=0 on the typed envelope; the locked value lives entirely in
// the registry until claim/refund releases it back into bc.balances.
//
// This emits WS events on success (htlc_created/htlc_claimed/htlc_refunded)
// so the UI can react in real time. Errors are logged and the TX is
// skipped — applyBlock keeps going so a single bad HTLC TX cannot stall
// the rest of the block.
pub fn applyHtlcTx(self: *Blockchain, tx: Transaction, block_height: u32) !void {
    switch (tx.tx_type) {
        .htlc_init => {
            const payload = try tx_payload_mod.HtlcInitPayload.decode(tx.data);
            try payload.validate();

            // Sender must have enough free balance to lock.
            const sender_bal = self.balances.get(tx.from_address) orelse 0;
            if (sender_bal < payload.amount_sat) return error.HtlcInsufficientFunds;

            // Build the deterministic 32-byte id from the init TX hash.
            const id = htlc_mod.computeHtlcId(tx.hash);

            // Build entry. sender = tx.from_address, recipient = tx.to_address.
            if (tx.from_address.len > htlc_mod.HTLC_MAX_ADDR_LEN) return error.HtlcAddressTooLong;
            if (tx.to_address.len > htlc_mod.HTLC_MAX_ADDR_LEN) return error.HtlcAddressTooLong;

            var e = htlc_mod.HtlcEntry{
                .id = id,
                .amount_sat = payload.amount_sat,
                .hash_lock = payload.hash_lock,
                .timelock_block = payload.timelock_block,
                .init_block = block_height,
                .state = .active,
            };
            @memcpy(e.sender[0..tx.from_address.len], tx.from_address);
            e.sender_len = @intCast(tx.from_address.len);
            @memcpy(e.recipient[0..tx.to_address.len], tx.to_address);
            e.recipient_len = @intCast(tx.to_address.len);
            if (tx.hash.len <= 64) {
                @memcpy(e.init_tx_hash[0..tx.hash.len], tx.hash);
                e.init_tx_hash_len = @intCast(tx.hash.len);
            }

            try self.htlc_registry.addEntry(e);
            // Lock sender funds (debit balance — held until claim/refund).
            try self.debitBalanceLocked(tx.from_address, payload.amount_sat);

            // WS event: htlc_created.
            if (main_mod.g_ws_srv) |ws| {
                var json_buf: [512]u8 = undefined;
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"htlc_created\",\"htlc_id\":\"{s}\",\"sender\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"timelock_block\":{d}}}",
                    .{ tx.hash, tx.from_address, tx.to_address, payload.amount_sat, payload.timelock_block }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        .htlc_claim => {
            const payload = try tx_payload_mod.HtlcClaimPayload.decode(tx.data);
            try payload.validate();

            // Lookup BEFORE applying claim so we can validate identity.
            const entry_opt = self.htlc_registry.get(payload.htlc_id);
            const entry = entry_opt orelse return error.HtlcNotFound;
            if (entry.state != .active) return error.HtlcNotActive;
            // Only the registered recipient can claim.
            if (!std.mem.eql(u8, entry.recipientSlice(), tx.from_address))
                return error.HtlcUnauthorizedClaim;

            try self.htlc_registry.applyClaim(payload.htlc_id, payload.preimage);
            // Release locked funds to recipient (== tx.from_address here).
            try self.creditBalanceLocked(tx.from_address, entry.amount_sat);

            if (main_mod.g_ws_srv) |ws| {
                var json_buf: [512]u8 = undefined;
                var pre_hex: [64]u8 = undefined;
                for (payload.preimage, 0..) |b, i| {
                    _ = std.fmt.bufPrint(pre_hex[i*2..i*2+2], "{x:0>2}", .{b}) catch {};
                }
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"htlc_claimed\",\"htlc_id_tx\":\"{s}\",\"recipient\":\"{s}\",\"amount_sat\":{d},\"preimage\":\"{s}\"}}",
                    .{ tx.hash, tx.from_address, entry.amount_sat, &pre_hex }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        .htlc_refund => {
            const payload = try tx_payload_mod.HtlcRefundPayload.decode(tx.data);
            try payload.validate();

            const entry_opt = self.htlc_registry.get(payload.htlc_id);
            const entry = entry_opt orelse return error.HtlcNotFound;
            if (entry.state != .active and entry.state != .expired)
                return error.HtlcNotRefundable;
            // Only the original sender can refund.
            if (!std.mem.eql(u8, entry.senderSlice(), tx.from_address))
                return error.HtlcUnauthorizedRefund;
            if (block_height < entry.timelock_block) return error.HtlcNotExpired;

            try self.htlc_registry.applyRefund(payload.htlc_id, block_height);
            // Return locked funds to sender.
            try self.creditBalanceLocked(tx.from_address, entry.amount_sat);

            if (main_mod.g_ws_srv) |ws| {
                var json_buf: [512]u8 = undefined;
                const json = std.fmt.bufPrint(&json_buf,
                    "{{\"type\":\"htlc_refunded\",\"htlc_id_tx\":\"{s}\",\"sender\":\"{s}\",\"amount_sat\":{d}}}",
                    .{ tx.hash, tx.from_address, entry.amount_sat }) catch null;
                if (json) |j| ws.broadcast(j);
            }
        },
        else => {}, // not an HTLC TX — caller filtered already
    }
}
