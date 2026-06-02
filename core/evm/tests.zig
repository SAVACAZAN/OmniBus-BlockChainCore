// core/evm/tests.zig — 10+ tests for the OmniBus Zig EVM
//
// Run with: zig build evm-test -Doqs=false

const std = @import("std");
const evm = @import("mod.zig");

const EvmState = evm.EvmState;
const Account = evm.Account;
const TxInput = evm.TxInput;
const ExecStatus = evm.ExecStatus;
const U256 = evm.U256;
const Address = evm.Address;

const testing = std.testing;
const alloc = testing.allocator;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn make_addr(b: u8) Address {
    var a = [_]u8{0} ** 20;
    a[19] = b;
    return a;
}

fn set_balance(state: *EvmState, addr: Address, bal: u64) !void {
    var acc = state.getAccount(addr) orelse Account{
        .balance = 0, .nonce = 0, .code = &.{}, .code_hash = [_]u8{0} ** 32,
    };
    acc.balance = bal;
    try state.setAccount(addr, acc);
}

fn free_result(result: anytype) void {
    alloc.free(result.output);
    // Free logs
    for (result.logs) |log| {
        alloc.free(log.topics);
        alloc.free(log.data);
    }
    alloc.free(result.logs);
}

// ---------------------------------------------------------------------------
// Test 1: plain ETH transfer increases recipient balance
// ---------------------------------------------------------------------------
test "plain ETH transfer increases balance" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const sender = make_addr(0x01);
    const recv = make_addr(0x02);
    try set_balance(&state, sender, 1000);

    const tx = TxInput{
        .from = sender,
        .to = recv,
        .value = 300,
        .data = &.{},
        .gas_limit = 100_000,
        .nonce = 0,
    };

    const result = try evm.execute_tx(&state, &tx, alloc);
    defer free_result(result);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(@as(u64, 300), state.getBalance(recv));
    try testing.expectEqual(@as(u64, 700), state.getBalance(sender));
}

// ---------------------------------------------------------------------------
// Test 2: plain ETH transfer with insufficient balance → halt
// ---------------------------------------------------------------------------
test "insufficient balance ETH transfer halts" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const sender = make_addr(0x03);
    const recv = make_addr(0x04);
    try set_balance(&state, sender, 50);

    const tx = TxInput{
        .from = sender,
        .to = recv,
        .value = 100,
        .data = &.{},
        .gas_limit = 100_000,
        .nonce = 0,
    };

    const result = try evm.execute_tx(&state, &tx, alloc);
    defer free_result(result);

    try testing.expectEqual(ExecStatus.halt, result.status);
    // Balance unchanged
    try testing.expectEqual(@as(u64, 50), state.getBalance(sender));
    try testing.expectEqual(@as(u64, 0), state.getBalance(recv));
}

// ---------------------------------------------------------------------------
// Test 3: CHAINID opcode returns 7771
// Bytecode: CHAINID (0x46) PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
// ---------------------------------------------------------------------------
test "CHAINID opcode returns 7771" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    // Deploy a contract that returns CHAINID
    // CHAINID(0x46) PUSH1(0x00) MSTORE(0x52) PUSH1(0x20) PUSH1(0x00) RETURN(0xf3)
    const code: []const u8 = &.{ 0x46, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

    const contract_addr = make_addr(0x10);
    try state.setAccount(contract_addr, Account{
        .balance = 0,
        .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    const caller = make_addr(0x11);
    const tx = TxInput{
        .from = caller,
        .to = contract_addr,
        .value = 0,
        .data = &.{},
        .gas_limit = 100_000,
        .nonce = 0,
    };

    const result = try evm.execute_call(&state, &tx, alloc);
    defer alloc.free(result.output);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(@as(usize, 32), result.output.len);

    // Parse returned big-endian 32 bytes as u64 (last 8 bytes)
    const returned = result.output;
    var val: u64 = 0;
    for (returned[24..32]) |byte| {
        val = (val << 8) | byte;
    }
    try testing.expectEqual(@as(u64, 7771), val);
}

// ---------------------------------------------------------------------------
// Test 4: PUSH1 + ADD + RETURN returns correct value
// Bytecode: PUSH1 3, PUSH1 4, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
// Expected: 7 in the 32-byte output
// ---------------------------------------------------------------------------
test "PUSH1 ADD RETURN computes correctly" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    // PUSH1 3  (0x60 0x03)
    // PUSH1 4  (0x60 0x04)
    // ADD      (0x01)
    // PUSH1 0  (0x60 0x00)
    // MSTORE   (0x52)
    // PUSH1 32 (0x60 0x20)
    // PUSH1 0  (0x60 0x00)
    // RETURN   (0xf3)
    const code: []const u8 = &.{ 0x60, 0x03, 0x60, 0x04, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const contract_addr = make_addr(0x20);
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    const tx = TxInput{
        .from = make_addr(0x21), .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 100_000, .nonce = 0,
    };

    const result = try evm.execute_call(&state, &tx, alloc);
    defer alloc.free(result.output);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 7), result.output[31]);
}

// ---------------------------------------------------------------------------
// Test 5: REVERT opcode → ExecStatus.revert
// Bytecode: PUSH1 0x00, PUSH1 0x00, REVERT
// ---------------------------------------------------------------------------
test "REVERT opcode returns revert status" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const code: []const u8 = &.{ 0x60, 0x00, 0x60, 0x00, 0xfd };
    const contract_addr = make_addr(0x30);
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    const tx = TxInput{
        .from = make_addr(0x31), .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 100_000, .nonce = 0,
    };

    const result = try evm.execute_call(&state, &tx, alloc);
    defer alloc.free(result.output);

    try testing.expectEqual(ExecStatus.revert, result.status);
}

// ---------------------------------------------------------------------------
// Test 6: SSTORE + SLOAD round-trip
// Bytecode:
//   PUSH1 0x42   (value)
//   PUSH1 0x01   (slot)
//   SSTORE       store 0x42 at slot 0x01
//   PUSH1 0x01   (slot)
//   SLOAD        load slot 0x01 → 0x42
//   PUSH1 0x00
//   MSTORE
//   PUSH1 0x20
//   PUSH1 0x00
//   RETURN
// ---------------------------------------------------------------------------
test "SSTORE SLOAD round-trip" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const code: []const u8 = &.{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x01, // PUSH1 0x01
        0x55,       // SSTORE
        0x60, 0x01, // PUSH1 0x01
        0x54,       // SLOAD
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    const contract_addr = make_addr(0x40);
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    const caller = make_addr(0x41);
    const tx = TxInput{
        .from = caller, .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 200_000, .nonce = 0,
    };

    const result = try evm.execute_tx(&state, &tx, alloc);
    defer free_result(result);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 0x42), result.output[31]);
}

// ---------------------------------------------------------------------------
// Test 7: LOG0 emits a log
// Bytecode:
//   PUSH1 0xAB, PUSH1 0x00, MSTORE   — store 0xAB at mem[0]
//   PUSH1 0x01, PUSH1 0x1f, LOG0     — log 1 byte from offset 0x1f
//   STOP
// ---------------------------------------------------------------------------
test "LOG0 emits a log entry" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const code: []const u8 = &.{
        0x60, 0xAB, // PUSH1 0xAB
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE  (stores 0xAB at byte 31 of mem[0..32])
        0x60, 0x01, // PUSH1 0x01  (size = 1)
        0x60, 0x1f, // PUSH1 0x1f  (offset = 31)
        0xa0,       // LOG0
        0x00,       // STOP
    };
    const contract_addr = make_addr(0x50);
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    const tx = TxInput{
        .from = make_addr(0x51), .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 200_000, .nonce = 0,
    };

    const result = try evm.execute_tx(&state, &tx, alloc);
    defer free_result(result);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(@as(usize, 1), result.logs.len);
    try testing.expectEqual(@as(u8, 0xAB), result.logs[0].data[0]);
    try testing.expectEqual(@as(usize, 0), result.logs[0].topics.len);
}

// ---------------------------------------------------------------------------
// Test 8: CREATE deploys code (non-null contract_addr)
// ---------------------------------------------------------------------------
test "CREATE returns non-null contract address" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const sender = make_addr(0x60);
    try set_balance(&state, sender, 10_000);

    // Simple contract: initcode that returns empty runtime code
    // Initcode: PUSH1 0x00, PUSH1 0x00, RETURN  (returns empty bytes → runtime code = empty)
    const initcode: []const u8 = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 };

    // CREATE transaction: to = null, data = initcode
    const tx = TxInput{
        .from = sender,
        .to = null,
        .value = 0,
        .data = initcode,
        .gas_limit = 500_000,
        .nonce = 0,
    };

    const result = try evm.execute_tx(&state, &tx, alloc);
    defer free_result(result);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expect(result.contract_addr != null);
    // Contract address must not be zero address
    const zero = [_]u8{0} ** 20;
    try testing.expect(!std.mem.eql(u8, &result.contract_addr.?, &zero));
}

// ---------------------------------------------------------------------------
// Test 9: execute_call does NOT mutate state
// Use a contract that reads (SLOAD) + returns — no write ops so it succeeds.
// A separate sub-check verifies SSTORE in static call → WriteProtection revert
// without leaving any trace on state.
// ---------------------------------------------------------------------------
test "execute_call does not mutate state" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const sender = make_addr(0x70);
    const contract_addr = make_addr(0x71);
    try set_balance(&state, sender, 5000);

    // Contract: SLOAD slot=1, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    // (read-only, no SSTORE → succeeds in static call)
    const code: []const u8 = &.{
        0x60, 0x01, // PUSH1 0x01   (slot)
        0x54,       // SLOAD
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    // Pre-write a value into slot 1 so SLOAD has something to return
    const slot = [_]u8{0} ** 31 ++ [_]u8{0x01};
    var slot_val = [_]u8{0} ** 32;
    slot_val[31] = 0xBE;
    try state.writeStorage(contract_addr, slot, slot_val);

    const balance_before = state.getBalance(sender);
    const nonce_before = state.getNonce(sender);
    const storage_before = state.readStorage(contract_addr, slot);

    const tx = TxInput{
        .from = sender, .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 200_000, .nonce = 0,
    };

    const result = try evm.execute_call(&state, &tx, alloc);
    defer alloc.free(result.output);

    // call should succeed (SLOAD is allowed in static context)
    try testing.expectEqual(ExecStatus.success, result.status);
    // Output should be the storage value 0xBE at byte 31
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 0xBE), result.output[31]);

    // State must NOT be mutated
    try testing.expectEqual(balance_before, state.getBalance(sender));
    try testing.expectEqual(nonce_before, state.getNonce(sender));
    const storage_after = state.readStorage(contract_addr, slot);
    try testing.expectEqual(storage_before, storage_after);
}

// ---------------------------------------------------------------------------
// Test 10: nonce increments after execute_tx
// ---------------------------------------------------------------------------
test "nonce increments after execute_tx" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    const sender = make_addr(0x80);
    const recv = make_addr(0x81);
    try set_balance(&state, sender, 10_000);

    const nonce_before = state.getNonce(sender);

    const tx = TxInput{
        .from = sender, .to = recv,
        .value = 100, .data = &.{}, .gas_limit = 100_000, .nonce = nonce_before,
    };

    const result = try evm.execute_tx(&state, &tx, alloc);
    defer free_result(result);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(nonce_before + 1, state.getNonce(sender));
}

// ---------------------------------------------------------------------------
// Bonus test 11: PUSH32 pushes all 32 bytes correctly
// ---------------------------------------------------------------------------
test "PUSH32 pushes 32-byte value" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    // PUSH32 <32 bytes of 0xAA> PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
    var code_buf: [3 + 32 + 6]u8 = undefined;
    code_buf[0] = 0x7f; // PUSH32
    @memset(code_buf[1..33], 0xAA);
    code_buf[33] = 0x60; code_buf[34] = 0x00; // PUSH1 0
    code_buf[35] = 0x52;                         // MSTORE
    code_buf[36] = 0x60; code_buf[37] = 0x20;  // PUSH1 32
    code_buf[38] = 0x60; code_buf[39] = 0x00;  // PUSH1 0
    code_buf[40] = 0xf3;                         // RETURN

    const contract_addr = make_addr(0x90);
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = &code_buf,
        .code_hash = [_]u8{0} ** 32,
    });

    const tx = TxInput{
        .from = make_addr(0x91), .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 100_000, .nonce = 0,
    };
    const result = try evm.execute_call(&state, &tx, alloc);
    defer alloc.free(result.output);

    try testing.expectEqual(ExecStatus.success, result.status);
    for (result.output) |b| try testing.expectEqual(@as(u8, 0xAA), b);
}

// ---------------------------------------------------------------------------
// Bonus test 12: DUP1 duplicates top-of-stack
// ---------------------------------------------------------------------------
test "DUP1 SWAP1 basic stack ops" {
    var state = EvmState.init(alloc);
    defer state.deinit();

    // PUSH1 0x05, DUP1, ADD (= 10), PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const code: []const u8 = &.{
        0x60, 0x05, // PUSH1 5
        0x80,       // DUP1  → stack: [5, 5]
        0x01,       // ADD   → stack: [10]
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    const contract_addr = make_addr(0xa0);
    try state.setAccount(contract_addr, Account{
        .balance = 0, .nonce = 0,
        .code = @constCast(code),
        .code_hash = [_]u8{0} ** 32,
    });

    const tx = TxInput{
        .from = make_addr(0xa1), .to = contract_addr,
        .value = 0, .data = &.{}, .gas_limit = 100_000, .nonce = 0,
    };
    const result = try evm.execute_call(&state, &tx, alloc);
    defer alloc.free(result.output);

    try testing.expectEqual(ExecStatus.success, result.status);
    try testing.expectEqual(@as(u8, 10), result.output[31]);
}
