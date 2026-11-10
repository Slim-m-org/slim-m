// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing a finished file so a power loss leaves the old state or the whole new file.
//!
//! A rename is atomic against other readers, not against a crash: the data has to reach the disk
//! before the name does, and the name before a caller records a row that points at it.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::Path;

use uuid::Uuid;

/// What a destination name stands for, which decides how a file already stored there is treated.
#[derive(Debug, Clone, Copy)]
pub(super) enum Name {
    /// The sha256 of the bytes: the same length is the same bytes, any other length a torn write.
    Content,
    /// A name several uploads can map to, so whatever is stored there stays.
    Shared,
}

/// Writes `bytes` to `path` through a same-directory temp file that is on disk before the rename.
pub(super) fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(".tmp-{}", Uuid::now_v7()));
    let placed = write_synced(&tmp, bytes).and_then(|()| fs::rename(&tmp, path));
    if placed.is_err() {
        let _ = fs::remove_file(&tmp);
        return placed;
    }
    sync_dir(dir);
    Ok(())
}

/// Moves the finished file `temp` to `dest`, or drops it when `dest` already holds those bytes.
pub(super) fn place(temp: &Path, dest: &Path, name: Name) -> io::Result<()> {
    if holds_the_bytes(temp, dest, name)? {
        return fs::remove_file(temp);
    }
    File::open(temp)?.sync_all()?;
    fs::rename(temp, dest)?;
    sync_dir(dest.parent().unwrap_or(Path::new(".")));
    Ok(())
}

fn holds_the_bytes(temp: &Path, dest: &Path, name: Name) -> io::Result<bool> {
    let stored = match fs::metadata(dest) {
        Ok(stored) => stored,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(err) => return Err(err),
    };
    match name {
        Name::Shared => Ok(true),
        Name::Content => Ok(stored.len() == fs::metadata(temp)?.len()),
    }
}

fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = File::create(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Best effort: a filesystem that cannot sync a directory must not fail an upload that is stored.
fn sync_dir(dir: &Path) {
    if let Err(err) = File::open(dir).and_then(|dir| dir.sync_all()) {
        tracing::warn!(error = %err, "could not sync a media directory after a rename");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dir(std::path::PathBuf);

    impl Dir {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("slimm-durable-test-{}", Uuid::now_v7()));
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn file(&self, name: &str, bytes: &[u8]) -> std::path::PathBuf {
            let path = self.0.join(name);
            fs::write(&path, bytes).unwrap();
            path
        }

        fn names(&self) -> Vec<String> {
            let mut names: Vec<String> = fs::read_dir(&self.0)
                .unwrap()
                .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                .collect();
            names.sort();
            names
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn an_atomic_write_replaces_the_file_and_leaves_no_temp() {
        let dir = Dir::new();
        let path = dir.file("avatar", b"old");

        write_atomic(&path, b"new bytes").unwrap();

        assert_eq!(fs::read(&path).unwrap(), b"new bytes");
        assert_eq!(dir.names(), ["avatar"]);
    }

    #[test]
    fn a_failed_atomic_write_leaves_no_temp() {
        let dir = Dir::new();

        let placed = write_atomic(&dir.0.join("missing").join("avatar"), b"bytes");

        assert!(placed.is_err());
        assert!(dir.names().is_empty());
    }

    #[test]
    fn placing_moves_the_file_to_a_free_name() {
        let dir = Dir::new();
        let temp = dir.file(".tmp-1", b"bytes");

        place(&temp, &dir.0.join("final"), Name::Content).unwrap();

        assert_eq!(dir.names(), ["final"]);
        assert_eq!(fs::read(dir.0.join("final")).unwrap(), b"bytes");
    }

    #[test]
    fn a_content_name_holding_the_same_length_is_kept() {
        let dir = Dir::new();
        let stored = dir.file("final", b"abcde");
        let temp = dir.file(".tmp-1", b"vwxyz");

        place(&temp, &stored, Name::Content).unwrap();

        assert_eq!(fs::read(&stored).unwrap(), b"abcde");
        assert_eq!(dir.names(), ["final"]);
    }

    #[test]
    fn a_content_name_holding_a_torn_file_is_repaired() {
        let dir = Dir::new();
        let stored = dir.file("final", b"abc");
        let temp = dir.file(".tmp-1", b"abcdef");

        place(&temp, &stored, Name::Content).unwrap();

        assert_eq!(fs::read(&stored).unwrap(), b"abcdef");
        assert_eq!(dir.names(), ["final"]);
    }

    #[test]
    fn a_shared_name_keeps_whatever_is_stored() {
        let dir = Dir::new();
        let stored = dir.file("final.orig", b"first original");
        let temp = dir.file(".tmp-1", b"second");

        place(&temp, &stored, Name::Shared).unwrap();

        assert_eq!(fs::read(&stored).unwrap(), b"first original");
        assert_eq!(dir.names(), ["final.orig"]);
    }
}
