// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How much disk the export archives may take, so a build is refused before it
//! can fill the volume the database shares.

use super::Store;
use super::data_exports::ExportKind;
use crate::ids::UserId;

/// Archives are uncompressed copies of the files they hold; this is the room
/// they get when the operator sets no attachment ceiling.
pub const DEFAULT_EXPORT_CEILING_BYTES: u64 = 50 * 1024 * 1024 * 1024;

const STORED: &str = "SELECT COALESCE(SUM(size_bytes), 0) FROM data_exports WHERE status = 'ready'";
const SPACE_FILES: &str = "SELECT COALESCE(SUM(size), 0) FROM attachments";
const MEMBER_FILES: &str = "SELECT COALESCE(SUM(a.size), 0) FROM attachments a
     WHERE EXISTS (SELECT 1 FROM attachment_uploaders au
                    WHERE au.sha256 = a.sha256 AND au.uploaded_by = ?)";

impl Store {
    /// Whether a new archive fits: what ready archives hold, plus an upper
    /// bound on the files this one will copy, stays within `ceiling`.
    pub async fn export_fits(
        &self,
        kind: ExportKind,
        user: UserId,
        ceiling: u64,
    ) -> anyhow::Result<bool> {
        let stored: i64 = sqlx::query_scalar(STORED).fetch_one(&self.pool).await?;
        let files = self.export_files_bytes(kind, user).await?;
        Ok(stored.saturating_add(files) <= i64::try_from(ceiling).unwrap_or(i64::MAX))
    }

    /// An upper bound on the attachment bytes this archive will copy.
    pub async fn export_files_bytes(&self, kind: ExportKind, user: UserId) -> anyhow::Result<i64> {
        Ok(match kind {
            ExportKind::Space => {
                sqlx::query_scalar(SPACE_FILES)
                    .fetch_one(&self.pool)
                    .await?
            }
            ExportKind::Member => {
                sqlx::query_scalar(MEMBER_FILES)
                    .bind(user)
                    .fetch_one(&self.pool)
                    .await?
            }
        })
    }
}
