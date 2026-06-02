//! evm_executor.rs — Safe wrapper over the EVM engine (revm FFI).
//!
//! Port of `core/bridge/evm_executor.zig` (219 lines).
//!
//! The Zig original wraps `evm_ffi.zig` (raw `extern "c"` declarations) and:
//!   - dupes Zig slices into NUL-terminated buffers expected by the C ABI;
//!   - translates `-1` return codes into structured error values;
//!   - trims trailing NULs from output buffers and returns Zig slices.
//!
//! This Rust port provides the same surface.  The real EVM engine is the
//! `revm`-based Rust crate that lives under `evm/` in the BlockChainCore tree
//! and exposes a C-compatible shared library.  When the `evm` feature flag is
//! enabled at compile time, calls go through `extern "C"` FFI.  When the flag
//! is disabled (e.g. on VPS nodes that only have the Zig side), every method
//! returns [`EvmError::NotInitialized`] — same semantics as `-Devm=false` in
//! the Zig build.
//!
//! Lifecycle: call [`init`] once at startup and [`shutdown`] on graceful exit.
//! All other entry points are callable from any thread; concurrency control
//! lives inside the Rust EVM side.

use std::ffi::CString;

// ─── EVM feature gate ─────────────────────────────────────────────────────────
//
// When the `evm` Cargo feature is absent we compile everything but every
// function returns `Err(EvmError::NotInitialized)` without touching FFI.
// This mirrors the Zig `evm_enabled: bool` comptime guard.

#[cfg(feature = "evm")]
mod ffi {
    extern "C" {
        pub fn omnibus_evm_init() -> i32;
        pub fn omnibus_evm_shutdown();
        pub fn omnibus_evm_deploy(
            bytecode_hex: *const u8,
            deployer_addr: *const u8,
            out_addr: *mut u8,
            out_addr_len: usize,
        ) -> i32;
        pub fn omnibus_evm_call(
            contract_addr: *const u8,
            caller_addr: *const u8,
            input_hex: *const u8,
            value_wei: u64,
            gas_limit: u64,
            out_buf: *mut u8,
            out_buf_len: usize,
            gas_used_out: *mut u64,
        ) -> i32;
        pub fn omnibus_evm_get_balance(
            addr: *const u8,
            out_buf: *mut u8,
            out_len: usize,
        ) -> i32;
        pub fn omnibus_evm_get_code(
            addr: *const u8,
            out_buf: *mut u8,
            out_len: usize,
            actual_len_out: *mut usize,
        ) -> i32;
        pub fn omnibus_evm_estimate_gas(
            from_addr: *const u8,
            to_addr: *const u8,
            input_hex: *const u8,
            value_wei: u64,
            gas_out: *mut u64,
        ) -> i32;
    }
}

// ─── Errors ───────────────────────────────────────────────────────────────────

/// Structured errors returned by every EVM entry point.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EvmError {
    /// EVM engine has not been initialized (either `init()` not called, or
    /// compiled without the `evm` feature).
    NotInitialized,
    /// The transaction was reverted by the EVM.
    Reverted,
    /// Caller passed invalid hex or address strings.
    InvalidInput,
    /// Transaction ran out of gas.
    OutOfGas,
    /// Output buffer too small (internal — callers never see this with the
    /// fixed 64 KiB output buffers we pre-allocate).
    BufferTooSmall,
    /// Unclassified FFI error.
    FfiError,
    /// OOM while constructing NUL-terminated strings.
    OutOfMemory,
}

impl std::fmt::Display for EvmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for EvmError {}

// ─── Result types ─────────────────────────────────────────────────────────────

/// Returned by [`deploy`].
#[derive(Debug, Clone)]
pub struct DeployResult {
    /// "0x" + 40 hex chars.
    pub contract_address: String,
    pub gas_used: u64,
}

/// Returned by [`call`].
#[derive(Debug, Clone)]
pub struct CallResult {
    /// Hex-encoded return data (typically "0x...").
    pub return_data: String,
    pub gas_used: u64,
}

/// Reserved address for the future in-EVM price oracle precompile.
/// Mirrors Zig `PRICE_ORACLE_PRECOMPILE_ADDR`.
pub const PRICE_ORACLE_PRECOMPILE_ADDR: &str =
    "0x00000000000000000000000000000000000001ee";

// ─── Lifecycle ────────────────────────────────────────────────────────────────

/// Initialize the revm engine.  Must be called exactly once before any other
/// entry point.  Idempotent on the Zig/Rust side if called twice.
pub fn init() -> Result<(), EvmError> {
    #[cfg(feature = "evm")]
    {
        let rc = unsafe { ffi::omnibus_evm_init() };
        if rc != 0 {
            return Err(EvmError::FfiError);
        }
        return Ok(());
    }
    #[cfg(not(feature = "evm"))]
    {
        Ok(()) // no-op when EVM compiled out
    }
}

/// Shut down the revm engine.  Idempotent.
pub fn shutdown() {
    #[cfg(feature = "evm")]
    unsafe {
        ffi::omnibus_evm_shutdown();
    }
}

// ─── Deploy ───────────────────────────────────────────────────────────────────

/// Deploy `bytecode_hex` from `deployer_addr`.  Both inputs are hex strings
/// (`"0x..."` or bare hex).  Returns the newly created contract address.
pub fn deploy(bytecode_hex: &str, deployer_addr: &str) -> Result<DeployResult, EvmError> {
    #[cfg(not(feature = "evm"))]
    {
        let _ = (bytecode_hex, deployer_addr);
        return Err(EvmError::NotInitialized);
    }
    #[cfg(feature = "evm")]
    {
        let bc_z = CString::new(bytecode_hex).map_err(|_| EvmError::InvalidInput)?;
        let da_z = CString::new(deployer_addr).map_err(|_| EvmError::InvalidInput)?;
        let mut out_addr = [0u8; 42];
        let rc = unsafe {
            ffi::omnibus_evm_deploy(
                bc_z.as_ptr() as *const u8,
                da_z.as_ptr() as *const u8,
                out_addr.as_mut_ptr(),
                out_addr.len(),
            )
        };
        if rc != 0 {
            return Err(EvmError::FfiError);
        }
        let len = out_addr.iter().position(|&b| b == 0).unwrap_or(42);
        let addr = std::str::from_utf8(&out_addr[..len])
            .map_err(|_| EvmError::FfiError)?
            .to_owned();
        Ok(DeployResult { contract_address: addr, gas_used: 0 })
    }
}

// ─── Call ─────────────────────────────────────────────────────────────────────

/// Execute a call into `contract_addr` originated from `caller_addr` with
/// `input_hex` calldata.  Returns hex-encoded return data.
pub fn call(
    contract_addr: &str,
    caller_addr: &str,
    input_hex: &str,
    value_wei: u64,
    gas_limit: u64,
) -> Result<CallResult, EvmError> {
    #[cfg(not(feature = "evm"))]
    {
        let _ = (contract_addr, caller_addr, input_hex, value_wei, gas_limit);
        return Err(EvmError::NotInitialized);
    }
    #[cfg(feature = "evm")]
    {
        let ca_z = CString::new(contract_addr).map_err(|_| EvmError::InvalidInput)?;
        let cl_z = CString::new(caller_addr).map_err(|_| EvmError::InvalidInput)?;
        let in_z = CString::new(input_hex).map_err(|_| EvmError::InvalidInput)?;

        const BUF_SIZE: usize = 65_536;
        let mut out_buf = vec![0u8; BUF_SIZE];
        let mut gas_used: u64 = 0;

        let rc = unsafe {
            ffi::omnibus_evm_call(
                ca_z.as_ptr() as *const u8,
                cl_z.as_ptr() as *const u8,
                in_z.as_ptr() as *const u8,
                value_wei,
                gas_limit,
                out_buf.as_mut_ptr(),
                BUF_SIZE,
                &mut gas_used,
            )
        };
        if rc != 0 {
            return Err(EvmError::Reverted);
        }

        let len = out_buf.iter().position(|&b| b == 0).unwrap_or(BUF_SIZE);
        let data = std::str::from_utf8(&out_buf[..len])
            .map_err(|_| EvmError::FfiError)?
            .to_owned();
        Ok(CallResult { return_data: data, gas_used })
    }
}

// ─── getBalance ───────────────────────────────────────────────────────────────

/// Returns the balance of `addr` as a hex-encoded u256 (e.g.
/// `"0x1bc16d674ec80000"`).
pub fn get_balance(addr: &str) -> Result<String, EvmError> {
    #[cfg(not(feature = "evm"))]
    {
        let _ = addr;
        return Err(EvmError::NotInitialized);
    }
    #[cfg(feature = "evm")]
    {
        let a_z = CString::new(addr).map_err(|_| EvmError::InvalidInput)?;
        let mut buf = [0u8; 80]; // u256 hex is ≤ 66 chars including "0x"
        let rc = unsafe {
            ffi::omnibus_evm_get_balance(a_z.as_ptr() as *const u8, buf.as_mut_ptr(), buf.len())
        };
        if rc != 0 {
            return Err(EvmError::FfiError);
        }
        let len = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
        Ok(std::str::from_utf8(&buf[..len])
            .map_err(|_| EvmError::FfiError)?
            .to_owned())
    }
}

// ─── getCode ──────────────────────────────────────────────────────────────────

/// Returns the deployed bytecode at `addr` as hex.  Empty string if no code.
pub fn get_code(addr: &str) -> Result<String, EvmError> {
    #[cfg(not(feature = "evm"))]
    {
        let _ = addr;
        return Err(EvmError::NotInitialized);
    }
    #[cfg(feature = "evm")]
    {
        let a_z = CString::new(addr).map_err(|_| EvmError::InvalidInput)?;
        const BUF_SIZE: usize = 65_536;
        let mut buf = vec![0u8; BUF_SIZE];
        let mut actual_len: usize = 0;
        let rc = unsafe {
            ffi::omnibus_evm_get_code(
                a_z.as_ptr() as *const u8,
                buf.as_mut_ptr(),
                BUF_SIZE,
                &mut actual_len,
            )
        };
        if rc != 0 {
            return Err(EvmError::FfiError);
        }
        let len = actual_len.min(BUF_SIZE);
        Ok(std::str::from_utf8(&buf[..len])
            .map_err(|_| EvmError::FfiError)?
            .to_owned())
    }
}

// ─── estimateGas ─────────────────────────────────────────────────────────────

/// Estimate the gas required for a transaction without mutating state.
pub fn estimate_gas(
    from_addr: &str,
    to_addr: &str,
    input_hex: &str,
    value_wei: u64,
) -> Result<u64, EvmError> {
    #[cfg(not(feature = "evm"))]
    {
        let _ = (from_addr, to_addr, input_hex, value_wei);
        return Err(EvmError::NotInitialized);
    }
    #[cfg(feature = "evm")]
    {
        let f_z = CString::new(from_addr).map_err(|_| EvmError::InvalidInput)?;
        let t_z = CString::new(to_addr).map_err(|_| EvmError::InvalidInput)?;
        let i_z = CString::new(input_hex).map_err(|_| EvmError::InvalidInput)?;
        let mut gas: u64 = 0;
        let rc = unsafe {
            ffi::omnibus_evm_estimate_gas(
                f_z.as_ptr() as *const u8,
                t_z.as_ptr() as *const u8,
                i_z.as_ptr() as *const u8,
                value_wei,
                &mut gas,
            )
        };
        if rc != 0 {
            return Err(EvmError::FfiError);
        }
        Ok(gas)
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Without the `evm` feature every call should return `NotInitialized` (or
    /// `Ok(())` for lifecycle no-ops).
    #[test]
    #[cfg(not(feature = "evm"))]
    fn without_evm_feature_init_is_noop() {
        assert!(init().is_ok());
    }

    #[test]
    #[cfg(not(feature = "evm"))]
    fn without_evm_feature_deploy_not_initialized() {
        let r = deploy("0xdeadbeef", "0x1234");
        assert!(matches!(r, Err(EvmError::NotInitialized)));
    }

    #[test]
    #[cfg(not(feature = "evm"))]
    fn without_evm_feature_call_not_initialized() {
        let r = call("0xcontract", "0xcaller", "0x", 0, 100_000);
        assert!(matches!(r, Err(EvmError::NotInitialized)));
    }

    #[test]
    #[cfg(not(feature = "evm"))]
    fn without_evm_feature_get_balance_not_initialized() {
        let r = get_balance("0xaddr");
        assert!(matches!(r, Err(EvmError::NotInitialized)));
    }

    #[test]
    #[cfg(not(feature = "evm"))]
    fn without_evm_feature_estimate_gas_not_initialized() {
        let r = estimate_gas("0xfrom", "0xto", "0x", 0);
        assert!(matches!(r, Err(EvmError::NotInitialized)));
    }

    #[test]
    fn precompile_addr_constant() {
        assert_eq!(
            PRICE_ORACLE_PRECOMPILE_ADDR,
            "0x00000000000000000000000000000000000001ee"
        );
    }

    #[test]
    fn shutdown_is_safe_to_call_without_init() {
        // Must not panic.
        shutdown();
    }
}
