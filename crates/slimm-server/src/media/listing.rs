// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Listing a media directory for the leak scans.

use std::io;
use std::path::PathBuf;
use std::time::SystemTime;

/// Every plain file of `dir` with when it was last written.
pub(super) async fn list_files(dir: PathBuf) -> io::Result<Vec<(String, SystemTime)>> {
    tokio::task::spawn_blocking(move || plain_files(std::fs::read_dir(dir)?))
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
}

/// The plain files among `entries` with their last write. An entry gone by the time it is read
/// is left out: an upload's temp file is renamed into place while the directory is listed.
fn plain_files(
    entries: impl Iterator<Item = io::Result<std::fs::DirEntry>>,
) -> io::Result<Vec<(String, SystemTime)>> {
    let mut files = Vec::new();
    for entry in entries {
        let entry = entry?;
        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        if meta.is_file()
            && let Some(name) = entry.file_name().to_str()
        {
            files.push((name.to_owned(), meta.modified()?));
        }
    }
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_renamed_away_between_listing_and_reading_it_is_left_out() {
        let dir = std::env::temp_dir().join(format!("slimm-listing-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let temp = dir.join(".tmp-being-written");
        std::fs::write(&temp, b"x").unwrap();
        std::fs::write(dir.join("kept"), b"x").unwrap();
        let listed: Vec<_> = std::fs::read_dir(&dir).unwrap().collect();

        std::fs::rename(&temp, dir.join("renamed")).unwrap();

        let mut names: Vec<String> = plain_files(listed.into_iter())
            .expect("a vanished temp file does not fail the listing")
            .into_iter()
            .map(|(name, _)| name)
            .collect();
        names.sort();
        assert_eq!(names, ["kept"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
