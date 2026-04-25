//! omnibus-evm: thin C ABI wrapper over revm for Zig FFI.
//!
//! All exported `extern "C"` functions return `0` on success, `-1` on error.
//! Strings on the boundary are always null-terminated UTF-8 hex (lower-case,
//! optional `0x` prefix accepted, never produced).
//!
//! State is held in a process-wide `Mutex<InMemoryDB>` singleton because the
//! Zig RPC handlers are multi-threaded. This is intentionally simple — the
//! plan is to swap in a persistent backend once the FFI surface stabilises.

use alloy_primitives::{Address, Bytes, TxKind, U256};
use once_cell::sync::Lazy;
use revm::{
    db::InMemoryDB,
    primitives::{ExecutionResult, Output, TransactTo},
    Evm,
};
use std::ffi::{c_char, c_int, CStr};
use std::str::FromStr;
use std::sync::Mutex;

// ── Globals ──────────────────────────────────────────────────────────────────

static EVM_DB: Lazy<Mutex<InMemoryDB>> = Lazy::new(|| Mutex::new(InMemoryDB::default()));

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Read a null-terminated C string into a Rust `&str`.
/// Returns `None` if the pointer is null or the bytes are not valid UTF-8.
unsafe fn cstr_to_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

/// Strip optional `0x` / `0X` prefix.
fn strip_hex(s: &str) -> &str {
    s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")).unwrap_or(s)
}

fn parse_address(s: &str) -> Option<Address> {
    Address::from_str(s).ok()
}

fn parse_bytes(s: &str) -> Option<Vec<u8>> {
    hex::decode(strip_hex(s)).ok()
}

/// Write a hex string (no `0x`) into a caller buffer, null-terminated.
/// Returns `false` if the buffer is too small (need len+1 bytes).
unsafe fn write_hex(out: *mut c_char, out_len: usize, data: &[u8]) -> bool {
    if out.is_null() {
        return false;
    }
    let needed = data.len() * 2 + 1; // hex + NUL
    if out_len < needed {
        return false;
    }
    let s = hex::encode(data);
    let bytes = s.as_bytes();
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out, bytes.len());
    *out.add(bytes.len()) = 0;
    true
}

/// Write a `0x`-prefixed address into a caller buffer (43 bytes incl. NUL).
unsafe fn write_address(out: *mut c_char, out_len: usize, addr: &Address) -> bool {
    if out.is_null() || out_len < 43 {
        return false;
    }
    let s = format!("0x{:x}", addr); // 0x + 40 hex
    let bytes = s.as_bytes();
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out, bytes.len());
    *out.add(bytes.len()) = 0;
    true
}

// ── FFI: lifecycle ───────────────────────────────────────────────────────────

#[no_mangle]
pub extern "C" fn omnibus_evm_init() -> c_int {
    // Touch the lazy to fault it in.
    drop(EVM_DB.lock());
    0
}

#[no_mangle]
pub extern "C" fn omnibus_evm_shutdown() {
    // Reset the in-memory DB. Cannot drop the Lazy itself.
    if let Ok(mut g) = EVM_DB.lock() {
        *g = InMemoryDB::default();
    }
}

// ── FFI: deploy ──────────────────────────────────────────────────────────────

#[no_mangle]
pub unsafe extern "C" fn omnibus_evm_deploy(
    bytecode_hex: *const c_char,
    deployer_addr_hex: *const c_char,
    out_address: *mut c_char,
    out_address_len: usize,
) -> c_int {
    let Some(bc_s) = cstr_to_str(bytecode_hex) else { return -1 };
    let Some(dep_s) = cstr_to_str(deployer_addr_hex) else { return -1 };
    let Some(bytecode) = parse_bytes(bc_s) else { return -1 };
    let Some(deployer) = parse_address(dep_s) else { return -1 };

    let Ok(mut db) = EVM_DB.lock() else { return -1 };

    // Fund the deployer minimally so it can pay base gas during construction.
    // (Tests/RPC will preload balances explicitly via a future API; for now
    // we make sure deploys do not abort on insufficient funds.)
    {
        use revm::primitives::AccountInfo;
        let info = db
            .basic(deployer)
            .ok()
            .flatten()
            .unwrap_or_else(|| AccountInfo::default());
        if info.balance.is_zero() {
            let mut updated = info;
            updated.balance = U256::from(u128::MAX);
            db.insert_account_info(deployer, updated);
        }
    }

    let mut evm = Evm::builder()
        .with_db(&mut *db)
        .modify_tx_env(|tx| {
            tx.caller = deployer;
            tx.transact_to = TransactTo::Create;
            tx.data = Bytes::from(bytecode);
            tx.value = U256::ZERO;
            tx.gas_limit = 30_000_000;
            tx.gas_price = U256::ZERO;
        })
        .build();

    let result = match evm.transact_commit() {
        Ok(r) => r,
        Err(_) => return -1,
    };

    match result {
        ExecutionResult::Success { output: Output::Create(_, Some(addr)), .. } => {
            if write_address(out_address, out_address_len, &addr) { 0 } else { -1 }
        }
        _ => -1,
    }
}

// ── FFI: call ────────────────────────────────────────────────────────────────

#[no_mangle]
pub unsafe extern "C" fn omnibus_evm_call(
    contract_addr_hex: *const c_char,
    caller_addr_hex: *const c_char,
    input_hex: *const c_char,
    value_wei: u64,
    gas_limit: u64,
    out_result: *mut c_char,
    out_result_len: usize,
    out_gas_used: *mut u64,
) -> c_int {
    let Some(c_s) = cstr_to_str(contract_addr_hex) else { return -1 };
    let Some(f_s) = cstr_to_str(caller_addr_hex) else { return -1 };
    let Some(i_s) = cstr_to_str(input_hex) else { return -1 };
    let Some(contract) = parse_address(c_s) else { return -1 };
    let Some(caller) = parse_address(f_s) else { return -1 };
    let Some(input) = parse_bytes(i_s) else { return -1 };

    let Ok(mut db) = EVM_DB.lock() else { return -1 };

    let mut evm = Evm::builder()
        .with_db(&mut *db)
        .modify_tx_env(|tx| {
            tx.caller = caller;
            tx.transact_to = TransactTo::Call(contract);
            tx.data = Bytes::from(input);
            tx.value = U256::from(value_wei);
            tx.gas_limit = gas_limit;
            tx.gas_price = U256::ZERO;
        })
        .build();

    let result = match evm.transact_commit() {
        Ok(r) => r,
        Err(_) => return -1,
    };

    match result {
        ExecutionResult::Success { output, gas_used, .. } => {
            let bytes: Vec<u8> = match output {
                Output::Call(b) => b.to_vec(),
                Output::Create(b, _) => b.to_vec(),
            };
            if !out_gas_used.is_null() {
                *out_gas_used = gas_used;
            }
            if write_hex(out_result, out_result_len, &bytes) { 0 } else { -1 }
        }
        ExecutionResult::Revert { gas_used, output } => {
            if !out_gas_used.is_null() {
                *out_gas_used = gas_used;
            }
            // Still try to write the revert payload so the caller can decode it.
            let _ = write_hex(out_result, out_result_len, &output);
            -1
        }
        ExecutionResult::Halt { gas_used, .. } => {
            if !out_gas_used.is_null() {
                *out_gas_used = gas_used;
            }
            -1
        }
    }
}

// ── FFI: account queries ─────────────────────────────────────────────────────

#[no_mangle]
pub unsafe extern "C" fn omnibus_evm_get_balance(
    addr_hex: *const c_char,
    out_balance_hex: *mut c_char,
    out_balance_hex_len: usize,
) -> c_int {
    let Some(a_s) = cstr_to_str(addr_hex) else { return -1 };
    let Some(addr) = parse_address(a_s) else { return -1 };

    let Ok(mut db) = EVM_DB.lock() else { return -1 };
    let info = match db.basic(addr) {
        Ok(Some(i)) => i,
        Ok(None) => {
            // Treat unknown account as zero balance, matching EVM semantics.
            let s = format!("0x{:x}", U256::ZERO);
            return if write_string(out_balance_hex, out_balance_hex_len, &s) { 0 } else { -1 };
        }
        Err(_) => return -1,
    };

    let s = format!("0x{:x}", info.balance);
    if write_string(out_balance_hex, out_balance_hex_len, &s) { 0 } else { -1 }
}

#[no_mangle]
pub unsafe extern "C" fn omnibus_evm_get_code(
    addr_hex: *const c_char,
    out_code_hex: *mut c_char,
    out_code_hex_len: usize,
    out_code_actual_len: *mut usize,
) -> c_int {
    let Some(a_s) = cstr_to_str(addr_hex) else { return -1 };
    let Some(addr) = parse_address(a_s) else { return -1 };

    let Ok(mut db) = EVM_DB.lock() else { return -1 };

    let info = match db.basic(addr) {
        Ok(Some(i)) => i,
        Ok(None) => {
            if !out_code_actual_len.is_null() { *out_code_actual_len = 0; }
            // Empty hex string.
            if !out_code_hex.is_null() && out_code_hex_len > 0 { *out_code_hex = 0; }
            return 0;
        }
        Err(_) => return -1,
    };

    let bytes: Vec<u8> = if let Some(bc) = info.code {
        bc.bytes().to_vec()
    } else {
        // code may not be inlined; fetch by hash.
        match db.code_by_hash(info.code_hash) {
            Ok(bc) => bc.bytes().to_vec(),
            Err(_) => return -1,
        }
    };

    if !out_code_actual_len.is_null() {
        *out_code_actual_len = bytes.len();
    }
    if write_hex(out_code_hex, out_code_hex_len, &bytes) { 0 } else { -1 }
}

// ── FFI: gas estimate ────────────────────────────────────────────────────────

#[no_mangle]
pub unsafe extern "C" fn omnibus_evm_estimate_gas(
    from_hex: *const c_char,
    to_hex: *const c_char,
    input_hex: *const c_char,
    value_wei: u64,
    out_gas: *mut u64,
) -> c_int {
    let Some(f_s) = cstr_to_str(from_hex) else { return -1 };
    let Some(t_s) = cstr_to_str(to_hex) else { return -1 };
    let Some(i_s) = cstr_to_str(input_hex) else { return -1 };
    let Some(from) = parse_address(f_s) else { return -1 };
    let Some(input) = parse_bytes(i_s) else { return -1 };

    // `to_hex` may be empty (deploy estimate) — treat empty / "0x" as Create.
    let kind: TxKind = if t_s.is_empty() || strip_hex(t_s).is_empty() {
        TxKind::Create
    } else {
        match parse_address(t_s) {
            Some(addr) => TxKind::Call(addr),
            None => return -1,
        }
    };

    let Ok(mut db) = EVM_DB.lock() else { return -1 };

    let mut evm = Evm::builder()
        .with_db(&mut *db)
        .modify_tx_env(|tx| {
            tx.caller = from;
            tx.transact_to = match kind {
                TxKind::Call(a) => TransactTo::Call(a),
                TxKind::Create => TransactTo::Create,
            };
            tx.data = Bytes::from(input);
            tx.value = U256::from(value_wei);
            tx.gas_limit = 30_000_000;
            tx.gas_price = U256::ZERO;
        })
        .build();

    // `transact` does not commit state changes — perfect for estimation.
    let res = match evm.transact() {
        Ok(r) => r,
        Err(_) => return -1,
    };

    let gas = match res.result {
        ExecutionResult::Success { gas_used, .. } => gas_used,
        ExecutionResult::Revert { gas_used, .. } => gas_used,
        ExecutionResult::Halt { gas_used, .. } => gas_used,
    };
    if !out_gas.is_null() {
        *out_gas = gas;
    }
    0
}

// ── small string helper (for human-readable hex with 0x prefix) ─────────────

unsafe fn write_string(out: *mut c_char, out_len: usize, s: &str) -> bool {
    if out.is_null() {
        return false;
    }
    let bytes = s.as_bytes();
    if out_len < bytes.len() + 1 {
        return false;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out, bytes.len());
    *out.add(bytes.len()) = 0;
    true
}

// ── DatabaseRef bring-in for InMemoryDB ──────────────────────────────────────
// `InMemoryDB::basic` / `code_by_hash` come from the `Database` trait.
use revm::Database;
