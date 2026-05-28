//! op_return dispatcher extracted from blockchain.zig.
//!
//! Single large dispatch function that routes op_return prefixes to the
//! on-chain registries (stake/unstake/agent/pq_attest/label/sub/notarize/
//! escrow/social/poap/gov/...). Kept as a free function taking
//! `*Blockchain`; Blockchain.applyOpReturnRoles is a thin shim.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const transaction_mod = @import("../transaction.zig");
const main_mod = @import("../main.zig");
const staking_mod = @import("../staking.zig");
const label_mod = @import("../label.zig");
const sub_mod = @import("../subscription.zig");
const notarize_mod = @import("../notarize.zig");
const escrow_mod = @import("../escrow.zig");
const social_mod = @import("../social_graph.zig");
const poap_mod = @import("../poap.zig");
const gov_mod = @import("../governance_onchain.zig");

const Blockchain = blockchain_mod.Blockchain;
const Transaction = transaction_mod.Transaction;
const PqIdentity = blockchain_mod.PqIdentity;
const persistPqIdentityAppend = blockchain_mod.persistPqIdentityAppend;

pub fn applyOpReturnRoles(self: *Blockchain, tx: Transaction) void {
    if (tx.op_return.len == 0 or tx.from_address.len == 0) return;
    if (std.mem.startsWith(u8, tx.op_return, "stake:")) {
        // Cap stake at the user's actual balance. Without this we'd
        // accept stake > balance which would later make unstake credit
        // back funds the user never owned.
        const cur_bal = self.balances.get(tx.from_address) orelse 0;
        const effective = @min(tx.amount, cur_bal);
        if (effective == 0) return;

        // Parse optional lock_blocks suffix: "stake:<amt>:<lock_blocks>".
        // The colon-amt segment is informational (we use tx.amount as the
        // source of truth for SAT) but `lock_blocks` after a second colon
        // is the user's commitment. Older clients send "stake:<amt>" with
        // no second colon → lock_blocks = 0 (immediate unstake allowed).
        var lock_blocks: u64 = 0;
        if (std.mem.indexOfScalarPos(u8, tx.op_return, "stake:".len, ':')) |second_colon| {
            const lock_str = tx.op_return[second_colon + 1 ..];
            lock_blocks = std.fmt.parseInt(u64, lock_str, 10) catch 0;
        }

        // Debit balance (lock funds). Caller (applyBlock) already holds
        // the chain mutex AND has set in_apply_block=true, so the
        // phantom-write detector is happy.
        self.debitBalanceLocked(tx.from_address, effective) catch return;

        const owned = self.allocator.dupe(u8, tx.from_address) catch return;
        const gop = self.stake_amounts.getOrPut(owned) catch {
            self.allocator.free(owned);
            return;
        };
        if (gop.found_existing) {
            self.allocator.free(owned);
        } else {
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* +|= effective; // saturating add

        // Update stake_meta. On top-up: keep the EARLIEST started_at
        // (so the lock countdown starts from the first stake) and the
        // MAX lock_blocks (longest commitment wins). Fresh stake gets
        // both fields populated from current block height + parsed
        // lock_blocks.
        const meta_key = self.allocator.dupe(u8, tx.from_address) catch return;
        const meta_gop = self.stake_meta.getOrPut(meta_key) catch {
            self.allocator.free(meta_key);
            return;
        };
        const current_block: u64 = @intCast(self.chain.items.len);
        if (meta_gop.found_existing) {
            self.allocator.free(meta_key);
            // Keep earliest start; pick max of existing and new lock.
            if (lock_blocks > meta_gop.value_ptr.lock_blocks) {
                meta_gop.value_ptr.lock_blocks = lock_blocks;
            }
        } else {
            meta_gop.value_ptr.* = .{
                .started_at_block = current_block,
                .lock_blocks = lock_blocks,
            };
        }

        // Auto-promote to validator when total stake >= VALIDATOR_MIN_STAKE
        // (100 OMNI). Reads main_mod.g_staking_engine which is set in
        // main.zig at init. Idempotent: existing validators just have
        // their total_stake updated; new ones are registered + activated.
        if (main_mod.g_staking_engine) |se| {
            if (gop.value_ptr.* >= staking_mod.VALIDATOR_MIN_STAKE) {
                const block_h = self.chain.items.len;
                if (se.findValidatorIndex(tx.from_address)) |idx| {
                    // Already registered — update stake amount
                    se.validators[idx].total_stake = gop.value_ptr.*;
                    se.validators[idx].self_stake = gop.value_ptr.*;
                } else if (se.registerValidator(
                    tx.from_address,
                    gop.value_ptr.*,
                    @intCast(block_h),
                )) |new_idx| {
                    se.activateValidator(new_idx) catch {};
                } else |_| {
                    // ValidatorSetFull or AlreadyRegistered — silent skip
                }
            }
        }
    } else if (std.mem.startsWith(u8, tx.op_return, "unstake:")) {
        // Unstake: credit back the user's full stake to their balance.
        // (Future: parse partial unstake amount from op_return; for now
        // we unstake everything stored under this address.)
        const cur_stake = self.stake_amounts.get(tx.from_address) orelse 0;
        if (cur_stake == 0) return;

        // Enforce lock period if metadata says so. Older stakes with
        // lock_blocks=0 (legacy or explicit no-lock) bypass this check.
        if (self.stake_meta.get(tx.from_address)) |meta| {
            if (meta.lock_blocks > 0) {
                const current_block: u64 = @intCast(self.chain.items.len);
                const unlock_at = meta.unlockAtBlock();
                if (current_block < unlock_at) {
                    // Lock not yet expired — drop unstake silently
                    // (no-op for non-failure path; user keeps stake).
                    return;
                }
            }
        }

        self.creditBalanceLocked(tx.from_address, cur_stake) catch return;

        const owned = self.allocator.dupe(u8, tx.from_address) catch return;
        const gop = self.stake_amounts.getOrPut(owned) catch {
            self.allocator.free(owned);
            return;
        };
        if (gop.found_existing) {
            self.allocator.free(owned);
        }
        gop.value_ptr.* = 0; // clear stake

        // Clean up stake_meta — entry no longer applies.
        if (self.stake_meta.fetchRemove(tx.from_address)) |kv| {
            self.allocator.free(kv.key);
        }
    } else if (std.mem.startsWith(u8, tx.op_return, "agent:register")) {
        const owned = self.allocator.dupe(u8, tx.from_address) catch return;
        const gop = self.registered_agents.getOrPut(owned) catch {
            self.allocator.free(owned);
            return;
        };
        if (gop.found_existing) {
            self.allocator.free(owned);
        }
    } else if (std.mem.startsWith(u8, tx.op_return, "pq_attest_v1:")) {
        // Format: pq_attest_v1:<love>:<food>:<rent>:<vacation>[:<btc>][:<eth>]
        // First-claim wins — if already registered, ignore.
        if (self.pq_identity_map.contains(tx.from_address)) return;

        const payload = tx.op_return["pq_attest_v1:".len..];
        var identity = PqIdentity{};

        // Parse colon-separated fields: love:food:rent:vacation[:btc][:eth]
        var it = std.mem.splitScalar(u8, payload, ':');
        var fi: usize = 0;
        while (it.next()) |field| : (fi += 1) {
            const copy_len_u = @min(field.len, 127);
            const copy_len: u8 = @intCast(copy_len_u);
            switch (fi) {
                0 => { @memcpy(identity.love[0..copy_len_u], field[0..copy_len_u]); identity.love_len = copy_len; },
                1 => { @memcpy(identity.food[0..copy_len_u], field[0..copy_len_u]); identity.food_len = copy_len; },
                2 => { @memcpy(identity.rent[0..copy_len_u], field[0..copy_len_u]); identity.rent_len = copy_len; },
                3 => { @memcpy(identity.vacation[0..copy_len_u], field[0..copy_len_u]); identity.vacation_len = copy_len; },
                4 => { const c = @min(field.len, 127); @memcpy(identity.btc[0..c], field[0..c]); identity.btc_len = @intCast(c); },
                5 => { const c = @min(field.len, 63); @memcpy(identity.eth[0..c], field[0..c]); identity.eth_len = @intCast(c); },
                else => break,
            }
        }

        // Require at least 4 soulbound fields
        if (identity.love_len == 0 or identity.food_len == 0 or
            identity.rent_len == 0 or identity.vacation_len == 0) return;

        // Validate soulbound prefixes
        if (!std.mem.startsWith(u8, identity.loveSlice(), "ob_k1_")) return;
        if (!std.mem.startsWith(u8, identity.foodSlice(), "ob_f5_")) return;
        if (!std.mem.startsWith(u8, identity.rentSlice(), "ob_d5_")) return;
        if (!std.mem.startsWith(u8, identity.vacationSlice(), "ob_s3_")) return;

        // Store attest block + tx hash
        identity.attest_block = @intCast(self.chain.items.len);
        const tx_hash_copy = @min(tx.hash.len, identity.attest_tx.len - 1);
        @memcpy(identity.attest_tx[0..tx_hash_copy], tx.hash[0..tx_hash_copy]);
        identity.attest_tx_len = @intCast(tx_hash_copy);

        // Store with owned key (first-claim wins)
        const owned_key = self.allocator.dupe(u8, tx.from_address) catch return;
        self.pq_identity_map.put(owned_key, identity) catch {
            self.allocator.free(owned_key);
            return;
        };
        // Persist to disk (JSONL append) so the registry survives restarts.
        // Best-effort: failure here doesn't break consensus, just means the
        // identity will need to be re-applied via chain replay on next start.
        persistPqIdentityAppend(self.allocator, tx.from_address, &identity);
    } else if (std.mem.startsWith(u8, tx.op_return, "label:")) {
        // op_return: "label:<target>:<tag>[:<note>]"
        // Fee check: minimum LABEL_FEE_SAT (0.1 OMNI) anti-spam
        if (tx.fee < label_mod.LABEL_FEE_SAT) return;
        const parsed = label_mod.parseApply(tx.op_return) orelse return;
        // reporter tier — look up reputation, fall back to OMNI default
        const reporter_tier = blk: {
            // Reputation module not directly accessible here; default "OMNI"
            // The tier weight will be overridden by RPC when submitting.
            break :blk "OMNI";
        };
        _ = self.label_registry.apply(
            parsed.target,
            tx.from_address,
            parsed.tag,
            parsed.note,
            reporter_tier,
            @intCast(self.chain.items.len),
            tx.hash,
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "label_remove:")) {
        // op_return: "label_remove:<id>"
        const label_id = label_mod.parseRemove(tx.op_return) orelse return;
        _ = self.label_registry.remove(label_id, tx.from_address);
    } else if (std.mem.startsWith(u8, tx.op_return, "sub_create:")) {
        // op_return: "sub_create:<to>:<amount>:<interval>:<max>[:<note>]"
        if (tx.fee < sub_mod.SUB_CREATE_FEE_SAT) return;
        const parsed = sub_mod.parseCreate(tx.op_return) orelse return;
        _ = self.sub_registry.create(
            tx.from_address,
            parsed,
            @intCast(self.chain.items.len),
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "sub_cancel:")) {
        // op_return: "sub_cancel:<id>"
        const sub_id = sub_mod.parseCancel(tx.op_return) orelse return;
        _ = self.sub_registry.cancel(sub_id, tx.from_address);
    } else if (std.mem.startsWith(u8, tx.op_return, "notarize:")) {
        // op_return: "notarize:<sha256>:<doc_type>:<expiry>[:<note>]"
        if (tx.fee < notarize_mod.NOTARIZE_FEE_SAT) return;
        const parsed = notarize_mod.parsNotarize(tx.op_return) orelse return;
        _ = self.notarize_registry.notarize(
            tx.from_address,
            parsed,
            @intCast(self.chain.items.len),
            tx.hash,
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "notarize_revoke:")) {
        // op_return: "notarize_revoke:<id>"
        if (tx.fee < notarize_mod.NOTARIZE_REVOKE_FEE_SAT) return;
        const notarize_id = notarize_mod.parseRevoke(tx.op_return) orelse return;
        _ = self.notarize_registry.revoke(notarize_id, tx.from_address);
    } else if (std.mem.startsWith(u8, tx.op_return, "escrow_create:")) {
        // op_return: "escrow_create:<to>:<amount>:<condition_hash>:<timeout>[:<note>]"
        if (tx.fee < escrow_mod.ESCROW_CREATE_FEE_SAT) return;
        const parsed = escrow_mod.parseCreate(tx.op_return) orelse return;
        // Fondurile sunt deja debitate din UTXO-ul senderului in applyBlock.
        // Inregistram escrow-ul — suma e tinuta virtual in registry.
        _ = self.escrow_registry.create(
            tx.from_address, parsed,
            @intCast(self.chain.items.len),
            tx.hash,
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "escrow_release:")) {
        // op_return: "escrow_release:<id>:<proof_hash>"
        const parsed = escrow_mod.parseRelease(tx.op_return) orelse return;
        const amount = self.escrow_registry.tryRelease(
            parsed.escrow_id, parsed.proof_hash,
            tx.from_address, @intCast(self.chain.items.len),
        );
        if (amount > 0) {
            // Crediteaza to_address (from_address este to-ul escrow-ului)
            const bal = self.balances.get(tx.from_address) orelse 0;
            self.balances.put(tx.from_address, bal + amount) catch {};
        }
    } else if (std.mem.startsWith(u8, tx.op_return, "escrow_refund:")) {
        // op_return: "escrow_refund:<id>"
        const escrow_id = escrow_mod.parseRefund(tx.op_return) orelse return;
        const amount = self.escrow_registry.tryRefund(
            escrow_id, tx.from_address,
            @intCast(self.chain.items.len),
        );
        if (amount > 0) {
            const bal = self.balances.get(tx.from_address) orelse 0;
            self.balances.put(tx.from_address, bal + amount) catch {};
        }
    } else if (std.mem.startsWith(u8, tx.op_return, "escrow_dispute:")) {
        if (tx.fee < escrow_mod.ESCROW_DISPUTE_FEE_SAT) return;
        const escrow_id = escrow_mod.parseDispute(tx.op_return) orelse return;
        _ = self.escrow_registry.openDispute(escrow_id, tx.from_address);

    // ── Social Graph ────────────────────────────────────────────────
    } else if (std.mem.startsWith(u8, tx.op_return, "follow:")) {
        const target = social_mod.parseFollow(tx.op_return) orelse return;
        self.social_graph.follow(
            tx.from_address, target, @intCast(self.chain.items.len),
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "unfollow:")) {
        const target = social_mod.parseUnfollow(tx.op_return) orelse return;
        self.social_graph.unfollow(tx.from_address, target);

    // ── POAP ────────────────────────────────────────────────────────
    } else if (std.mem.startsWith(u8, tx.op_return, "poap_event:")) {
        if (tx.fee < poap_mod.POAP_EVENT_FEE_SAT) return;
        const parsed = poap_mod.parseEvent(tx.op_return) orelse return;
        self.poap_registry.createEvent(
            tx.from_address, parsed, @intCast(self.chain.items.len),
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "poap_claim:")) {
        if (tx.fee < poap_mod.POAP_CLAIM_FEE_SAT) return;
        const event_id = poap_mod.parseClaim(tx.op_return) orelse return;
        self.poap_registry.claimPoap(
            tx.from_address, event_id, @intCast(self.chain.items.len), tx.hash,
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "poap_close:")) {
        const event_id = poap_mod.parseClose(tx.op_return) orelse return;
        _ = self.poap_registry.closeEvent(event_id, tx.from_address);

    // ── Governance ──────────────────────────────────────────────────
    } else if (std.mem.startsWith(u8, tx.op_return, "gov_propose:")) {
        if (tx.fee < gov_mod.GOV_PROPOSE_FEE_SAT) return;
        const parsed = gov_mod.parsePropose(tx.op_return) orelse return;
        _ = self.gov_registry.propose(
            tx.from_address, parsed, @intCast(self.chain.items.len),
        ) catch return;
    } else if (std.mem.startsWith(u8, tx.op_return, "gov_vote:")) {
        if (tx.fee < gov_mod.GOV_VOTE_FEE_SAT) return;
        const parsed = gov_mod.parseVote(tx.op_return) orelse return;
        self.gov_registry.vote(
            parsed.id, tx.from_address, parsed.yes, "OMNI",
            @intCast(self.chain.items.len),
        ) catch return;
    }
}
