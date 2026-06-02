//! Canonical EVM interface — single import point for all callers
//! (block_exec.rs, rpc/eth_methods.rs, etc.).
//!
//! Design goal: when the Zig EVM port is ready, swap the re-export target from
//! `crate::evm::executor` to `crate::evm::zig_executor` and nothing else
//! changes.
//!
//! Zig equivalent signatures (for the porter):
//!   pub fn execute_call(state: *const EvmState, tx: *const TxParsed) ExecResult
//!   pub fn execute_tx(state: *EvmState, tx: *const TxParsed) ExecResult
//!
//! See docs/ZIG_EVM_OPCODES.md for the full opcode reference.

// These re-exports are intentionally public API for future callers.
#![allow(unused_imports)]

// Read-only execution — used by eth_call / eth_estimateGas.
// Must NOT mutate any state. Safe to call concurrently.
pub use crate::evm::executor::execute_call;

// State-mutating execution — used by eth_sendRawTransaction.
// Commits account / code / storage changes atomically.
pub use crate::evm::executor::execute_tx;

// Discriminated result of any EVM execution.
pub use crate::evm::executor::ExecResult;

// Lighter result returned by execute_call (no logs, no contract_addr).
pub use crate::evm::executor::CallResult;

// Execution outcome discriminant.
pub use crate::evm::executor::ExecStatus;

// ---------------------------------------------------------------------------
// Zig EVM Port Checklist
// ---------------------------------------------------------------------------
//
// When implementing the Zig EVM, every item below must be verified against
// the test suite in evm/tests.rs before swapping this re-export.
//
// [ ] Stack
//     - 256-bit words (U256), big-endian internally
//     - Max depth: 1024 items; push beyond 1024 → StackOverflow halt
//
// [ ] Memory
//     - Byte-addressable, dynamic, always zero-initialised
//     - Expand in 32-byte word increments (MSIZE rounds up)
//     - Gas cost: linear + quadratic per EIP-150
//
// [ ] Storage
//     - Persistent key-value: [u8;32] → [u8;32]
//     - Backed by EvmState::read_storage_slot / write_storage_slot
//     - EIP-2929 cold/warm accounting:
//         cold SLOAD  = 2100 gas
//         warm SLOAD  = 100 gas
//         cold SSTORE = 20000 (new) / 2900 (dirty) gas + 100 warm access
//
// [ ] Opcodes: 150+ — see docs/ZIG_EVM_OPCODES.md
//
// [ ] Gas accounting
//     - EIP-1559 base-fee model (intrinsic 21 000 for plain transfers)
//     - EIP-2929 cold/warm storage
//     - Memory expansion quadratic schedule
//     - CALL stipend: 2300 gas forwarded when value > 0
//
// [ ] Call variants
//     - CALL         — external call, new context, can transfer value
//     - DELEGATECALL — inherited storage + caller, no value
//     - STATICCALL   — read-only sub-context (SSTORE forbidden)
//     - CALLCODE     — deprecated but must not panic
//     - CREATE       — deploys a new contract at keccak256(rlp(sender,nonce))
//     - CREATE2      — deploys at keccak256(0xff ++ sender ++ salt ++ keccak256(initcode))
//
// [ ] Precompiles (addresses 0x01–0x09)
//     0x01 ecRecover       — ECDSA pubkey recovery (secp256k1)
//     0x02 SHA2-256        — sha2::Sha256
//     0x03 RIPEMD-160      — ripemd::Ripemd160
//     0x04 identity        — copy input to output
//     0x05 modexp          — big-integer modular exponentiation (EIP-198)
//     0x06 ecAdd           — BN254 G1 addition (EIP-196)
//     0x07 ecMul           — BN254 G1 scalar multiplication (EIP-196)
//     0x08 ecPairing       — BN254 pairing check (EIP-197)
//     0x09 blake2f         — BLAKE2b-F compression (EIP-152)
//
// [ ] Chain constants
//     chain_id = 7771     (CHAINID opcode must return this)
//
// [ ] Error / halt conditions
//     - OutOfGas
//     - StackOverflow / StackUnderflow
//     - InvalidOpcode
//     - InvalidJump
//     - WriteProtection (SSTORE inside STATICCALL)
//
// [ ] ExecResult mapping
//     ExecutionResult::Success  → ExecStatus::Success
//     ExecutionResult::Revert   → ExecStatus::Revert
//     ExecutionResult::Halt     → ExecStatus::Halt
