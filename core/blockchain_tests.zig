// Blockchain unit tests — extracted from core/blockchain.zig.
//
// Lives next to blockchain.zig (in core/) so the test's nested
// @imports of sibling modules (chain_config.zig, ripemd160.zig,
// secp256k1.zig, etc. used inline by individual tests) resolve via
// a normal relative path. Zig 0.15.2 forbids `@import("../...")`
// from a test root file, which is why a `test/` location wouldn't work.
//
// Run via `zig test core/blockchain_tests.zig` (with the same -Doqs flag
// the chain uses) or via the build.zig `test-chain` step which wires it
// in as the `blockchain-tests` step.

const std = @import("std");
const blockchain_mod   = @import("blockchain.zig");
const block_mod        = @import("block.zig");
const transaction_mod  = @import("transaction.zig");
const consensus_params_mod = @import("blockchain/consensus_params.zig");
const script_mod       = @import("script.zig");
const htlc_mod         = @import("htlc.zig");
const gov_mod          = @import("governance_onchain.zig");
const registrar_mod    = @import("registrar_addresses.zig");
const tx_payload_mod   = @import("tx_payload.zig");

const Blockchain    = blockchain_mod.Blockchain;
const Block         = block_mod.Block;
const Transaction   = transaction_mod.Transaction;
const Outpoint      = transaction_mod.Outpoint;
const TxOutput      = transaction_mod.TxOutput;

// Re-exported consensus constants/helpers (kept as bare identifiers in the
// original tests, hence the local aliases here).
const BLOCK_REWARD_SAT   = blockchain_mod.BLOCK_REWARD_SAT;
const HALVING_INTERVAL   = blockchain_mod.HALVING_INTERVAL;
const MAX_DIFFICULTY     = blockchain_mod.MAX_DIFFICULTY;
const MIN_DIFFICULTY     = blockchain_mod.MIN_DIFFICULTY;
const MAX_REORG_DEPTH    = blockchain_mod.MAX_REORG_DEPTH;
const TARGET_INTERVAL_S  = blockchain_mod.TARGET_INTERVAL_S;
const FEE_BURN_PCT       = blockchain_mod.FEE_BURN_PCT;
const blockRewardAt      = blockchain_mod.blockRewardAt;
const retargetDifficulty = blockchain_mod.retargetDifficulty;

const array_list = std.array_list;

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "blockRewardAt — bloc 0 = reward initial" {
    try testing.expectEqual(BLOCK_REWARD_SAT, blockRewardAt(0));
}

test "blockRewardAt — halving la HALVING_INTERVAL" {
    const r0 = blockRewardAt(0);
    const r1 = blockRewardAt(HALVING_INTERVAL);
    try testing.expectEqual(r0 / 2, r1);
}

test "blockRewardAt — dupa 64 halvings = 0" {
    try testing.expectEqual(@as(u64, 0), blockRewardAt(HALVING_INTERVAL * 64));
}

test "Blockchain.init — geneza + 1 bloc in chain" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount());
}

test "Blockchain.init — difficulty = 4" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 4), bc.difficulty);
}

test "Blockchain.getBlock — bloc genesis la index 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0);
    try testing.expect(genesis != null);
    try testing.expectEqual(@as(u32, 0), genesis.?.index);
}

test "Blockchain.getBlock — index inexistent returneaza null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getBlock(999) == null);
}

test "Blockchain.getLatestBlock — initial = genesis" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    var latest = try bc.getLatestBlock(testing.allocator);
    defer Blockchain.freeClonedBlock(testing.allocator, &latest);
    try testing.expectEqual(@as(u32, 0), latest.index);
}

test "Blockchain.creditBalance — adauga sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 1_000_000_000);
    // PHASE-B: getAddressBalance citeste din UTXO, nu din RAM cache.
    // creditBalance scrie doar in cache; verificam cache-ul direct.
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.balances.get("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh").?);
}

test "Blockchain.creditBalance — acumuleaza multiple credite" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 500_000_000);
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.balances.get("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh").?);
}

test "Blockchain.debitBalance — scade sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 2_000_000_000);
    try bc.debitBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 500_000_000);
    try testing.expectEqual(@as(u64, 1_500_000_000), bc.balances.get("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas").?);
}

test "Blockchain.debitBalance — sold insuficient => error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 100);
    try testing.expectError(error.InsufficientBalance, bc.debitBalance("ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 200));
}

test "Blockchain.getAddressBalance — adresa necunoscuta returneaza 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getAddressBalance("ob1qqlkv63jlf7n2vh97tc4zj3h8tvplz0e5dj7mvq"));
}

test "Blockchain.validateTransaction — amount 0 invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 0, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — adresa goala invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — prefix invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "invalid_prefix_addr", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — nonce replay attack blocked" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Give sender some balance via UTXO (PHASE-B: validateTransaction reads from UTXO)
    try bc.utxo_set.addUTXO("funding_tx_01", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 10_000, 1, "", false);

    // First TX with nonce 0 should be valid (fee >= TX_MIN_FEE)
    const tx1 = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx1));

    // Simulate nonce increment after processing
    try bc.nonces.put("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 1);

    // Replay same TX with nonce 0 should be rejected (nonce too low)
    try testing.expect(!try bc.validateTransaction(&tx1));

    // TX with nonce 1 should be valid
    const tx2 = Transaction{
        .id = 2, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000001, .nonce = 1, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx2));
}

test "Blockchain.validateTransaction — insufficient balance rejected (amount + fee)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has 0 balance
    const tx = Transaction{
        .id = 1, .from_address = "ob1qu6d376ysuserqh6rjeh8q0t39j7qp9fcl87hk6", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 1_000_000, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — fee too low rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_02", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 10_000, 1, "", false);
    const tx = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 0, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — balance must cover amount + fee" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has exactly 100 SAT via UTXO, TX needs 100 amount + 1 fee = 101
    try bc.utxo_set.addUTXO("funding_tx_03", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 100, 1, "", false);
    const tx = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.getNextNonce — unknown address returns 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getNextNonce("ob1qf67we03tka2etd5u8lsa3uf5aq9605hu99yxc2"));
}

test "Blockchain.validateTransaction — nonce gap rejected (strict ordering)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_04", 0, "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 100_000, 1, "", false);

    // Expected nonce is 0, but TX has nonce 5 — gap should be rejected
    const tx_gap = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 5, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx_gap));

    // nonce 0 should be accepted
    const tx_ok = Transaction{
        .id = 2, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000001, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx_ok));
}

test "Blockchain.getNextAvailableNonce — includes pending mempool TXs" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Chain nonce is 0
    try testing.expectEqual(@as(u64, 0), bc.getNextAvailableNonce("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Add a TX to the internal mempool (simulating addTransaction bypassing validation)
    try bc.mempool.append(Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    });

    // Now next available nonce should be 1 (chain_nonce=0 + 1 pending)
    try testing.expectEqual(@as(u64, 1), bc.getNextAvailableNonce("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Bob has no pending TXs
    try testing.expectEqual(@as(u64, 0), bc.getNextAvailableNonce("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas"));
}

test "Blockchain.isValidHash — 4 zerouri leading = valid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(try bc.isValidHash("0000abcdef123456789012345678901234567890123456789012345678901234"));
}

test "Blockchain.isValidHash — 3 zerouri leading = invalid (difficulty=4)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(!try bc.isValidHash("000abcdef1234567890123456789012345678901234567890123456789012345"));
}

test "Blockchain.calculateBlockHash — produce 64 chars hex" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    const hash = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(hash);
    try testing.expectEqual(@as(usize, 64), hash.len);
}

test "retargetDifficulty — prea rapid → creste dificultatea" {
    // actual_time = 504s = target/4 → clamp → new = old * 2016 / 504 = old*4
    const new_d = retargetDifficulty(4, 504);
    try testing.expectEqual(@as(u32, 16), new_d);
}

test "retargetDifficulty — prea lent → scade dificultatea" {
    // actual_time = 8064s = target*4 → clamp → new = old * 2016 / 8064 = old/4
    const new_d = retargetDifficulty(8, 8064);
    try testing.expectEqual(@as(u32, 2), new_d);
}

test "retargetDifficulty — exact target → dificultate neschimbata" {
    const new_d = retargetDifficulty(6, TARGET_INTERVAL_S);
    try testing.expectEqual(@as(u32, 6), new_d);
}

test "retargetDifficulty — clamp la MAX_DIFFICULTY" {
    // actual_time extrem de mic → ar da overflow → limitat la MAX
    const new_d = retargetDifficulty(MAX_DIFFICULTY, 1);
    try testing.expectEqual(MAX_DIFFICULTY, new_d);
}

test "retargetDifficulty — clamp la MIN_DIFFICULTY" {
    // actual_time maxim posibil, dificultate mica → nu scade sub 1
    const new_d = retargetDifficulty(1, TARGET_INTERVAL_S * 100);
    try testing.expectEqual(MIN_DIFFICULTY, new_d);
}

test "retargetDifficulty — actual_time zero → returneaza old" {
    const new_d = retargetDifficulty(5, 0);
    try testing.expectEqual(@as(u32, 5), new_d);
}

test "Blockchain.calculateBlockHash — determinist" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    const h1 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h1);
    const h2 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h2);
    try testing.expectEqualSlices(u8, h1, h2);
}

test "Blockchain.validateTransaction — rejects TX when pending outgoing exceeds balance" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Credit Alice 1000 SAT via UTXO
    try bc.utxo_set.addUTXO("funding_tx_pending", 0, "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll", 1000, 1, "", false);

    // TX1: Alice sends 400 SAT (fee=1), nonce=0 — should succeed
    const tx1 = Transaction{
        .id = 1,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 400,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "",
    };
    try bc.addTransaction(tx1);

    // Verify pending outgoing is 401 (400 amount + 1 fee)
    try testing.expectEqual(@as(u64, 401), bc.getPendingOutgoing("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll"));

    // TX2: Alice sends 700 SAT (fee=1), nonce=1 — should FAIL
    // Available = 1000 - 401 = 599, but TX2 needs 701 (700+1)
    const tx2 = Transaction{
        .id = 2,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 700,
        .fee = 1,
        .timestamp = 1700000001,
        .nonce = 1,
        .signature = "",
        .hash = "",
    };
    try testing.expectError(error.InvalidTransaction, bc.addTransaction(tx2));

    // TX3: Alice sends 500 SAT (fee=1), nonce=1 — should SUCCEED
    // Available = 1000 - 401 = 599, TX3 needs 501 (500+1) — fits
    const tx3 = Transaction{
        .id = 3,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 500,
        .fee = 1,
        .timestamp = 1700000002,
        .nonce = 1,
        .signature = "",
        .hash = "",
    };
    try bc.addTransaction(tx3);

    // After TX1 (401) + TX3 (501) pending = 902, available = 98
    try testing.expectEqual(@as(u64, 902), bc.getPendingOutgoing("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll"));
}

test "Blockchain.getConfirmations — unknown TX returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getConfirmations("nonexistent_tx_hash") == null);
}

test "Blockchain.getConfirmations — tracked TX returns correct count" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    // Simulate: TX was included in block at height 5
    try bc.tx_block_height.put("test_tx_hash_001", 5);
    // Chain has 1 block (genesis at index 0), so chain.items.len = 1
    // Confirmations = 1 - 5 => would underflow, so should return 0
    try testing.expectEqual(@as(u64, 0), bc.getConfirmations("test_tx_hash_001").?);
}

test "Blockchain.getTxBlockHeight — returns stored height" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.tx_block_height.put("tx_abc", 42);
    try testing.expectEqual(@as(u64, 42), bc.getTxBlockHeight("tx_abc").?);
}

test "Blockchain.getTxBlockHeight — unknown returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getTxBlockHeight("unknown") == null);
}

// ─── Block Validation Tests (B7) ────────────────────────────────────────────

test "Blockchain.validateBlock — genesis block always valid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    try testing.expect(bc.validateBlock(&genesis));
}

test "Blockchain.validateBlock — wrong merkle root rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Set difficulty to 1 so our fake hash passes difficulty check
    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0xFF} ** 32, // Wrong merkle root (should be all zeros for empty TX list)
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — future timestamp rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;
    const now = std.time.timestamp();

    var block = Block{
        .index = 1,
        .timestamp = now + 10000, // More than 2 hours in the future
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — wrong previous_hash rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "wrong_previous_hash_does_not_match_genesis",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — hash not meeting difficulty rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // difficulty = 4 (default), hash has only 1 leading zero
    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    // difficulty=4 but hash has only 1 leading zero => rejected
    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — inflated reward rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 999_999_999_999, // Way more than allowed block reward
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — valid block passes all checks" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32, // Correct for empty TX list
        .reward_sat = BLOCK_REWARD_SAT, // Correct block reward
    };
    defer block.transactions.deinit();

    try testing.expect(bc.validateBlock(&block));
}

test "Blockchain.addExternalBlock — invalid block returns error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Block with wrong merkle root
    var bad_block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "0000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0xFF} ** 32,
        .reward_sat = 0,
    };
    defer bad_block.transactions.deinit();

    try testing.expectError(error.InvalidBlock, bc.addExternalBlock(bad_block));
}

test "Blockchain.addExternalBlock — valid block appended and miner credited" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;
    const reward = blockRewardAt(1);

    // Heap-allocate hash so deinit can free it (blocks at index>0 with 64-char hash get freed)
    const hash_str = try testing.allocator.alloc(u8, 64);
    @memset(hash_str, 'a');
    hash_str[0] = '0'; // leading zero for difficulty=1
    const block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = hash_str,
        .merkle_root = [_]u8{0} ** 32,
        .miner_address = "ob1q5lk2scarv6nvqgzeekdv5xhjv7v9yex73qhm40",
        .reward_sat = reward,
    };
    // Do NOT defer deinit — blockchain takes ownership (deinit frees hash + transactions)

    try bc.addExternalBlock(block);

    // Chain should now have 2 blocks (genesis + external)
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());
    // Miner should be credited with block reward
    try testing.expectEqual(reward, bc.getAddressBalance("ob1q5lk2scarv6nvqgzeekdv5xhjv7v9yex73qhm40"));
}

// ─── Timelock + OP_RETURN Blockchain Tests (B4) ────────────────────────────

test "Blockchain.validateTransaction — locktime > current_height rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_lockh", 0, "ob1qmcl7lj9e5wg6523ynqyg6xklhg67tgjspv7dg6", 100_000, 1, "", false);

    // Chain has 1 block (genesis), so chain.items.len = 1 = current_height
    // TX locked until block 100 → rejected (100 > 1)
    const tx = Transaction{
        .id = 1, .from_address = "ob1qmcl7lj9e5wg6523ynqyg6xklhg67tgjspv7dg6", .to_address = "ob1qlu4ev8rqhzw65w7m0at8khnvxje9y7t7n2plhn",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 100,
        .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — locktime <= current_height accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_lock1", 0, "ob1qje7f8p2nm66d2x5m6vvx8s0wkuyhc439c2q85r", 100_000, 1, "", false);

    // Chain has 1 block, so current_height = 1
    // TX locked until block 1 → accepted (1 <= 1)
    const tx = Transaction{
        .id = 1, .from_address = "ob1qje7f8p2nm66d2x5m6vvx8s0wkuyhc439c2q85r", .to_address = "ob1qvwz680427a037eqyzv675xavxm8txh792h3m0r",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 1,
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — locktime 0 always accepted (immediate)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_lock0", 0, "ob1qwtdsz27whtcajhqjl4e6yc9l2vpujzzt7z8dxe", 100_000, 1, "", false);

    const tx = Transaction{
        .id = 1, .from_address = "ob1qwtdsz27whtcajhqjl4e6yc9l2vpujzzt7z8dxe", .to_address = "ob1qvvvn3uz7nh2v93eyx7y85rc7usumvgc3kle246",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 0,
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — op_return data-only TX accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // OP_RETURN TX: amount=0, op_return set, fee >= 1
    try bc.utxo_set.addUTXO("funding_tx_opret", 0, "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2", 100_000, 1, "", false);

    const tx = Transaction{
        .id = 1, .from_address = "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2", .to_address = "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2",
        .amount = 0, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .op_return = "timestamp:2026-03-30T12:00:00Z",
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — op_return > 80 bytes rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("funding_tx_big", 0, "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3", 100_000, 1, "", false);

    const big_data = "X" ** 81;
    const tx = Transaction{
        .id = 1, .from_address = "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3", .to_address = "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3",
        .amount = 0, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .op_return = big_data,
        .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

// ─── Chain Reorganization Tests (B8) ────────────────────────────────────────

/// Helper: create a valid block with given parameters (difficulty=1, no TX)
/// `variant` byte makes the hash unique across different chains (0='a' default)
fn makeTestBlockV(alloc: std.mem.Allocator, idx: u32, prev_hash: []const u8, miner: []const u8, variant: u8) !Block {
    const hash_str = try alloc.alloc(u8, 64);
    @memset(hash_str, 'a');
    hash_str[0] = '0'; // leading zero for difficulty=1

    // Make hash unique per index by encoding the index
    var idx_buf: [10]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch "0";
    for (idx_str, 0..) |c, j| {
        if (j + 1 < 64) hash_str[j + 1] = c;
    }
    // Variant byte at a safe position to differentiate chains
    if (variant != 0) {
        hash_str[12] = variant;
    }

    return Block{
        .index = idx,
        .timestamp = 1743000000 + @as(i64, @intCast(idx)),
        .transactions = array_list.Managed(Transaction).init(alloc),
        .previous_hash = prev_hash,
        .nonce = 0,
        .hash = hash_str,
        .merkle_root = [_]u8{0} ** 32,
        .miner_address = miner,
        .reward_sat = blockRewardAt(@intCast(idx)),
    };
}

fn makeTestBlock(alloc: std.mem.Allocator, idx: u32, prev_hash: []const u8, miner: []const u8) !Block {
    return makeTestBlockV(alloc, idx, prev_hash, miner, 0);
}

test "Blockchain.reorg — longer chain accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add block 1 to our chain
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());

    // Build a longer competing chain: genesis + block1' + block2'
    // (same genesis, different blocks after)
    const genesis = bc.getBlock(0).?;

    const alt_block1 = try makeTestBlockV(testing.allocator, 1, genesis.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'b');

    const alt_block2 = try makeTestBlockV(testing.allocator, 2, alt_block1.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'b');

    var new_chain: [3]Block = undefined;
    new_chain[0] = genesis;
    new_chain[1] = alt_block1;
    new_chain[2] = alt_block2;

    try bc.reorg(&new_chain);

    // Chain should now be 3 blocks (genesis + alt1 + alt2)
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
    // Miner B should be credited (from recalculation)
    try testing.expect(bc.getAddressBalance("ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092") > 0);

    // Clean up alt blocks that are now owned by chain (deinit handles them)
    // alt_block1 and alt_block2 transactions are owned by the chain via append
}

test "Blockchain.reorg — shorter chain rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add 2 blocks to our chain
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);

    const block2 = try makeTestBlock(testing.allocator, 2, block1.hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block2);
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());

    // Try reorg with a chain of same length (3 blocks) — should be rejected
    const genesis = bc.getBlock(0).?;
    const alt_block1 = try makeTestBlock(testing.allocator, 1, genesis.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block1.hash);
    defer alt_block1.transactions.deinit();

    const alt_block2 = try makeTestBlock(testing.allocator, 2, alt_block1.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block2.hash);
    defer alt_block2.transactions.deinit();

    var same_len_chain: [3]Block = undefined;
    same_len_chain[0] = genesis;
    same_len_chain[1] = alt_block1;
    same_len_chain[2] = alt_block2;

    try testing.expectError(error.ShorterChain, bc.reorg(&same_len_chain));

    // Chain should still be 3 blocks (unchanged)
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
}

test "Blockchain.reorg — depth > MAX_REORG_DEPTH rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Build a chain of MAX_REORG_DEPTH + 2 blocks (genesis + 101 blocks)
    var prev_hash: []const u8 = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982";
    for (1..MAX_REORG_DEPTH + 2) |i| {
        const blk = try makeTestBlock(testing.allocator, @intCast(i), prev_hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
        try bc.addExternalBlock(blk);
        prev_hash = bc.chain.items[bc.chain.items.len - 1].hash;
    }

    // Our chain: genesis + 101 blocks = 102 blocks
    try testing.expectEqual(@as(u32, MAX_REORG_DEPTH + 2), bc.getBlockCount());

    // Build a competing chain that forks from genesis (depth = 101 > MAX_REORG_DEPTH)
    const genesis = bc.getBlock(0).?;

    // New chain needs to be longer: genesis + 102 alt blocks = 103 blocks
    var alt_chain_buf: [MAX_REORG_DEPTH + 3]Block = undefined;
    alt_chain_buf[0] = genesis;

    var alt_prev: []const u8 = genesis.hash;
    for (1..MAX_REORG_DEPTH + 3) |i| {
        const alt_blk = try makeTestBlockV(testing.allocator, @intCast(i), alt_prev, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'z');
        alt_chain_buf[i] = alt_blk;
        alt_prev = alt_blk.hash;
    }

    const result = bc.reorg(alt_chain_buf[0 .. MAX_REORG_DEPTH + 3]);
    try testing.expectError(error.ReorgTooDeep, result);

    // Chain should be unchanged
    try testing.expectEqual(@as(u32, MAX_REORG_DEPTH + 2), bc.getBlockCount());

    // Clean up alt blocks
    for (1..MAX_REORG_DEPTH + 3) |i| {
        testing.allocator.free(alt_chain_buf[i].hash);
        alt_chain_buf[i].transactions.deinit();
    }
}

test "Blockchain.addExternalBlock — orphan stored when parent unknown" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Block whose parent we don't have
    const orphan = try makeTestBlock(testing.allocator, 5, "unknown_parent_hash_that_does_not_exist_in_our_chain_at_all_xxxx", "ob1q3c4mm4mpad5mnzpush3mzt0umdk7sqy7kml67e");

    try bc.addExternalBlock(orphan);

    // Block should be in orphan pool, not in chain
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount()); // still just genesis
    try testing.expectEqual(@as(usize, 1), bc.orphan_blocks.items.len);
}

test "Blockchain.processOrphans — orphan connected when parent arrives" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Create block 1 and block 2, but send block 2 first (orphan)
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    const block2 = try makeTestBlock(testing.allocator, 2, block1.hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");

    // Send block 2 first — parent unknown, goes to orphan pool
    try bc.addExternalBlock(block2);
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount()); // just genesis
    try testing.expectEqual(@as(usize, 1), bc.orphan_blocks.items.len);

    // Now send block 1 — connects to genesis, then orphan block 2 should auto-connect
    try bc.addExternalBlock(block1);

    // Chain should now have 3 blocks: genesis + block1 + block2
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
    // Orphan pool should be empty
    try testing.expectEqual(@as(usize, 0), bc.orphan_blocks.items.len);
}

test "Blockchain.findForkPoint — common ancestor found" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add block 1
    const block1 = try makeTestBlock(testing.allocator, 1, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);

    // Other chain shares genesis + block1, then diverges
    const genesis = bc.getBlock(0).?;
    var other_chain: [3]Block = undefined;
    other_chain[0] = genesis;
    other_chain[1] = bc.chain.items[1]; // same block1

    const alt_block2 = try makeTestBlock(testing.allocator, 2, bc.chain.items[1].hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block2.hash);
    defer alt_block2.transactions.deinit();
    other_chain[2] = alt_block2;

    const fork = bc.findForkPoint(&other_chain);
    try testing.expect(fork != null);
    try testing.expectEqual(@as(usize, 1), fork.?); // fork at block 1
}

test "Blockchain.findForkPoint — no common ancestor" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Build a chain with completely different hashes
    const fake_block = Block{
        .index = 0,
        .timestamp = 9999999999,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
        .nonce = 0,
        .hash = "completely_different_genesis",
    };
    defer fake_block.transactions.deinit();

    var other_chain = [_]Block{fake_block};

    try testing.expect(bc.findForkPoint(&other_chain) == null);
}

test "Blockchain.indexAddressTx — TX appears in both sender and receiver history" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const addr_a = "ob1qyfr7eu6lawmtpc70htrf7cxpenlfxhhm8pu952";
    const addr_b = "ob1q23qfxzsfjdsyj6em4u3egclxfqmzue5etu4h6u";
    const tx_hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";

    // Simulate indexing a TX for both addresses (like mineBlockForMiner does)
    bc.indexAddressTx(addr_a, tx_hash);
    bc.indexAddressTx(addr_b, tx_hash);

    // Both addresses should have the TX in their history
    const history_a = bc.getAddressHistory(addr_a);
    try testing.expect(history_a != null);
    try testing.expectEqual(@as(usize, 1), history_a.?.len);
    try testing.expectEqualStrings(tx_hash, history_a.?[0]);

    const history_b = bc.getAddressHistory(addr_b);
    try testing.expect(history_b != null);
    try testing.expectEqual(@as(usize, 1), history_b.?.len);
    try testing.expectEqualStrings(tx_hash, history_b.?[0]);
}

test "Blockchain.indexAddressTx — multiple TXs accumulate per address" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const addr = "ob1qn8psc97zfjv0hak3nqyvgz7mjewq0hqyv7mgu7";
    const tx1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const tx2 = "2222222222222222222222222222222222222222222222222222222222222222";
    const tx3 = "3333333333333333333333333333333333333333333333333333333333333333";

    bc.indexAddressTx(addr, tx1);
    bc.indexAddressTx(addr, tx2);
    bc.indexAddressTx(addr, tx3);

    const history = bc.getAddressHistory(addr);
    try testing.expect(history != null);
    try testing.expectEqual(@as(usize, 3), history.?.len);
}

test "Blockchain.getAddressHistory — unknown address returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try testing.expect(bc.getAddressHistory("ob1q80wdpvx6ewepelcnt4pu07jhe300kxtw5hhxyf") == null);
}

test "Blockchain.indexAddressTx — empty address ignored" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.indexAddressTx("", "somehash");
    try testing.expect(bc.getAddressHistory("") == null);
}

test "Blockchain.blocks_since_save — increments and resets" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Initially zero
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);

    // Increment
    bc.blocks_since_save += 1;
    try testing.expectEqual(@as(u32, 1), bc.blocks_since_save);

    bc.blocks_since_save += 49;
    try testing.expectEqual(@as(u32, 50), bc.blocks_since_save);

    // Reset
    bc.blocks_since_save = 0;
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);
}

test "Blockchain.checkAutoSave — triggers at block threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // No persistent_db attached — checkAutoSave is a no-op (no crash)
    bc.blocks_since_save = 100;
    bc.checkAutoSave();
    // Without a persistent_db, counters still reset on threshold
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);
}

test "Blockchain.checkAutoSave — triggers at TX threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.txs_since_save = 1000;
    bc.checkAutoSave();
    try testing.expectEqual(@as(u32, 0), bc.txs_since_save);
}

test "Blockchain.checkAutoSave — does not trigger below threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.blocks_since_save = 50;
    bc.txs_since_save = 500;
    bc.last_save_time = std.time.timestamp(); // just now
    bc.checkAutoSave();
    // Should NOT have reset — thresholds not met
    try testing.expectEqual(@as(u32, 50), bc.blocks_since_save);
    try testing.expectEqual(@as(u32, 500), bc.txs_since_save);
}

test "Blockchain.saveToDisc — no-op without persistent_db" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Should not error — just returns silently
    try bc.saveToDisc();
}

// ─── Script Engine Integration Tests ──────────────────────────────────────────

const Secp256k1Crypto = @import("secp256k1.zig").Secp256k1Crypto;
const Ripemd160 = @import("ripemd160.zig").Ripemd160;

test "Blockchain.validateTransaction — legacy TX (no scripts) still validates" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_legacy", 0, "ob1qpuvwpsyt4r0p9c800qhgmnz7n4mjffs36g8r5m", 10_000, 1, "", false);
    const tx = Transaction{
        .id = 1, .from_address = "ob1qpuvwpsyt4r0p9c800qhgmnz7n4mjffs36g8r5m", .to_address = "ob1qa85832ynnv6lmc43mm07qjxk80mswapgz0zc63",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        // script_pubkey and script_sig default to "" (legacy mode)
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — TX with valid P2PKH scripts validates" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_p2pkh", 0, "ob1qzkl36jh98nwlqhz2ldspp7enquuh9fvq2s5pna", 10_000, 1, "", false);

    // Generate sender keypair
    const kp = try Secp256k1Crypto.generateKeyPair();

    // Compute receiver pubkey hash (for locking script)
    // Here we lock to the sender's own key for simplicity
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);

    // Create P2PKH lock script
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    // Create TX (unsigned first to get hash)
    var tx = Transaction{
        .id = 1, .from_address = "ob1qzkl36jh98nwlqhz2ldspp7enquuh9fvq2s5pna", .to_address = "ob1qp4zd3f7wuputqdljt0xmu8lah0gkt47usjayzf",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
    };

    // Get TX hash and sign it
    const tx_hash = tx.calculateHash();
    const sig = try Secp256k1Crypto.sign(kp.private_key, &tx_hash);

    // Create P2PKH unlock script
    const unlock_script = script_mod.createP2PKHUnlock(sig, kp.public_key);
    tx.script_sig = &unlock_script;

    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — TX with invalid scripts rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_invscript", 0, "ob1q8sfgk7l05gngpwm6u8m964j4cmz8arly600chj", 10_000, 1, "", false);

    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    // Lock to kp1's pubkey hash
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp1.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    var tx = Transaction{
        .id = 1, .from_address = "ob1q8sfgk7l05gngpwm6u8m964j4cmz8arly600chj", .to_address = "ob1qtsdal04x4kahc0rzljtkzwqpnq8p3mhn4jrv8f",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
    };

    // Sign with kp2 (wrong key) — unlock won't match lock
    const tx_hash = tx.calculateHash();
    const sig = try Secp256k1Crypto.sign(kp2.private_key, &tx_hash);
    const unlock_script = script_mod.createP2PKHUnlock(sig, kp2.public_key);
    tx.script_sig = &unlock_script;

    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — script_pubkey set but script_sig empty rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.utxo_set.addUTXO("funding_tx_nosig", 0, "ob1qguvehlayw4x0v2ku25zw82tfkxsqcjv3l4xtns", 10_000, 1, "", false);

    const kp = try Secp256k1Crypto.generateKeyPair();
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    const tx = Transaction{
        .id = 1, .from_address = "ob1qguvehlayw4x0v2ku25zw82tfkxsqcjv3l4xtns", .to_address = "ob1qvuhxtgd6p0wu6f2vn3g9l9l70uhd02hjxwf938",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
        .script_sig = "",  // empty — should be rejected
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

// ─── Bridge consensus hook tests ─────────────────────────────────────────────

test "Blockchain.isBridgeLockTx — recognizes vault address + OMNIBRIDGE prefix" {
    const cfg_local = @import("chain_config.zig");
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1quser",
        .to_address = cfg_local.BRIDGE_VAULT_ADDR_HEX,
        .amount = 1_000_000,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .op_return = "OMNIBRIDGE:liberty_testnet:0xabcd",
        .signature = "",
        .hash = "",
    };
    try testing.expect(Blockchain.isBridgeLockTx(&tx));
}

test "Blockchain.isBridgeLockTx — rejects non-vault destination" {
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1quser",
        .to_address = "ob1qsomeotheraddress0000000000000000000000",
        .amount = 1_000_000,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .op_return = "OMNIBRIDGE:liberty_testnet:0xabcd",
        .signature = "",
        .hash = "",
    };
    try testing.expect(!Blockchain.isBridgeLockTx(&tx));
}

test "Blockchain.isBridgeLockTx — rejects vault dest without OMNIBRIDGE prefix" {
    const cfg_local = @import("chain_config.zig");
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1quser",
        .to_address = cfg_local.BRIDGE_VAULT_ADDR_HEX,
        .amount = 1_000_000,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .op_return = "regular memo not bridge",
        .signature = "",
        .hash = "",
    };
    try testing.expect(!Blockchain.isBridgeLockTx(&tx));
}


// ─── PHASE B: UTXO Source-of-Truth Tests ────────────────────────────────────

test "applyBlock spends sender UTXOs and creates recipient UTXO" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Fund address A with a mature non-coinbase UTXO
    try bc.utxo_set.addUTXO("coinbase_a", 0, "ob1qalice", 1_000_000_000, 1, "", false);

    // Build a block with A -> B for 500M
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qalice",
        .to_address = "ob1qbob",
        .amount = 500_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "tx_ab_01_hash_________________________________",
    };

    var block = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "block_01_hash_________________________________",
        .miner_address = "ob1qminer",
        .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);
    // NOTE: applyBlock appends a copy to chain; we must NOT deinit our copy's
    // transactions because chain's copy shares the same underlying allocation.

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // UTXO set should have: B's output + A's change + miner's coinbase
    try testing.expectEqual(@as(u64, 3), bc.utxo_set.count);
    try testing.expectEqual(@as(u64, 500_000_000), bc.utxo_set.getBalance("ob1qbob"));
    try testing.expectEqual(@as(u64, 500_000_000 - 1_000), bc.utxo_set.getBalance("ob1qalice")); // change
    try testing.expect(bc.utxo_set.getBalance("ob1qminer") >= BLOCK_REWARD_SAT);

    // getAddressBalance reads from UTXO
    try testing.expectEqual(@as(u64, 500_000_000), bc.getAddressBalance("ob1qbob"));
    try testing.expectEqual(@as(u64, 500_000_000 - 1_000), bc.getAddressBalance("ob1qalice"));
}

test "auditBalanceConsistency returns 0 divergences after normal applyBlock" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Fund and transfer via applyBlock so both cache and UTXO are updated.
    // Must seed BOTH UTXO and RAM cache before applyBlock so they start aligned.
    try bc.utxo_set.addUTXO("fund_audit", 0, "ob1qaudit", 1_000_000_000, 1, "", false);
    try bc.creditBalance("ob1qaudit", 1_000_000_000);
    const tx = Transaction{
        .id = 1, .from_address = "ob1qaudit", .to_address = "ob1qrecv",
        .amount = 100_000_000, .fee = 1_000, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "tx_audit_01_____________________________________",
    };
    var block = Block{
        .index = 1, .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", .nonce = 0,
        .hash = "block_audit_01__________________________________",
        .miner_address = "ob1qminer", .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    const result = bc.auditBalanceConsistency();
    try testing.expectEqual(@as(usize, 0), result.divergences);
}

test "auditBalanceConsistency catches phantom RAM credit" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Create a phantom RAM credit without UTXO
    try bc.balances.put("ob1qphantom", 999);

    const result = bc.auditBalanceConsistency();
    try testing.expectEqual(@as(usize, 1), result.divergences);
    try testing.expectEqual(@as(usize, 1), result.addresses_checked);
}

test "getMatureBalance excludes immature coinbase" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Coinbase to A at height 5
    try bc.utxo_set.addUTXO("coinbase_a", 0, "ob1qminerA", 50_000_000_000, 5, "", true);

    // Add dummy blocks to reach height 50 (genesis at 0, need 50 more)
    var h: u32 = 1;
    while (h <= 50) : (h += 1) {
        const b = Block{
            .index = h,
            .timestamp = 1700000000 + @as(i64, h),
            .transactions = array_list.Managed(Transaction).init(testing.allocator),
            .previous_hash = "dummy_prev____________________________________",
            .nonce = 0,
            .hash = "dummy_hash____________________________________",
        };
        try bc.chain.append(b);
    }

    // At height 50, coinbase at height 5 is NOT yet mature (needs 105)
    try testing.expectEqual(@as(u64, 0), bc.getMatureBalance("ob1qminerA"));
    try testing.expectEqual(@as(u64, 50_000_000_000), bc.getAddressBalance("ob1qminerA")); // total includes immature

    // Add 55 more blocks to reach height 105
    while (h <= 105) : (h += 1) {
        const b = Block{
            .index = h,
            .timestamp = 1700000000 + @as(i64, h),
            .transactions = array_list.Managed(Transaction).init(testing.allocator),
            .previous_hash = "dummy_prev____________________________________",
            .nonce = 0,
            .hash = "dummy_hash____________________________________",
        };
        try bc.chain.append(b);
    }

    // At height 105, coinbase at height 5 IS mature (5 + 100 = 105)
    try testing.expectEqual(@as(u64, 50_000_000_000), bc.getMatureBalance("ob1qminerA"));
}


// ─── PHASE C / wire-format v2 tests ─────────────────────────────────────────

test "v2 wire: TX spends listed inputs, leaves untouched UTXOs alone" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Seed two mature non-coinbase UTXOs to alice; spend only one.
    try bc.utxo_set.addUTXO("seed_a1", 0, "ob1qalicev2", 600_000_000, 1, "", false);
    try bc.utxo_set.addUTXO("seed_a2", 0, "ob1qalicev2", 400_000_000, 1, "", false);

    const inputs = [_]Outpoint{
        .{ .tx_hash = "seed_a1", .output_index = 0 },
    };
    const outputs = [_]TxOutput{
        .{ .amount = 100_000_000, .address = "ob1qbobv2" },
    };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qalicev2",
        .to_address = "ob1qbobv2",
        .amount = 100_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_tx_alice_to_bob______________________________",
        .inputs = &inputs,
        .outputs = &outputs,
    };

    var block = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "v2_block_01_____________________________________",
        .miner_address = "ob1qminerv2",
        .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // bob got 100M; alice change = 600M - 100M - 1000 = 499_999_000;
    // alice still has the untouched seed_a2 (400M) → total alice = 899_999_000.
    try testing.expectEqual(@as(u64, 100_000_000), bc.utxo_set.getBalance("ob1qbobv2"));
    try testing.expectEqual(@as(u64, 400_000_000 + 499_999_000),
        bc.utxo_set.getBalance("ob1qalicev2"));
}

test "v2 wire: TX with explicit outputs[] creates each as a UTXO" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.utxo_set.addUTXO("seed_b", 0, "ob1qsenderv2", 1_000_000_000, 1, "", false);

    const inputs = [_]Outpoint{ .{ .tx_hash = "seed_b", .output_index = 0 } };
    const outputs = [_]TxOutput{
        .{ .amount = 700_000_000, .address = "ob1qrecv1v2" },
        .{ .amount = 200_000_000, .address = "ob1qrecv2v2" },
    };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qsenderv2",
        .to_address = "ob1qrecv1v2", // legacy field, ignored when outputs[] present
        .amount = 700_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_multi_out_tx_________________________________",
        .inputs = &inputs,
        .outputs = &outputs,
    };

    var block = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "v2_block_multiout_______________________________",
        .miner_address = "ob1qminerv2",
        .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    try testing.expectEqual(@as(u64, 700_000_000), bc.utxo_set.getBalance("ob1qrecv1v2"));
    try testing.expectEqual(@as(u64, 200_000_000), bc.utxo_set.getBalance("ob1qrecv2v2"));
    // change = 1B - 900M - 1000 = 99_999_000
    try testing.expectEqual(@as(u64, 99_999_000), bc.utxo_set.getBalance("ob1qsenderv2"));
}

test "v2 wire: validateTransaction rejects TX with input owned by other address" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Seed UTXO owned by victim
    try bc.utxo_set.addUTXO("seed_victim", 0, "ob1qvictimv2", 1_000_000_000, 1, "", false);

    // Attacker tries to spend it
    const inputs = [_]Outpoint{ .{ .tx_hash = "seed_victim", .output_index = 0 } };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qattackerv2",
        .to_address = "ob1qattackerv2",
        .amount = 500_000_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_steal_attempt________________________________",
        .inputs = &inputs,
    };

    const ok = try bc.validateTransaction(&tx);
    try testing.expect(!ok); // must reject — input not owned by from_address
}

test "v2 wire: validateTransaction rejects TX with non-existent input" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const inputs = [_]Outpoint{
        .{ .tx_hash = "ghost_tx_does_not_exist", .output_index = 0 },
    };
    const tx = Transaction{
        .id = 1,
        .from_address = "ob1qghostv2",
        .to_address = "ob1qrecvghostv2",
        .amount = 1_000,
        .fee = 1_000,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "v2_ghost_input__________________________________",
        .inputs = &inputs,
    };

    const ok = try bc.validateTransaction(&tx);
    try testing.expect(!ok); // must reject — input not in UTXO set
}

// Helper for fee-settlement tests: free the duped balance keys we inserted
// outside the normal apply_block flow (Blockchain.deinit doesn't own them).
fn freeBalanceKeys(bc: *Blockchain, addrs: []const []const u8) void {
    for (addrs) |a| {
        if (bc.balances.fetchRemove(a)) |kv| {
            bc.allocator.free(kv.key);
        }
    }
}

test "applyExchangeFees: routes network fee to miner accumulator (default)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const taker = "ob1qtestxtaker0000000000000000000000000000";
    const maker = "ob1qtestxmaker0000000000000000000000000000";
    const treasury = registrar_mod.addressOf(.exchange).?;
    defer freeBalanceKeys(&bc, &.{ taker, maker, treasury });

    bc.in_apply_block = true;
    try bc.creditBalanceLocked(taker, 1_000_000);
    try bc.creditBalanceLocked(maker, 1_000_000);
    bc.in_apply_block = false;

    const treasury_before = bc.balances.get(treasury) orelse 0;
    try testing.expect(bc.consensus_params.route_fees_to_miner); // default ON

    // Charge: taker_fee=2000, maker_fee=1000, network=1000 → split 500/500.
    // Default routing: treasury gets only the exchange fees (3_000), the
    // network 1_000 lands in pending_miner_fees and is settled at the next
    // applyBlock to that block's miner.
    try bc.applyExchangeFees(taker, maker, 2_000, 1_000, 1_000);

    try testing.expectEqual(@as(u64, 1_000_000 - 2_500), bc.balances.get(taker).?);
    try testing.expectEqual(@as(u64, 1_000_000 - 1_500), bc.balances.get(maker).?);
    try testing.expectEqual(treasury_before + 3_000, bc.balances.get(treasury) orelse 0);
    try testing.expectEqual(@as(u64, 1_000), bc.pending_miner_fees);
}

test "applyExchangeFees: legacy treasury routing when flag flipped" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const taker = "ob1qtreasurytaker0000000000000000000000000";
    const maker = "ob1qtreasurymaker0000000000000000000000000";
    const treasury = registrar_mod.addressOf(.exchange).?;
    defer freeBalanceKeys(&bc, &.{ taker, maker, treasury });

    bc.consensus_params.route_fees_to_miner = false; // revert to old behaviour

    bc.in_apply_block = true;
    try bc.creditBalanceLocked(taker, 1_000_000);
    try bc.creditBalanceLocked(maker, 1_000_000);
    bc.in_apply_block = false;

    const treasury_before = bc.balances.get(treasury) orelse 0;

    try bc.applyExchangeFees(taker, maker, 2_000, 1_000, 1_000);

    try testing.expectEqual(@as(u64, 1_000_000 - 2_500), bc.balances.get(taker).?);
    try testing.expectEqual(@as(u64, 1_000_000 - 1_500), bc.balances.get(maker).?);
    // Full taker_fee + maker_fee + network goes to treasury (legacy path).
    try testing.expectEqual(treasury_before + 4_000, bc.balances.get(treasury) orelse 0);
    try testing.expectEqual(@as(u64, 0), bc.pending_miner_fees);
}

test "applyExchangeFees: rejects insufficient balance without partial mutation" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const taker = "ob1qpoor0taker000000000000000000000000000";
    const maker = "ob1qrich0maker000000000000000000000000000";
    const treasury = registrar_mod.addressOf(.exchange).?;
    defer freeBalanceKeys(&bc, &.{ taker, maker, treasury });

    bc.in_apply_block = true;
    try bc.creditBalanceLocked(taker, 100);
    try bc.creditBalanceLocked(maker, 1_000_000);
    bc.in_apply_block = false;

    const treasury_before = bc.balances.get(treasury) orelse 0;

    try testing.expectError(
        error.InsufficientBalance,
        bc.applyExchangeFees(taker, maker, 5_000, 1_000, 1_000),
    );

    try testing.expectEqual(@as(u64, 100), bc.balances.get(taker).?);
    try testing.expectEqual(@as(u64, 1_000_000), bc.balances.get(maker).?);
    try testing.expectEqual(treasury_before, bc.balances.get(treasury) orelse 0);
}

// ─── Governance proposal execution + miner fee routing tests ────────────────

test "executeProposal: set_block_reward updates consensus_params after pass" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Bootstrap default == BLOCK_REWARD_SAT.
    try testing.expectEqual(@as(u64, BLOCK_REWARD_SAT), bc.consensus_params.block_reward_sat);

    const pp = gov_mod.ParsedPropose{
        .title_hash = "a" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 5,
        .quorum = 100,
        .note = "set reward to 40 OMNI",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_block_reward,
        .u64_value = 40_000_000_000, // 40 OMNI in SAT
    };
    const id = try bc.gov_registry.proposeWithAction("ob1qproposer", pp, 100, action);
    try bc.gov_registry.vote(id, "ob1qzen", true, "ZEN", 101); // weight 1000
    bc.gov_registry.finalizeProposals(110);

    try bc.executeProposal(id, 110);

    try testing.expectEqual(@as(u64, 40_000_000_000), bc.consensus_params.block_reward_sat);
    const p = bc.gov_registry.getProposal(id).?;
    try testing.expect(p.executed);
    try testing.expectEqual(gov_mod.ProposalStatus.executed, p.status);
}

test "executeProposal: rejects already-executed proposal" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const pp = gov_mod.ParsedPropose{
        .title_hash = "b" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 5,
        .quorum = 50,
        .note = "",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_min_difficulty,
        .u64_value = 8,
    };
    const id = try bc.gov_registry.proposeWithAction("ob1qprop", pp, 100, action);
    try bc.gov_registry.vote(id, "ob1qzen", true, "ZEN", 101);
    bc.gov_registry.finalizeProposals(110);

    try bc.executeProposal(id, 110);
    try testing.expectEqual(@as(u32, 8), bc.consensus_params.min_difficulty);

    // Second call must reject — proposal is now .executed, not .passed.
    try testing.expectError(error.ProposalNotPassed, bc.executeProposal(id, 111));
}

test "executeProposal: rejects proposal that did not pass" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const pp = gov_mod.ParsedPropose{
        .title_hash = "c" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 5,
        .quorum = 50,
        .note = "",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_block_size_limit,
        .u64_value = 2_097_152,
    };
    const id = try bc.gov_registry.proposeWithAction("ob1qprop", pp, 100, action);
    // Vote NO so the proposal is rejected at finalize.
    try bc.gov_registry.vote(id, "ob1qzen", false, "ZEN", 101);
    bc.gov_registry.finalizeProposals(110);

    try testing.expectError(error.ProposalNotPassed, bc.executeProposal(id, 110));
    try testing.expectEqual(@as(u64, 1_048_576), bc.consensus_params.block_size_limit); // unchanged
}

test "applyBlock auto-executes a passed proposal at the next block" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const pp = gov_mod.ParsedPropose{
        .title_hash = "d" ** gov_mod.TITLE_HASH_LEN,
        .voting_blocks = 1,
        .quorum = 50,
        .note = "",
    };
    const action = gov_mod.ProposalAction{
        .kind = .set_validator_quorum_min,
        .u64_value = 5,
    };
    // Voting opens at create_block; ends at create_block + 1.
    const id = try bc.gov_registry.proposeWithAction("ob1qprop", pp, 0, action);
    try bc.gov_registry.vote(id, "ob1qzen", true, "ZEN", 1); // weight 1000

    // Mine a block at index >= voting_end_block (1) so finalize+autoExec kick.
    const block = Block{
        .index = 5,
        .timestamp = 1700000000,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "block_gov_autoexec______________________________",
        .miner_address = "ob1qminergov",
        .reward_sat = BLOCK_REWARD_SAT,
    };

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    try testing.expectEqual(@as(u32, 5), bc.consensus_params.validator_quorum_min);
    const p = bc.gov_registry.getProposal(id).?;
    try testing.expectEqual(gov_mod.ProposalStatus.executed, p.status);
    try testing.expectEqual(@as(u64, 5), p.executed_block);
}

test "applyBlock credits accumulated exchange fees to miner alongside reward" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Simulate a fill that landed mid-block: pending_miner_fees has 7_500 sat.
    bc.pending_miner_fees = 7_500;
    try testing.expect(bc.consensus_params.route_fees_to_miner);

    const block = Block{
        .index = 1,
        .timestamp = 1700000000,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "block_fees_to_miner____________________________1",
        .miner_address = "ob1qminerfees",
        .reward_sat = BLOCK_REWARD_SAT,
    };

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // Miner receives reward + accumulator. No TX-level fees in this block.
    const miner_bal = bc.utxo_set.getBalance("ob1qminerfees");
    try testing.expectEqual(BLOCK_REWARD_SAT + 7_500, miner_bal);
    // Accumulator drained.
    try testing.expectEqual(@as(u64, 0), bc.pending_miner_fees);
    // Cumulative tracker incremented.
    try testing.expectEqual(@as(u64, 7_500), bc.total_miner_exchange_fees);
}

test "applyBlock: per-TX fees + N*F miner credit (block_reward + N*fee)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Two senders, each pre-funded; each pays a fee F=10_000.
    try bc.utxo_set.addUTXO("seed_a_fees", 0, "ob1qfeealice", 1_000_000_000, 1, "", false);
    try bc.utxo_set.addUTXO("seed_b_fees", 0, "ob1qfeebob",   1_000_000_000, 1, "", false);

    const F: u64 = 10_000;
    const tx_a = Transaction{
        .id = 1, .from_address = "ob1qfeealice", .to_address = "ob1qfeerecv1",
        .amount = 100_000, .fee = F, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "tx_fee_a_______________________________________a",
    };
    const tx_b = Transaction{
        .id = 2, .from_address = "ob1qfeebob", .to_address = "ob1qfeerecv2",
        .amount = 100_000, .fee = F, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "tx_fee_b_______________________________________b",
    };

    var block = Block{
        .index = 1, .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", .nonce = 0,
        .hash = "block_NF_to_miner______________________________1",
        .miner_address = "ob1qminerNF", .reward_sat = BLOCK_REWARD_SAT,
    };
    try block.transactions.append(tx_a);
    try block.transactions.append(tx_b);

    bc.mutex.lock();
    defer bc.mutex.unlock();
    try bc.applyBlock(block);

    // Total fees = 2*F = 20_000; FEE_BURN_PCT=50 → 10_000 burned, 10_000 to miner.
    const total_fees = 2 * F;
    const fees_burned = total_fees * FEE_BURN_PCT / 100;
    const fees_to_miner = total_fees - fees_burned;
    const expected = BLOCK_REWARD_SAT + fees_to_miner;

    try testing.expectEqual(expected, bc.utxo_set.getBalance("ob1qminerNF"));
}

// ─── PHASE 2F.2 — HTLC end-to-end test ──────────────────────────────────────

test "HTLC roundtrip: A locks → B claims with preimage → balances flip" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const alice = "ob1qalice00000000000000000000000000000000";
    const bob   = "ob1qbob000000000000000000000000000000000";

    // Seed Alice's balance.
    bc.in_apply_block = true;
    try bc.creditBalanceLocked(alice, 1_000_000);
    bc.in_apply_block = false;

    // Generate preimage / hash.
    const pair = htlc_mod.HTLC.generatePreimage();

    // ── Block 1: Alice's htlc_init locks 500_000 ──────────────────────────
    var init_payload_buf: [tx_payload_mod.HtlcInitPayload.WIRE_SIZE]u8 = undefined;
    const init_p = tx_payload_mod.HtlcInitPayload{
        .hash_lock = pair.hash,
        .timelock_block = 100,
        .amount_sat = 500_000,
    };
    _ = try init_p.encode(&init_payload_buf);

    const init_tx_hash = "htlc_init_tx_hash_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const init_tx = Transaction{
        .id = 1,
        .from_address = alice,
        .to_address = bob,
        .amount = 0,
        .fee = 0,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = init_tx_hash,
        .tx_type = .htlc_init,
        .data = &init_payload_buf,
    };

    var b1 = Block{
        .index = 1,
        .timestamp = 1700000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982",
        .nonce = 0,
        .hash = "htlc_block_1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    };
    try b1.transactions.append(init_tx);

    bc.mutex.lock();
    try bc.applyBlock(b1);
    bc.mutex.unlock();

    // Alice should have lost 500_000; HTLC registry has 1 active entry.
    try testing.expectEqual(@as(u64, 500_000), bc.balances.get(alice).?);
    try testing.expectEqual(@as(u32, 1), bc.htlc_registry.entry_count);
    try testing.expectEqual(@as(u32, 1), bc.htlc_registry.activeCount());

    // ── Block 2: Bob's htlc_claim with the preimage ───────────────────────
    var claim_payload_buf: [tx_payload_mod.HtlcClaimPayload.WIRE_SIZE]u8 = undefined;
    const claim_p = tx_payload_mod.HtlcClaimPayload{
        .htlc_id = htlc_mod.computeHtlcId(init_tx_hash),
        .preimage = pair.preimage,
    };
    _ = try claim_p.encode(&claim_payload_buf);

    const claim_tx = Transaction{
        .id = 2,
        .from_address = bob,
        .to_address = alice, // not used by claim logic but required for address validation
        .amount = 0,
        .fee = 0,
        .timestamp = 1700000002,
        .nonce = 0,
        .signature = "",
        .hash = "htlc_claim_tx_hash_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .tx_type = .htlc_claim,
        .data = &claim_payload_buf,
    };

    var b2 = Block{
        .index = 2,
        .timestamp = 1700000003,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "htlc_block_1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .nonce = 0,
        .hash = "htlc_block_2_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    };
    try b2.transactions.append(claim_tx);

    bc.mutex.lock();
    try bc.applyBlock(b2);
    bc.mutex.unlock();

    // Bob received the 500_000; Alice still at 500_000 (already debited).
    try testing.expectEqual(@as(u64, 500_000), bc.balances.get(bob).?);
    try testing.expectEqual(@as(u64, 500_000), bc.balances.get(alice).?);
    try testing.expectEqual(@as(u32, 0), bc.htlc_registry.activeCount());
    const final = bc.htlc_registry.get(claim_p.htlc_id).?;
    try testing.expectEqual(htlc_mod.HTLCState.claimed, final.state);
    try testing.expect(final.has_preimage);
}
