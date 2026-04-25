//! Raw FFI bindings to the omnibus-evm Rust static library.
//!
//! All hex strings on the boundary are null-terminated UTF-8. Functions return
//! `0` on success, `-1` on error (revert / parse failure / buffer too small).
//! Buffers must be caller-allocated; callers should size them generously and
//! check for the trailing NUL before using the returned hex.

pub extern "c" fn omnibus_evm_init() c_int;

pub extern "c" fn omnibus_evm_deploy(
    bytecode_hex: [*:0]const u8,
    deployer_addr_hex: [*:0]const u8,
    out_address: [*]u8,
    out_address_len: usize,
) c_int;

pub extern "c" fn omnibus_evm_call(
    contract_addr_hex: [*:0]const u8,
    caller_addr_hex: [*:0]const u8,
    input_hex: [*:0]const u8,
    value_wei: u64,
    gas_limit: u64,
    out_result: [*]u8,
    out_result_len: usize,
    out_gas_used: *u64,
) c_int;

pub extern "c" fn omnibus_evm_get_balance(
    addr_hex: [*:0]const u8,
    out_balance_hex: [*]u8,
    out_balance_hex_len: usize,
) c_int;

pub extern "c" fn omnibus_evm_get_code(
    addr_hex: [*:0]const u8,
    out_code_hex: [*]u8,
    out_code_hex_len: usize,
    out_code_actual_len: *usize,
) c_int;

pub extern "c" fn omnibus_evm_estimate_gas(
    from_hex: [*:0]const u8,
    to_hex: [*:0]const u8,
    input_hex: [*:0]const u8,
    value_wei: u64,
    out_gas: *u64,
) c_int;

pub extern "c" fn omnibus_evm_shutdown() void;

