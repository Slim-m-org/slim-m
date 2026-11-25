// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one-shot that sizes a connector volume by the disk it occupies, not by file sizes.

use std::collections::HashSet;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// Entries counted before the walk gives up and reports the volume as over, whatever it holds.
pub const MAX_ENTRIES: u64 = 500_000;
const BLOCK: u64 = 512;

/// What a walk found; `bytes` is disk space allocated, directories included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Measured {
    pub bytes: u64,
    pub entries: u64,
}

impl Measured {
    /// The size to report against `limit`: past it, or past the entry cap, is always over.
    pub fn reported(self, limit: u64) -> u64 {
        match self.entries > MAX_ENTRIES {
            true => self.bytes.max(limit.saturating_add(1)),
            false => self.bytes,
        }
    }
}

/// Sums `st_blocks * 512` under `root` without following links, counting a hard-linked file
/// once, and stops as soon as the sum passes `limit` or the entry count passes [`MAX_ENTRIES`].
pub fn allocated(root: &Path, limit: u64) -> std::io::Result<Measured> {
    let mut seen = HashSet::new();
    let mut found = Measured {
        bytes: 0,
        entries: 0,
    };
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let meta = std::fs::symlink_metadata(&dir)?;
        found.bytes += meta.blocks() * BLOCK;
        found.entries += 1;
        if !meta.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&dir)? {
            let path = entry?.path();
            let meta = std::fs::symlink_metadata(&path)?;
            if meta.is_dir() {
                pending.push(path);
                continue;
            }
            found.entries += 1;
            if meta.nlink() > 1 && !seen.insert((meta.dev(), meta.ino())) {
                continue;
            }
            found.bytes += meta.blocks() * BLOCK;
            if found.bytes > limit || found.entries > MAX_ENTRIES {
                return Ok(found);
            }
        }
        if found.bytes > limit || found.entries > MAX_ENTRIES {
            return Ok(found);
        }
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    fn dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("slimm-measure-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn tiny_files_cost_whole_blocks() {
        let root = dir();
        for i in 0..64 {
            std::fs::write(root.join(format!("f{i}")), b"x").unwrap();
        }
        let found = allocated(&root, u64::MAX).unwrap();
        assert_eq!(found.entries, 65);
        let apparent = 64;
        assert!(found.bytes > apparent, "{found:?}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_sparse_file_costs_what_it_occupies_not_what_it_claims() {
        let root = dir();
        let file = std::fs::File::create(root.join("sparse")).unwrap();
        file.set_len(64 * 1024 * 1024).unwrap();
        let found = allocated(&root, u64::MAX).unwrap();
        assert!(found.bytes < 1024 * 1024, "{found:?}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn written_data_is_counted_and_hard_links_once() {
        let root = dir();
        let mut file = std::fs::File::create(root.join("a")).unwrap();
        file.write_all(&vec![7u8; 256 * 1024]).unwrap();
        file.sync_all().unwrap();
        let once = allocated(&root, u64::MAX).unwrap().bytes;
        std::fs::hard_link(root.join("a"), root.join("b")).unwrap();
        let linked = allocated(&root, u64::MAX).unwrap();
        assert!(once >= 256 * 1024, "{once}");
        assert_eq!(linked.bytes, once);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn links_are_not_followed_and_the_walk_stops_past_the_limit() {
        let root = dir();
        std::os::unix::fs::symlink("/", root.join("up")).unwrap();
        assert!(allocated(&root, u64::MAX).unwrap().bytes < 1024 * 1024);
        for i in 0..32 {
            std::fs::write(root.join(format!("f{i}")), vec![1u8; 8192]).unwrap();
        }
        let found = allocated(&root, 4096).unwrap();
        assert!(found.bytes > 4096 && found.entries < 34, "{found:?}");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn past_the_entry_cap_the_volume_reports_over() {
        let found = Measured {
            bytes: 10,
            entries: MAX_ENTRIES + 1,
        };
        assert_eq!(found.reported(1000), 1001);
        let few = Measured {
            bytes: 10,
            entries: 3,
        };
        assert_eq!(few.reported(1000), 10);
    }
}
