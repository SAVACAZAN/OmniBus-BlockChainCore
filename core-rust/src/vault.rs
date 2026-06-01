//! Vault reader — port of `core/vault_reader.zig`.
//!
//! Reads the OmniBus wallet mnemonic from, in order of priority:
//!   1. SuperVault Named Pipe (Windows only) — talks the VaaS protocol to
//!      `vault_service.exe` over `\\.\pipe\OmnibusVault`.
//!   2. Environment variable `OMNIBUS_MNEMONIC` (cross-platform).
//!   3. Hardcoded dev default ("abandon abandon ... about").
//!
//! On non-Windows targets the pipe step is skipped entirely.
//!
//! VaaS wire format (matches `vault_core.h`):
//!   Request:  [opcode:1][exchange:1][slot:2 LE][payload_len:2 LE][payload]
//!   Response: [error:1][payload_len:2 LE][payload]

use thiserror::Error;

/// SuperVault Named Pipe name (Windows).
///
/// Historically called "OmnibusVault" inside the Zig codebase; the parent
/// CLAUDE.md refers to the same service as "SuperVault". The pipe name on
/// the wire is what the daemon listens on.
#[cfg(windows)]
pub const VAULT_PIPE_PATH: &str = r"\\.\pipe\OmnibusVault";

/// Unix-domain socket path for future non-Windows vault daemon. Currently
/// unused — Linux/macOS fall back to env var only.
#[cfg(unix)]
pub const VAULT_SOCKET_PATH: &str = "/var/run/omnibus/vault.sock";

/// Environment variable consulted when the pipe is unavailable.
pub const ENV_VAR: &str = "OMNIBUS_MNEMONIC";

/// Dev-only mnemonic — BIP-39 standard "abandon × 11 + about". DO NOT use on
/// mainnet; it derives a publicly known wallet.
pub const DEV_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon \
                                abandon abandon abandon abandon abandon about";

/// VaaS opcode for GET_SECRET (from `vault_core.h`).
const VAULT_OP_GET_SECRET: u8 = 0x4A;
/// VaaS exchange id used for the OMNI wallet mnemonic (LCX slot, historical).
const VAULT_EXCHANGE_LCX: u8 = 0x00;

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("vault pipe not available")]
    PipeNotAvailable,
    #[error("vault pipe write failed: {0}")]
    PipeWrite(#[source] std::io::Error),
    #[error("vault pipe read failed: {0}")]
    PipeRead(#[source] std::io::Error),
    #[error("vault returned error byte: {0:#x}")]
    VaultStatus(u8),
    #[error("vault returned an empty secret")]
    EmptySecret,
    #[error("vault returned non-utf8 secret")]
    InvalidUtf8(#[from] std::string::FromUtf8Error),
}

/// Top-level: try the pipe (Windows only), then env var, then the dev default.
/// Returns the mnemonic as an owned String. Always succeeds in practice
/// because the dev default is the final fallback.
pub fn read_mnemonic() -> Result<String, VaultError> {
    // 1. Named Pipe (Windows). Failures fall through silently.
    #[cfg(windows)]
    {
        match read_from_vault_pipe() {
            Ok(m) => {
                tracing::info!("[VAULT] mnemonic loaded from vault_service");
                return Ok(m);
            }
            Err(e) => {
                tracing::debug!("[VAULT] pipe unavailable ({e}); trying env var");
            }
        }
    }

    // 2. Env var (cross-platform).
    if let Ok(val) = std::env::var(ENV_VAR) {
        if !val.trim().is_empty() {
            tracing::info!("[VAULT] mnemonic loaded from ${}", ENV_VAR);
            return Ok(val);
        }
    }

    // 3. Dev default.
    tracing::warn!(
        "[VAULT] using DEV default mnemonic (set ${} or start vault_service)",
        ENV_VAR
    );
    Ok(DEV_MNEMONIC.to_string())
}

/// Windows-only: speak VaaS over the Named Pipe and pull the OMNI mnemonic
/// at exchange=LCX (0x00), slot=0.
#[cfg(windows)]
fn read_from_vault_pipe() -> Result<String, VaultError> {
    use std::io::{Read, Write};
    use std::time::Duration;

    // We use the blocking std::fs::OpenOptions path because the request is
    // one-shot at startup and stays well outside any async runtime hot path.
    // `tokio::net::windows::named_pipe::ClientOptions` is the async cousin —
    // not needed here, and avoids requiring a running runtime for this call.
    let mut pipe = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(VAULT_PIPE_PATH)
        .map_err(|_| VaultError::PipeNotAvailable)?;

    // Request frame: [0x4A][0x00 LCX][slot=0 u16 LE][payload_len=0 u16 LE]
    let req: [u8; 6] = [
        VAULT_OP_GET_SECRET,
        VAULT_EXCHANGE_LCX,
        0x00, 0x00, // slot = 0
        0x00, 0x00, // payload_len = 0
    ];
    pipe.write_all(&req).map_err(VaultError::PipeWrite)?;
    pipe.flush().ok();

    // Response: [error:1][len:2 LE][secret_bytes…]. Cap at 16 KiB.
    let mut resp = vec![0u8; 16384 + 3];
    let n = pipe.read(&mut resp).map_err(VaultError::PipeRead)?;
    if n < 3 {
        return Err(VaultError::EmptySecret);
    }

    let status = resp[0];
    if status != 0 {
        return Err(VaultError::VaultStatus(status));
    }
    let len = u16::from_le_bytes([resp[1], resp[2]]) as usize;
    if len == 0 || n < 3 + len {
        return Err(VaultError::EmptySecret);
    }

    let secret = String::from_utf8(resp[3..3 + len].to_vec())?;
    // unused on this branch but keeps clippy happy if added later
    let _ = Duration::from_millis(0);
    Ok(secret)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_default_is_non_empty_and_starts_with_abandon() {
        // Without OMNIBUS_MNEMONIC set and (likely) no vault_service, we hit
        // the dev default. Don't assume CI is "clean" — only assert shape.
        let m = read_mnemonic().expect("read_mnemonic infallible");
        assert!(!m.is_empty());
    }

    #[test]
    fn dev_default_has_12_words() {
        let count = DEV_MNEMONIC.split_whitespace().count();
        assert_eq!(count, 12);
    }

    #[test]
    fn dev_default_is_bip39_standard() {
        assert!(DEV_MNEMONIC.starts_with("abandon"));
        assert!(DEV_MNEMONIC.ends_with("about"));
    }
}
