//! Safe Zig wrapper over the raw FFI exposed by `evm_ffi.zig`.
//!
//! The raw FFI returns `0` on success / `-1` on error and operates on
//! null-terminated UTF-8 hex strings. This module:
//!   * dupes Zig slices into NUL-terminated buffers expected by the C ABI;
//!   * translates `-1` into structured `EvmError` values;
//!   * trims trailing NULs from output buffers and returns Zig slices.
//!
//! Lifecycle: call `init()` once at startup and `shutdown()` on graceful exit.
//! Every other entry point is callable from any thread; concurrency control
//! lives inside the Rust side.

const std = @import("std");
const ffi = @import("evm_ffi.zig");

pub const EvmError = error{
    NotInitialized,
    Reverted,
    InvalidInput,
    OutOfGas,
    BufferTooSmall,
    FFIError,
    OutOfMemory,
};

pub const DeployResult = struct {
    /// "0x" + 40 hex chars (NUL-padded inside the array).
    contract_address: [42]u8,
    gas_used: u64,
};

pub const CallResult = struct {
    /// Hex-encoded return data ("0x..." or empty). Owned by `allocator`.
    return_data: []u8,
    gas_used: u64,

    pub fn deinit(self: *CallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.return_data);
        self.return_data = &.{};
    }
};

/// Initializes the revm engine. Must be called exactly once before any other
/// entry point. Returns `error.FFIError` if the Rust side fails (already
/// initialized, OOM in revm, etc.).
pub fn init() EvmError!void {
    if (ffi.omnibus_evm_init() != 0) return error.FFIError;
}

/// Shuts the revm engine down. Idempotent on the Zig side.
pub fn shutdown() void {
    ffi.omnibus_evm_shutdown();
}

/// Deploys `bytecode_hex` from `deployer_addr`. Both inputs are expected to
/// be hex strings ("0x..." or bare hex). Returns the contract address.
pub fn deploy(
    allocator: std.mem.Allocator,
    bytecode_hex: []const u8,
    deployer_addr: []const u8,
) EvmError!DeployResult {
    const bc_z = allocator.dupeZ(u8, bytecode_hex) catch return error.OutOfMemory;
    defer allocator.free(bc_z);
    const da_z = allocator.dupeZ(u8, deployer_addr) catch return error.OutOfMemory;
    defer allocator.free(da_z);

    var out_addr: [42]u8 = undefined;
    @memset(&out_addr, 0);
    const rc = ffi.omnibus_evm_deploy(bc_z.ptr, da_z.ptr, &out_addr, out_addr.len);
    if (rc != 0) return error.FFIError;
    return DeployResult{ .contract_address = out_addr, .gas_used = 0 };
}

/// Executes a call into `contract_addr` originated from `caller_addr` with
/// `input_hex` calldata. Returns hex-encoded output (without "0x" if the Rust
/// side omits it, but typically with it).
pub fn call(
    allocator: std.mem.Allocator,
    contract_addr: []const u8,
    caller_addr: []const u8,
    input_hex: []const u8,
    value_wei: u64,
    gas_limit: u64,
) EvmError!CallResult {
    const ca_z = allocator.dupeZ(u8, contract_addr) catch return error.OutOfMemory;
    defer allocator.free(ca_z);
    const cl_z = allocator.dupeZ(u8, caller_addr) catch return error.OutOfMemory;
    defer allocator.free(cl_z);
    const in_z = allocator.dupeZ(u8, input_hex) catch return error.OutOfMemory;
    defer allocator.free(in_z);

    const buf_size: usize = 65_536; // 64 KiB max return data
    var out_buf = allocator.alloc(u8, buf_size) catch return error.OutOfMemory;
    errdefer allocator.free(out_buf);
    @memset(out_buf, 0);
    var gas_used: u64 = 0;

    const rc = ffi.omnibus_evm_call(
        ca_z.ptr,
        cl_z.ptr,
        in_z.ptr,
        value_wei,
        gas_limit,
        out_buf.ptr,
        buf_size,
        &gas_used,
    );
    if (rc != 0) {
        allocator.free(out_buf);
        return error.Reverted;
    }

    // out_buf is NUL-terminated by the Rust side; trim to actual length.
    const len = std.mem.indexOfScalar(u8, out_buf, 0) orelse buf_size;
    // Shrink to fit so callers don't carry a 64 KiB allocation around.
    const tight = allocator.realloc(out_buf, len) catch out_buf[0..len];
    return CallResult{ .return_data = tight, .gas_used = gas_used };
}

/// Returns the balance of `addr` as a hex-encoded u256 (e.g. "0x1bc16d674ec80000").
/// Caller owns the returned slice.
pub fn getBalance(allocator: std.mem.Allocator, addr: []const u8) EvmError![]u8 {
    const a_z = allocator.dupeZ(u8, addr) catch return error.OutOfMemory;
    defer allocator.free(a_z);
    var buf: [80]u8 = undefined; // u256 hex is at most 66 chars including "0x"
    @memset(&buf, 0);
    const rc = ffi.omnibus_evm_get_balance(a_z.ptr, &buf, buf.len);
    if (rc != 0) return error.FFIError;
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    return allocator.dupe(u8, buf[0..len]) catch return error.OutOfMemory;
}

/// Returns the deployed bytecode at `addr` as hex (caller owns the slice).
/// Empty string ("") if the account has no code.
pub fn getCode(allocator: std.mem.Allocator, addr: []const u8) EvmError![]u8 {
    const a_z = allocator.dupeZ(u8, addr) catch return error.OutOfMemory;
    defer allocator.free(a_z);
    var buf = allocator.alloc(u8, 65_536) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var actual_len: usize = 0;
    const rc = ffi.omnibus_evm_get_code(a_z.ptr, buf.ptr, buf.len, &actual_len);
    if (rc != 0) {
        allocator.free(buf);
        return error.FFIError;
    }
    if (actual_len > buf.len) actual_len = buf.len;
    const tight = allocator.realloc(buf, actual_len) catch buf[0..actual_len];
    return tight;
}

/// Estimates the gas required for a transaction without actually mutating
/// state. `value_wei` is the ether value forwarded in the call.
pub fn estimateGas(
    allocator: std.mem.Allocator,
    from_addr: []const u8,
    to_addr: []const u8,
    input_hex: []const u8,
    value_wei: u64,
) EvmError!u64 {
    const f_z = allocator.dupeZ(u8, from_addr) catch return error.OutOfMemory;
    defer allocator.free(f_z);
    const t_z = allocator.dupeZ(u8, to_addr) catch return error.OutOfMemory;
    defer allocator.free(t_z);
    const i_z = allocator.dupeZ(u8, input_hex) catch return error.OutOfMemory;
    defer allocator.free(i_z);

    var gas: u64 = 0;
    const rc = ffi.omnibus_evm_estimate_gas(f_z.ptr, t_z.ptr, i_z.ptr, value_wei, &gas);
    if (rc != 0) return error.FFIError;
    return gas;
}

// ─── Price Oracle Precompile (TODO) ─────────────────────────────────────────
//
// Solidity-compatible read endpoint at the magic precompile address
// `0x00000000000000000000000000000000000001ee` (1ee = "price oracle"). Calling
// this address from a contract should return the current per-pair / per-
// exchange bid/ask snapshot encoded as ABI uint256 fields.
//
// Proposed calldata layout (single uint256 input, packed):
//   bytes 0..30 : 0
//   byte  31    : (pair_index << 2) | exchange_index
//                  pair_index    in 0..6 (BTC/USD, ETH/USD, ..., LCX/USD)
//                  exchange_index in 0..2 (Coinbase, Kraken, LCX)
//
// Proposed return data: a single ABI-encoded `(uint256 bid_micro_usd,
// uint256 ask_micro_usd, uint256 timestamp_ms, uint256 success_flag)`.
//
// Implementing this requires hooking into the revm executor on the Rust
// side (a custom precompile registered at address 0x...01ee that calls back
// into Zig to read from `g_ws_feed.snapshot()` or the latest block's prices).
// That work belongs to the EVM bridge agent — for now the on-chain
// `Block.prices` array (queried via `omnibus_getblockprices`) is the
// authoritative read path, so this stub is intentionally a no-op.
pub const PRICE_ORACLE_PRECOMPILE_ADDR: [42]u8 =
    "0x00000000000000000000000000000000000001ee".*;

