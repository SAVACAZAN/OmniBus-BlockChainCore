/// e2e_mining.zig — Test end-to-end: mining, balante, tranzactii, chain integrity
///
/// Simuleaza un ciclu complet de viata al blockchain-ului:
///   1. Init blockchain cu genesis
///   2. Mineaza blocuri reale (PoW difficulty=4)
///   3. Verifica reward-uri miner
///   4. Adauga tranzactii in mempool
///   5. Mineaza bloc cu tranzactii
///   6. Verifica balante sender/receiver
///   7. Verifica integritatea lantului (previous_hash chaining)

const std   = @import("std");
const bc_mod = @import("blockchain.zig");

const Blockchain = bc_mod.Blockchain;
const Transaction = bc_mod.Transaction;

const MINER_ADDR = "ob_omni_miner00000001";
const ALICE_ADDR = "ob_omni_alice0000001";
const BOB_ADDR   = "ob_omni_bob00000001";

const testing = std.testing;

// ── Helper: mineaza un bloc si elibereaza hash-ul (hash ramane in chain) ──────
fn mineOne(bc: *Blockchain, miner: []const u8) !void {
    _ = try bc.mineBlockForMiner(miner);
}

// ─── Test 1: genesis block exista si e valid ──────────────────────────────────
test "E2E — genesis block la init" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try testing.expectEqual(@as(u32, 1), bc.getBlockCount());
    const genesis = bc.getBlock(0).?;
    try testing.expectEqual(@as(u32, 0), genesis.index);
    try testing.expect(genesis.hash.len > 0);
}

// ─── Test 2: mineaza 1 bloc, chain creste ────────────────────────────────────
test "E2E — mining 1 bloc creste chain-ul la 2" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, MINER_ADDR);
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());
}

// ─── Test 3: miner primeste reward ───────────────────────────────────────────
test "E2E — miner primeste BLOCK_REWARD_SAT dupa mining" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const bal_before = bc.getAddressBalance(MINER_ADDR);
    try mineOne(&bc, MINER_ADDR);
    const bal_after = bc.getAddressBalance(MINER_ADDR);

    try testing.expectEqual(bc_mod.BLOCK_REWARD_SAT, bal_after - bal_before);
}

// ─── Test 4: mineaza 3 blocuri, reward acumulat ───────────────────────────────
test "E2E — 3 blocuri minate, reward acumulat corect" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, MINER_ADDR);
    try mineOne(&bc, MINER_ADDR);
    try mineOne(&bc, MINER_ADDR);

    try testing.expectEqual(@as(u32, 4), bc.getBlockCount());
    try testing.expectEqual(bc_mod.BLOCK_REWARD_SAT * 3,
        bc.getAddressBalance(MINER_ADDR));
}

// ─── Test 5: hash bloc minat are 4 zerouri leading (difficulty=4) ────────────
test "E2E — hash bloc minat respecta difficulty" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, MINER_ADDR);
    const blk = bc.getLatestBlock();

    // hash trebuie sa inceapa cu cel putin 4 zerouri
    try testing.expect(blk.hash.len >= 4);
    for (blk.hash[0..4]) |ch| {
        try testing.expectEqual(@as(u8, '0'), ch);
    }
}

// ─── Test 6: previous_hash chaining intre blocuri ────────────────────────────
test "E2E — previous_hash leaga blocurile in lant" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, MINER_ADDR);
    try mineOne(&bc, MINER_ADDR);

    const b0 = bc.getBlock(0).?;
    const b1 = bc.getBlock(1).?;
    const b2 = bc.getBlock(2).?;

    try testing.expectEqualStrings(b0.hash, b1.previous_hash);
    try testing.expectEqualStrings(b1.hash, b2.previous_hash);
}

// ─── Test 7: index blocuri creste secvential ─────────────────────────────────
test "E2E — index blocuri creste 0,1,2,..." {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, MINER_ADDR);
    try mineOne(&bc, MINER_ADDR);

    try testing.expectEqual(@as(u32, 0), bc.getBlock(0).?.index);
    try testing.expectEqual(@as(u32, 1), bc.getBlock(1).?.index);
    try testing.expectEqual(@as(u32, 2), bc.getBlock(2).?.index);
}

// ─── Test 8: tranzactie in mempool → minata → balante actualizate ────────────
test "E2E — tranzactie mineata: sender scade, receiver creste" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Fonduri pentru alice: 2 blocuri minate de ea
    try mineOne(&bc, ALICE_ADDR);
    try mineOne(&bc, ALICE_ADDR);
    const alice_funded = bc.getAddressBalance(ALICE_ADDR);
    try testing.expect(alice_funded >= 1_000_000);

    const transfer_amount: u64 = 1_000_000; // 0.001 OMNI
    const tx_fee: u64 = bc_mod.TX_MIN_FEE; // 1 SAT minimum fee

    // Creeaza TX manual (fara semnatura ECDSA — validatorul accepta TX fara sig)
    const tx = Transaction{
        .id            = 1,
        .from_address  = ALICE_ADDR,
        .to_address    = BOB_ADDR,
        .amount        = transfer_amount,
        .fee           = tx_fee,
        .timestamp     = std.time.timestamp(),
        .signature     = "",  // fara semnatura => validatorul o accepta (len == 0)
        .hash          = "",
    };

    try bc.addTransaction(tx);
    try testing.expectEqual(@as(usize, 1), bc.mempool.items.len);

    // Mineaza blocul cu TX (miner-ul e altul)
    try mineOne(&bc, MINER_ADDR);

    // Mempool golit dupa mining
    try testing.expectEqual(@as(usize, 0), bc.mempool.items.len);

    // Balanta bob crescuta
    try testing.expectEqual(transfer_amount, bc.getAddressBalance(BOB_ADDR));

    // Balanta alice scazuta (amount + fee debited)
    const alice_after = bc.getAddressBalance(ALICE_ADDR);
    try testing.expectEqual(alice_funded - transfer_amount - tx_fee, alice_after);
}

// ─── Test 9: doua tranzactii in acelasi bloc ─────────────────────────────────
test "E2E — doua tranzactii in acelasi bloc" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Fonduri miner → alice si bob
    try mineOne(&bc, ALICE_ADDR);
    try mineOne(&bc, BOB_ADDR);

    const tx1 = Transaction{
        .id = 1, .from_address = ALICE_ADDR, .to_address = MINER_ADDR,
        .amount = 100_000, .fee = bc_mod.TX_MIN_FEE, .timestamp = 0, .signature = "", .hash = "",
    };
    const tx2 = Transaction{
        .id = 2, .from_address = BOB_ADDR, .to_address = MINER_ADDR,
        .amount = 200_000, .fee = bc_mod.TX_MIN_FEE, .timestamp = 0, .signature = "", .hash = "",
    };
    try bc.addTransaction(tx1);
    try bc.addTransaction(tx2);
    try testing.expectEqual(@as(usize, 2), bc.mempool.items.len);

    try mineOne(&bc, MINER_ADDR);

    try testing.expectEqual(@as(usize, 0), bc.mempool.items.len);
    // miner primeste reward + 100k + 200k + 50% of fees (2 TX × 1 SAT, 50% burned)
    const total_fees = 2 * bc_mod.TX_MIN_FEE;
    const fees_to_miner = total_fees - (total_fees * bc_mod.FEE_BURN_PCT / 100);
    const expected = bc_mod.BLOCK_REWARD_SAT + 100_000 + 200_000 + fees_to_miner;
    try testing.expectEqual(expected, bc.getAddressBalance(MINER_ADDR));
}

// ─── Test 10: getLatestBlock returneaza ultimul bloc ─────────────────────────
test "E2E — getLatestBlock dupa 2 mine = index 2" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, MINER_ADDR);
    try mineOne(&bc, MINER_ADDR);

    const latest = bc.getLatestBlock();
    try testing.expectEqual(@as(u32, 2), latest.index);
}

// ─── Test 11: miner diferit per bloc ─────────────────────────────────────────
test "E2E — doi mineri diferiti, fiecare primeste reward separat" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try mineOne(&bc, ALICE_ADDR);
    try mineOne(&bc, BOB_ADDR);

    try testing.expectEqual(bc_mod.BLOCK_REWARD_SAT, bc.getAddressBalance(ALICE_ADDR));
    try testing.expectEqual(bc_mod.BLOCK_REWARD_SAT, bc.getAddressBalance(BOB_ADDR));
}
