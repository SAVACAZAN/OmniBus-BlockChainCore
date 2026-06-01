//! Salt manager — KYC hash = SHA-256(salt || kyc_doc).
//! Deleting the salt = GDPR §17 (right to be forgotten).

use rand::RngCore;
use std::fs;
use std::io::{Read, Write};
use std::path::PathBuf;

pub type Salt = [u8; 32];

pub trait SaltManager {
    fn get_or_create(&mut self) -> std::io::Result<Salt>;
    fn delete(&mut self) -> std::io::Result<()>;
}

pub struct MemorySaltManager {
    salt: Option<Salt>,
}

impl MemorySaltManager {
    pub fn new() -> Self {
        Self { salt: None }
    }

    pub fn salt(&self) -> Option<Salt> {
        self.salt
    }
}

impl Default for MemorySaltManager {
    fn default() -> Self {
        Self::new()
    }
}

impl SaltManager for MemorySaltManager {
    fn get_or_create(&mut self) -> std::io::Result<Salt> {
        if let Some(s) = self.salt {
            return Ok(s);
        }
        let mut fresh = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut fresh);
        self.salt = Some(fresh);
        Ok(fresh)
    }

    fn delete(&mut self) -> std::io::Result<()> {
        self.salt = None;
        Ok(())
    }
}

pub struct FileSaltManager {
    path: PathBuf,
}

impl FileSaltManager {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

impl SaltManager for FileSaltManager {
    fn get_or_create(&mut self) -> std::io::Result<Salt> {
        if let Ok(mut f) = fs::File::open(&self.path) {
            let mut buf = [0u8; 32];
            let n = f.read(&mut buf)?;
            if n == 32 {
                return Ok(buf);
            }
            // corrupt → regenerate
        }
        let mut fresh = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut fresh);
        // chmod 0600 on Unix; on Windows the default file ACL inherits from
        // parent (user-only by convention for vault dirs).
        let mut f = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perm = f.metadata()?.permissions();
            perm.set_mode(0o600);
            f.set_permissions(perm)?;
        }
        f.write_all(&fresh)?;
        Ok(fresh)
    }

    fn delete(&mut self) -> std::io::Result<()> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_get_twice_same() {
        let mut m = MemorySaltManager::new();
        let a = m.get_or_create().unwrap();
        let b = m.get_or_create().unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn memory_delete_forgets() {
        let mut m = MemorySaltManager::new();
        let a = m.get_or_create().unwrap();
        m.delete().unwrap();
        let b = m.get_or_create().unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn memory_delete_idempotent() {
        let mut m = MemorySaltManager::new();
        m.delete().unwrap();
        m.delete().unwrap();
    }
}
