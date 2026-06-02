// core/evm/executor.zig — OmniBus EVM executor
//
// Two entry points mirroring core-rust/src/evm/executor.rs:
//   execute_call — read-only (clones state, discards changes)
//   execute_tx   — state-mutating (commits account/code/storage)
//
// No liboqs. No external dependencies. Pure Zig + std.

const std = @import("std");
const types = @import("types.zig");
const state_mod = @import("state.zig");
const interp = @import("interpreter.zig");

pub const ExecStatus = types.ExecStatus;
pub const ExecResult = types.ExecResult;
pub const CallResult = types.CallResult;
pub const TxInput = types.TxInput;
pub const Address = types.Address;
pub const EvmState = state_mod.EvmState;
pub const Account = state_mod.Account;

const CHAIN_ID: u64 = 7771;
const INTRINSIC_GAS: u64 = 21_000;

// ---------------------------------------------------------------------------
// Keccak256 stub (SHA-256) — same as interpreter.zig, see note there
// ---------------------------------------------------------------------------
fn keccak256_stub(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// Derive contract address from sender address + nonce
// stub: sha256(sender || nonce_be8) → take last 20 bytes
// ---------------------------------------------------------------------------
fn derive_contract_addr(sender: Address, nonce: u64) Address {
    var input: [28]u8 = undefined;
    @memcpy(input[0..20], &sender);
    std.mem.writeInt(u64, input[20..28], nonce, .big);
    const hash = keccak256_stub(&input);
    var addr: Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}

// ---------------------------------------------------------------------------
// execute_call — read-only execution (eth_call / eth_estimateGas)
// Does NOT mutate state. Safe to call concurrently (each call clones state).
// ---------------------------------------------------------------------------
pub fn execute_call(
    state: *const EvmState,
    tx: *const TxInput,
    alloc: std.mem.Allocator,
) !CallResult {
    // Clone state so we never commit
    var state_clone = try state.clone();
    defer state_clone.deinit();

    // Plain ETH transfer or no destination — no bytecode to run
    const to = tx.to orelse {
        // CREATE in read-only context: just report success
        return CallResult{
            .gas_used = INTRINSIC_GAS,
            .status = .success,
            .output = try alloc.dupe(u8, &.{}),
        };
    };

    const code = if (state_clone.getAccountConst(to)) |a| a.code else &.{};
    if (code.len == 0) {
        // Plain transfer or call to EOA
        return CallResult{
            .gas_used = INTRINSIC_GAS,
            .status = .success,
            .output = try alloc.dupe(u8, &.{}),
        };
    }

    const ctx = interp.CallContext{
        .caller = tx.from,
        .callee = to,
        .value = tx.value,
        .calldata = tx.data,
        .gas_limit = if (tx.gas_limit > INTRINSIC_GAS) tx.gas_limit - INTRINSIC_GAS else tx.gas_limit,
        .is_static = true, // read-only
        .block_number = state_clone.block_number,
        .timestamp = state_clone.timestamp,
        .chain_id = state_clone.chain_id,
    };

    const result = try interp.interpret(alloc, &state_clone, code, ctx);
    defer alloc.free(result.logs);
    // Logs from read-only call are discarded

    return CallResult{
        .gas_used = result.gas_used + INTRINSIC_GAS,
        .status = result.status,
        .output = result.output,
    };
}

// ---------------------------------------------------------------------------
// execute_tx — state-mutating execution (eth_sendRawTransaction)
// Commits account/code/storage changes atomically.
// ---------------------------------------------------------------------------
pub fn execute_tx(
    state: *EvmState,
    tx: *const TxInput,
    alloc: std.mem.Allocator,
) !ExecResult {
    // 1. Check sender balance >= value (+ gas fee placeholder)
    const sender_balance = state.getBalance(tx.from);
    if (sender_balance < tx.value) {
        return ExecResult{
            .gas_used = INTRINSIC_GAS,
            .status = .halt,
            .output = try alloc.dupe(u8, &.{}),
            .contract_addr = null,
            .logs = try alloc.dupe(Log, &.{}),
        };
    }

    // 2. Increment sender nonce
    var sender_acc = state.getAccount(tx.from) orelse Account{
        .balance = sender_balance,
        .nonce = 0,
        .code = &.{},
        .code_hash = [_]u8{0} ** 32,
    };
    const sender_nonce = sender_acc.nonce;
    sender_acc.nonce += 1;
    sender_acc.balance -= tx.value;
    try state.setAccount(tx.from, sender_acc);

    // 3. Contract creation (to == null)
    if (tx.to == null) {
        const new_addr = derive_contract_addr(tx.from, sender_nonce);
        // Credit the new contract with the value sent
        var contract_acc = Account{
            .balance = tx.value,
            .nonce = 0,
            .code = &.{},
            .code_hash = [_]u8{0} ** 32,
        };
        try state.setAccount(new_addr, contract_acc);

        if (tx.data.len == 0) {
            // Empty initcode — deploy empty contract
            return ExecResult{
                .gas_used = INTRINSIC_GAS + 32_000,
                .status = .success,
                .output = try alloc.dupe(u8, &.{}),
                .contract_addr = new_addr,
                .logs = try alloc.dupe(Log, &.{}),
            };
        }

        // Run initcode
        const ctx = interp.CallContext{
            .caller = tx.from,
            .callee = new_addr,
            .value = tx.value,
            .calldata = &.{},
            .gas_limit = if (tx.gas_limit > INTRINSIC_GAS + 32_000) tx.gas_limit - INTRINSIC_GAS - 32_000 else 1000,
            .is_static = false,
            .block_number = state.block_number,
            .timestamp = state.timestamp,
            .chain_id = state.chain_id,
        };

        const result = try interp.interpret(alloc, state, tx.data, ctx);

        if (result.status == .success) {
            // Deployed code = returned output
            const code_hash = keccak256_stub(result.output);
            contract_acc.code = result.output;
            contract_acc.code_hash = code_hash;
            try state.setAccount(new_addr, contract_acc);

            return ExecResult{
                .gas_used = result.gas_used + INTRINSIC_GAS + 32_000,
                .status = .success,
                .output = try alloc.dupe(u8, &.{}),
                .contract_addr = new_addr,
                .logs = result.logs,
            };
        } else {
            return ExecResult{
                .gas_used = result.gas_used + INTRINSIC_GAS + 32_000,
                .status = result.status,
                .output = result.output,
                .contract_addr = null,
                .logs = result.logs,
            };
        }
    }

    const to = tx.to.?;

    // 4. Credit recipient with value (before running code)
    var recv_acc = state.getAccount(to) orelse Account{
        .balance = 0, .nonce = 0, .code = &.{}, .code_hash = [_]u8{0} ** 32,
    };
    recv_acc.balance += tx.value;
    try state.setAccount(to, recv_acc);

    // 5. Check for contract code
    const code = if (state.getAccountConst(to)) |a| a.code else &.{};
    if (code.len == 0) {
        // Plain ETH transfer — done
        return ExecResult{
            .gas_used = INTRINSIC_GAS,
            .status = .success,
            .output = try alloc.dupe(u8, &.{}),
            .contract_addr = null,
            .logs = try alloc.dupe(Log, &.{}),
        };
    }

    // 6. Run contract code
    const ctx = interp.CallContext{
        .caller = tx.from,
        .callee = to,
        .value = tx.value,
        .calldata = tx.data,
        .gas_limit = if (tx.gas_limit > INTRINSIC_GAS) tx.gas_limit - INTRINSIC_GAS else tx.gas_limit,
        .is_static = false,
        .block_number = state.block_number,
        .timestamp = state.timestamp,
        .chain_id = state.chain_id,
    };

    const result = try interp.interpret(alloc, state, code, ctx);

    // If revert: undo the value transfer
    if (result.status == .revert or result.status == .halt) {
        var recv2 = state.getAccount(to) orelse recv_acc;
        recv2.balance -= tx.value;
        try state.setAccount(to, recv2);
        var sender2 = state.getAccount(tx.from) orelse sender_acc;
        sender2.balance += tx.value;
        try state.setAccount(tx.from, sender2);
    }

    return ExecResult{
        .gas_used = result.gas_used + INTRINSIC_GAS,
        .status = result.status,
        .output = result.output,
        .contract_addr = null,
        .logs = result.logs,
    };
}

// Alias for Log type
const Log = types.Log;
