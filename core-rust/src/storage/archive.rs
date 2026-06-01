//! Archive manager — port of `core/archive_manager.zig`.
//!
//! Tracks counts/sizes of pruned-block batches written to long-term archive.
//! The Zig version is a stub (no real S3/IPFS upload), so this port keeps the
//! same shape: counters + metadata + snapshot records. Compression is currently
//! a 75% size estimate, matching Zig.

#[derive(Debug, Clone)]
pub struct ArchiveManager {
    pub archive_path: String,
    pub compress_enabled: bool,
    pub archived_blocks: u32,
    pub total_archive_size: u64,
}

impl ArchiveManager {
    pub fn new(archive_path: impl Into<String>, compress: bool) -> Self {
        Self {
            archive_path: archive_path.into(),
            compress_enabled: compress,
            archived_blocks: 0,
            total_archive_size: 0,
        }
    }

    pub fn archive_blocks(&mut self, start_height: u32, end_height: u32, blocks_data: &[u8]) {
        let block_count = end_height - start_height + 1;
        let compressed_size = if self.compress_enabled {
            (blocks_data.len() * 25) / 100 // ~75% reduction, matches Zig stub
        } else {
            blocks_data.len()
        };
        self.archived_blocks += block_count;
        self.total_archive_size += compressed_size as u64;
    }

    pub fn metadata(&self) -> ArchiveMetadata {
        ArchiveMetadata {
            archived_block_count: self.archived_blocks,
            total_size_bytes: self.total_archive_size,
            estimated_restore_time_sec: self.total_archive_size / (100 * 1024 * 1024),
        }
    }

    pub fn create_snapshot(&self, height: u32, hash: impl Into<Vec<u8>>) -> ArchiveSnapshot {
        ArchiveSnapshot {
            height,
            block_hash: hash.into(),
            created_at: chrono_now_unix(),
            archive_size: self.total_archive_size,
        }
    }

    pub fn verify(&self) -> bool { true }
}

#[derive(Debug, Clone, Copy)]
pub struct ArchiveMetadata {
    pub archived_block_count: u32,
    pub total_size_bytes: u64,
    pub estimated_restore_time_sec: u64,
}

#[derive(Debug, Clone)]
pub struct ArchiveSnapshot {
    pub height: u32,
    pub block_hash: Vec<u8>,
    pub created_at: i64,
    pub archive_size: u64,
}

fn chrono_now_unix() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn archive_counts() {
        let mut a = ArchiveManager::new("/tmp/arch", true);
        a.archive_blocks(0, 99, &vec![0u8; 1_000_000]);
        assert_eq!(a.archived_blocks, 100);
        // 75% reduction → 250_000
        assert_eq!(a.total_archive_size, 250_000);
    }
}
