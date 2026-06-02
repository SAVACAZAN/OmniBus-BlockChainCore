// core/evm/mod.zig — Single import point for the OmniBus Zig EVM
//
// Usage:
//   const evm = @import("evm/mod.zig");
//   var state = evm.EvmState.init(allocator);
//   const result = try evm.execute_tx(&state, &tx, allocator);

pub const types = @import("types.zig");
pub const state = @import("state.zig");
pub const executor = @import("executor.zig");
pub const interpreter = @import("interpreter.zig");

// Flat re-exports for convenience (mirrors interface.rs)
pub const ExecStatus = types.ExecStatus;
pub const ExecResult = types.ExecResult;
pub const CallResult = types.CallResult;
pub const TxInput = types.TxInput;
pub const Log = types.Log;
pub const U256 = types.U256;
pub const Address = types.Address;

pub const EvmState = state.EvmState;
pub const Account = state.Account;

pub const execute_call = executor.execute_call;
pub const execute_tx = executor.execute_tx;
