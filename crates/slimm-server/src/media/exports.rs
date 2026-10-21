// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Where data export archives are built and kept, one file per job named by
//! the job's id.

use std::io;
use std::path::PathBuf;

use super::Media;

/// A finished archive is `<id>.tar`, an unfinished one `<id>.tar.part`, and the
/// scratch sections of a running job live in `<id>.work/`.
pub const ARCHIVE_SUFFIX: &str = ".tar";
const PART_SUFFIX: &str = ".tar.part";
const WORK_SUFFIX: &str = ".work";

impl Media {
    /// The most disk finished and running archives may take together: twice the
    /// operator's attachment ceiling (an archive copies the files), else a default.
    pub fn export_ceiling_bytes(&self) -> u64 {
        self.max_total_attachment_bytes()
            .map_or(crate::store::DEFAULT_EXPORT_CEILING_BYTES, |c| {
                c.saturating_mul(2)
            })
    }

    pub fn export_archive_path(&self, id: &str) -> PathBuf {
        self.exports_dir.join(format!("{id}{ARCHIVE_SUFFIX}"))
    }

    pub fn export_part_path(&self, id: &str) -> PathBuf {
        self.exports_dir.join(format!("{id}{PART_SUFFIX}"))
    }

    pub fn export_work_dir(&self, id: &str) -> PathBuf {
        self.exports_dir.join(format!("{id}{WORK_SUFFIX}"))
    }

    /// Opens a finished archive for streaming, with its length.
    pub async fn open_export(&self, id: &str) -> io::Result<(tokio::fs::File, u64)> {
        let file = tokio::fs::File::open(self.export_archive_path(id)).await?;
        let len = file.metadata().await?.len();
        Ok((file, len))
    }

    /// The job ids that have anything on disk, finished or not.
    pub async fn export_ids_on_disk(&self) -> io::Result<Vec<String>> {
        let mut ids = Vec::new();
        let mut entries = tokio::fs::read_dir(&self.exports_dir).await?;
        while let Some(entry) = entries.next_entry().await? {
            let name = entry.file_name().to_string_lossy().into_owned();
            let id = name
                .strip_suffix(PART_SUFFIX)
                .or_else(|| name.strip_suffix(ARCHIVE_SUFFIX))
                .or_else(|| name.strip_suffix(WORK_SUFFIX));
            if let Some(id) = id {
                ids.push(id.to_owned());
            }
        }
        ids.sort();
        ids.dedup();
        Ok(ids)
    }

    /// Removes every file a job left; a missing file is not an error.
    pub async fn remove_export(&self, id: &str) -> io::Result<()> {
        for path in [self.export_archive_path(id), self.export_part_path(id)] {
            match tokio::fs::remove_file(path).await {
                Err(err) if err.kind() != io::ErrorKind::NotFound => return Err(err),
                _ => {}
            }
        }
        self.remove_export_work(id).await
    }

    /// Removes a job's scratch sections, keeping any archive.
    pub async fn remove_export_work(&self, id: &str) -> io::Result<()> {
        match tokio::fs::remove_dir_all(self.export_work_dir(id)).await {
            Err(err) if err.kind() != io::ErrorKind::NotFound => Err(err),
            _ => Ok(()),
        }
    }
}
