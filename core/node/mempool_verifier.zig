// core/node/mempool_verifier.zig
// ──────────────────────────────────────────────────────────────────────────────
// Mempool signature gate — verifies a TX's signature before the mempool
// accepts it. Mirrors the dispatch in blockchain.validateTransaction:
//   ECDSA  → look up pubkey in bc.pubkey_registry (or use embedded pubkey
//             field if the sender hasn't registered yet — backward compat
//             with the same first-tx behavior the chain validator uses).
//   PQ     → pubkey is embedded in the TX itself (PQ keys aren't in the
//             registry; each PQ scheme carries its own pk).
// Returns false on any decode/lookup error so the mempool rejects the TX.
//
// Extracted from core/main.zig (2026-05-29).
// ──────────────────────────────────────────────────────────────────────────────

const std = @import("std");
const transaction_mod = @import("../transaction.zig");
const blockchain_mod  = @import("../blockchain.zig");
const multisig_mod    = @import("../multisig.zig");

const Blockchain = blockchain_mod.Blockchain;

pub fn mempoolVerifierFn(ctx_opt: ?*anyopaque, tx: *const transaction_mod.Transaction) bool {
    const ctx = ctx_opt orelse return false;
    const bc: *Blockchain = @ptrCast(@alignCast(ctx));

    // Coinbase / system TXs have empty signatures — let them through; the
    // chain validator owns the coinbase-specific checks.
    if (tx.signature.len == 0) return true;

    // Multisig uses M-of-N verification at submission time (rpc layer).
    // The mempool can't re-verify without quorum data, so skip and let
    // applyBlock catch any invariant violations.
    if (std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX)) {
        return true;
    }

    return switch (tx.scheme) {
        .omni_ecdsa => blk: {
            // Prefer embedded pubkey (first TX from a fresh address); fall
            // back to the registry for established senders.
            if (tx.public_key.len == 66) {
                break :blk tx.verifySignature(tx.public_key);
            }
            if (bc.pubkey_registry.get(tx.from_address)) |pk_hex| {
                break :blk tx.verifySignature(pk_hex);
            }
            // Unknown sender, no embedded pk — same backward-compat policy
            // as validateTransaction: accept (registry will be populated
            // after this TX confirms). Mempool rejection is reserved for
            // *bad* signatures, not missing ones.
            break :blk true;
        },
        .love_dilithium, .food_falcon, .rent_ml_dsa, .vacation_slh_dsa
            => tx.verifySignature(null),
        .pq_omni_ml_dsa, .pq_omni_falcon, .pq_omni_dilithium, .pq_omni_slh_dsa,
        .hybrid_q1, .hybrid_q2, .hybrid_q3, .hybrid_q4 => tx.verifySignature(null),
    };
}
