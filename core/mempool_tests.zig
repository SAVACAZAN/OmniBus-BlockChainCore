// Mempool unit tests — extracted from core/mempool.zig.
//
// Lives next to mempool.zig (in core/) so test-local @imports of sibling
// modules resolve via a normal relative path. Zig 0.15.2 forbids
// `@import("../...")` from a test root file, which is why a `test/`
// location wouldn't work — see core/blockchain_tests.zig for the same
// pattern.
//
// Run via `zig test core/mempool_tests.zig` (with the same -Doqs flag the
// chain uses) or via the build.zig `test-chain` step which wires it in as
// the `mempool-tests` step.

const std = @import("std");
const mempool_mod     = @import("mempool.zig");
const transaction_mod = @import("transaction.zig");

const Mempool             = mempool_mod.Mempool;
const MempoolError        = mempool_mod.MempoolError;
const TX_MIN_FEE_SAT      = mempool_mod.TX_MIN_FEE_SAT;
const MEMPOOL_EXPIRY_SEC  = mempool_mod.MEMPOOL_EXPIRY_SEC;
const Transaction         = transaction_mod.Transaction;

const testing = std.testing;

// ─── Test helpers (file-private to the test module) ──────────────────────────

fn makeTx(id: u32, from: []const u8, to: []const u8, amount: u64) Transaction {
    return makeTxWithFee(id, from, to, amount, TX_MIN_FEE_SAT);
}

fn makeTxWithFee(id: u32, from: []const u8, to: []const u8, amount: u64, fee: u64) Transaction {
    return Transaction{
        .id           = id,
        .from_address = from,
        .to_address   = to,
        .amount       = amount,
        .fee          = fee,
        .nonce        = id, // unique nonce per TX (prevents RBF conflict in tests)
        .timestamp    = 1_743_000_000,
        .signature    = "",
        .hash         = "",
    };
}

test "Mempool — add si size" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    const tx = makeTx(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 1_000_000);
    try mp.add(tx);
    try testing.expectEqual(@as(usize, 1), mp.size());
}

test "Mempool — FIFO: ordinea e pastrata" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTx(10, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100));
    try mp.add(makeTx(20, "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", "ob1q82wjr7r83zpamjy9keykx9a9xhfjtde44juc34", 200));
    try mp.add(makeTx(30, "ob1qgzkmy8xzlg6j66pr8ne79am8s90hs6mf79t3pr", "ob1q5pj4vl30hvu30a9re3xv0zn9q3p24twgqg5fu4", 300));

    const popped = try mp.popN(2, testing.allocator);
    defer testing.allocator.free(popped);

    try testing.expectEqual(@as(u32, 10), popped[0].id);
    try testing.expectEqual(@as(u32, 20), popped[1].id);
    try testing.expectEqual(@as(usize, 1), mp.size()); // mai ramas 1
}

test "Mempool — TX invalida respinsa" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // Adresa fara prefix valid
    const bad_tx = makeTx(1, "invalid_addr", "also_invalid", 1000);
    const result = mp.add(bad_tx);
    try testing.expectError(MempoolError.TxInvalid, result);
    try testing.expectEqual(@as(usize, 0), mp.size());
}

test "Mempool — amount zero respins (isValid rejecta amount=0)" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    const tx = makeTx(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 0);
    const result = mp.add(tx);
    try testing.expectError(MempoolError.TxInvalid, result);
}

test "Mempool — maintenance (expiry + memory)" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTx(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 1000));
    mp.maintenance(); // should not crash, no expired TX yet
    try testing.expectEqual(@as(usize, 1), mp.size());
}

test "Mempool — estimateMemoryUsage" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try testing.expectEqual(@as(usize, 0), mp.estimateMemoryUsage());
    try mp.add(makeTx(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 1000));
    try testing.expect(mp.estimateMemoryUsage() > 0);
}

test "Mempool — MEMPOOL_EXPIRY_SEC is 14 days" {
    try testing.expectEqual(@as(i64, 14 * 24 * 3600), MEMPOOL_EXPIRY_SEC);
    try testing.expectEqual(@as(i64, 1_209_600), MEMPOOL_EXPIRY_SEC);
}

test "Mempool — isEmpty si printStats" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try testing.expect(mp.isEmpty());
    try mp.add(makeTx(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 500));
    try testing.expect(!mp.isEmpty());
    mp.printStats();
}

test "Mempool — popN mai mult decat exista" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTx(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100));

    const popped = try mp.popN(100, testing.allocator); // cere 100, are 1
    defer testing.allocator.free(popped);

    try testing.expectEqual(@as(usize, 1), popped.len);
    try testing.expectEqual(@as(usize, 0), mp.size());
}

test "Mempool — fee too low rejected" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // TX with fee=0 should be rejected
    const tx = makeTxWithFee(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 1000, 0);
    const result = mp.add(tx);
    try testing.expectError(MempoolError.FeeTooLow, result);
    try testing.expectEqual(@as(usize, 0), mp.size());
}

test "Mempool — getByFee returns sorted by fee descending" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTxWithFee(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100, 1));   // low fee
    try mp.add(makeTxWithFee(2, "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", "ob1q82wjr7r83zpamjy9keykx9a9xhfjtde44juc34", 200, 100)); // high fee
    try mp.add(makeTxWithFee(3, "ob1qgzkmy8xzlg6j66pr8ne79am8s90hs6mf79t3pr", "ob1q5pj4vl30hvu30a9re3xv0zn9q3p24twgqg5fu4", 300, 50));  // mid fee

    const sorted = try mp.getByFee(3, testing.allocator);
    defer testing.allocator.free(sorted);

    try testing.expectEqual(@as(usize, 3), sorted.len);
    try testing.expectEqual(@as(u64, 100), sorted[0].fee_sat); // highest
    try testing.expectEqual(@as(u64, 50), sorted[1].fee_sat);  // middle
    try testing.expectEqual(@as(u64, 1), sorted[2].fee_sat);   // lowest
}

test "Mempool — medianFee empty mempool returns min fee" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try testing.expectEqual(TX_MIN_FEE_SAT, mp.medianFee());
}

test "Mempool — medianFee with entries" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTxWithFee(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100, 10));
    try mp.add(makeTxWithFee(2, "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", "ob1q82wjr7r83zpamjy9keykx9a9xhfjtde44juc34", 200, 50));
    try mp.add(makeTxWithFee(3, "ob1qgzkmy8xzlg6j66pr8ne79am8s90hs6mf79t3pr", "ob1q5pj4vl30hvu30a9re3xv0zn9q3p24twgqg5fu4", 300, 100));

    // Sorted fees: [10, 50, 100] — median at index 1 = 50
    try testing.expectEqual(@as(u64, 50), mp.medianFee());
}

// ─── Nonce tracking tests ────────────────────────────────────────────────────

test "Mempool — getPendingCount tracks pending TXs per sender" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // No pending TXs
    try testing.expectEqual(@as(u64, 0), mp.getPendingCount("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Add 2 TXs from alice, 1 from bob
    try mp.add(makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100));
    try mp.add(makeTx(2, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", 200));
    try mp.add(makeTx(3, "ob1q30hwjz0vlj7uw939knp8629ygxl2aspttdv7xy", "ob1q82wjr7r83zpamjy9keykx9a9xhfjtde44juc34", 300));

    try testing.expectEqual(@as(u64, 2), mp.getPendingCount("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
    try testing.expectEqual(@as(u64, 1), mp.getPendingCount("ob1q30hwjz0vlj7uw939knp8629ygxl2aspttdv7xy"));
    try testing.expectEqual(@as(u64, 0), mp.getPendingCount("ob1qxx053xkaxkrykutxfg2znskcwdckg7mj7swr7j"));
}

test "Mempool — removeConfirmed decrements pending count" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    const tx1 = makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100);
    const tx2 = makeTx(2, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", 200);
    try mp.add(tx1);
    try mp.add(tx2);
    try testing.expectEqual(@as(u64, 2), mp.getPendingCount("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Confirm tx1
    const confirmed = [_]Transaction{tx1};
    mp.removeConfirmed(&confirmed);
    try testing.expectEqual(@as(u64, 1), mp.getPendingCount("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
    try testing.expectEqual(@as(usize, 1), mp.size());
}

test "Mempool — replaceByNonce replaces TX with same sender+nonce" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // Add TX with nonce 5
    var tx1 = makeTxWithFee(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100, 10);
    tx1.nonce = 5;
    try mp.add(tx1);
    try testing.expectEqual(@as(usize, 1), mp.size());
    try testing.expectEqual(@as(u64, 1), mp.getPendingCount("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Replace with higher fee TX at same nonce
    var tx2 = makeTxWithFee(2, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", 200, 50);
    tx2.nonce = 5;
    const replaced = mp.replaceByNonce(tx2);
    try testing.expect(replaced);
    try testing.expectEqual(@as(usize, 1), mp.size()); // still 1 TX
    try testing.expectEqual(@as(u64, 1), mp.getPendingCount("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh")); // still 1 pending

    // The TX in mempool should now be tx2
    try testing.expectEqual(@as(u32, 2), mp.entries.items[0].tx.id);
    try testing.expectEqual(@as(u64, 50), mp.entries.items[0].fee_sat);
}

test "Mempool — replaceByNonce returns false if no match" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    var tx1 = makeTx(1, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100);
    tx1.nonce = 5;
    try mp.add(tx1);

    // Try to replace nonce 6 (doesn't exist)
    var tx2 = makeTx(2, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", 200);
    tx2.nonce = 6;
    const replaced = mp.replaceByNonce(tx2);
    try testing.expect(!replaced);
    try testing.expectEqual(@as(usize, 1), mp.size()); // unchanged
}

// ─── Timelock + OP_RETURN Mempool Tests (B4) ────────────────────────────────

fn makeTxWithLocktime(id: u32, from: []const u8, to: []const u8, amount: u64, locktime: u64) Transaction {
    return Transaction{
        .id           = id,
        .from_address = from,
        .to_address   = to,
        .amount       = amount,
        .fee          = TX_MIN_FEE_SAT,
        .nonce        = id + 1000, // unique nonce
        .timestamp    = 1_743_000_000,
        .locktime     = locktime,
        .signature    = "",
        .hash         = "",
    };
}

test "Mempool — add accepts locked TX (waits in mempool)" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // TX locked until block 1000 — still added to mempool
    const tx = makeTxWithLocktime(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 1000, 1000);
    try mp.add(tx);
    try testing.expectEqual(@as(usize, 1), mp.size());
}

test "Mempool — getMineable skips locked TXs" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // TX1: immediate (locktime=0)
    try mp.add(makeTxWithLocktime(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100, 0));
    // TX2: locked until block 1000
    try mp.add(makeTxWithLocktime(2, "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", "ob1q82wjr7r83zpamjy9keykx9a9xhfjtde44juc34", 200, 1000));
    // TX3: locked until block 5 (already reached)
    try mp.add(makeTxWithLocktime(3, "ob1qgzkmy8xzlg6j66pr8ne79am8s90hs6mf79t3pr", "ob1q5pj4vl30hvu30a9re3xv0zn9q3p24twgqg5fu4", 300, 5));

    // Current height = 10 → TX1 (locktime=0) and TX3 (locktime=5<=10) are mineable
    const mineable = try mp.getMineable(100, 10, testing.allocator);
    defer testing.allocator.free(mineable);

    try testing.expectEqual(@as(usize, 2), mineable.len);
    try testing.expectEqual(@as(u32, 1), mineable[0].id); // TX1
    try testing.expectEqual(@as(u32, 3), mineable[1].id); // TX3

    // TX2 (locked) should still be in mempool
    try testing.expectEqual(@as(usize, 1), mp.size());
    try testing.expectEqual(@as(u32, 2), mp.entries.items[0].tx.id);
}

test "Mempool — getMineable all locked returns empty" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTxWithLocktime(1, "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q", "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6", 100, 500));
    try mp.add(makeTxWithLocktime(2, "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7", "ob1q82wjr7r83zpamjy9keykx9a9xhfjtde44juc34", 200, 1000));

    // Current height = 3 → both locked
    const mineable = try mp.getMineable(100, 3, testing.allocator);
    defer testing.allocator.free(mineable);

    try testing.expectEqual(@as(usize, 0), mineable.len);
    try testing.expectEqual(@as(usize, 2), mp.size()); // both still in mempool
}

test "Mempool — OP_RETURN TX with amount=0 accepted" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // OP_RETURN data TX: amount=0 but op_return is set — isValid() should allow it
    const tx = Transaction{
        .id           = 1,
        .from_address = "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q",
        .to_address   = "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6",
        .amount       = 0,
        .fee          = TX_MIN_FEE_SAT,
        .timestamp    = 1_743_000_000,
        .op_return    = "hello world",
        .signature    = "",
        .hash         = "",
    };
    try mp.add(tx);
    try testing.expectEqual(@as(usize, 1), mp.size());
}

// ─── HIGH-05 — RBF replacement signature verification ─────────────────────────
//
// Regression test for the audit finding: if `mempool.add()` does not run sig
// verification on the replacement TX, an attacker can replace a victim's
// pending (from, nonce) slot with a higher-fee TX that redirects funds.

const SigGate = struct {
    const reject_marker: []const u8 = "BAD"; // signatures starting with this fail
    fn verify(_: ?*anyopaque, tx: *const Transaction) bool {
        // A real verifier would call tx.verifySignature(...). For the test we
        // use a stub: any TX whose `signature` field starts with "BAD" is
        // rejected. This isolates the mempool gate logic from secp256k1 setup.
        if (tx.signature.len >= reject_marker.len and
            std.mem.eql(u8, tx.signature[0..reject_marker.len], reject_marker))
        {
            return false;
        }
        return true;
    }
};

test "Mempool — RBF replacement with bad signature rejected (HIGH-05)" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    mp.verifier = SigGate.verify;

    const victim_from = "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q";
    const victim_to   = "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6";
    const attacker    = "ob1qdactu4tmgr24gxzakg0zkd0hwhd9cuc6g8tcx7";

    // Original TX — RBF-enabled, sig "OK..."
    const orig = Transaction{
        .id           = 1,
        .from_address = victim_from,
        .to_address   = victim_to,
        .amount       = 1_000_000,
        .fee          = 100,
        .nonce        = 7,
        .timestamp    = 1_743_000_000,
        .sequence     = 0xFFFFFFFD, // RBF opt-in
        .signature    = "OK_valid_sig_placeholder",
        .hash         = "",
    };
    try mp.add(orig);
    try testing.expectEqual(@as(usize, 1), mp.size());

    // Attacker's malicious replacement — same (from, nonce), higher fee,
    // CORRUPTED sig (would normally redirect funds to attacker).
    const attack = Transaction{
        .id           = 2,
        .from_address = victim_from,
        .to_address   = attacker,        // funds would be redirected
        .amount       = 1_000_000,
        .fee          = 1_000,            // higher fee → would pass canBeReplacedBy
        .nonce        = 7,                // same slot
        .timestamp    = 1_743_000_001,
        .sequence     = 0xFFFFFFFD,
        .signature    = "BAD_forged_signature",
        .hash         = "",
    };
    const r1 = mp.add(attack);
    try testing.expectError(MempoolError.BadSignature, r1);
    // Original must still be in the mempool, unchanged
    try testing.expectEqual(@as(usize, 1), mp.size());
    try testing.expectEqualStrings(victim_to, mp.entries.items[0].tx.to_address);

    // Legitimate replacement (valid sig + higher fee) must still succeed.
    const legit = Transaction{
        .id           = 3,
        .from_address = victim_from,
        .to_address   = victim_to,
        .amount       = 1_000_000,
        .fee          = 500,
        .nonce        = 7,
        .timestamp    = 1_743_000_002,
        .sequence     = 0xFFFFFFFD,
        .signature    = "OK_legit_replacement",
        .hash         = "",
    };
    try mp.add(legit);
    try testing.expectEqual(@as(usize, 1), mp.size());
    try testing.expectEqual(@as(u64, 500), mp.entries.items[0].fee_sat);
}

test "Mempool — initial submit with bad signature rejected (HIGH-05)" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();
    mp.verifier = SigGate.verify;

    const tx = Transaction{
        .id           = 1,
        .from_address = "ob1qwp7k56wu8x22axd7dvw5wqtzlc29grf8uf760q",
        .to_address   = "ob1qfn5y32ywn22hsl4vj82v6va9uczd6dvlfeu9a6",
        .amount       = 1_000_000,
        .fee          = 100,
        .nonce        = 0,
        .timestamp    = 1_743_000_000,
        .signature    = "BAD_forged",
        .hash         = "",
    };
    try testing.expectError(MempoolError.BadSignature, mp.add(tx));
    try testing.expectEqual(@as(usize, 0), mp.size());
}
