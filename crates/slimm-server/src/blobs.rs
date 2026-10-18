// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Releasing attachment bytes safely, and reclaiming any that leaked.
//!
//! Bytes are content-addressed and shared, so a release is "remove the rows,
//! then unlink the file if nothing points at it". Done naively, an identical
//! upload landing between those two steps kept the old file, inserted a fresh
//! row, and then lost the file (issue 2077). Both sides now hold
//! [`Media::blob_guard`]: an upload across placing its bytes and inserting its
//! row, a release across checking for a row and unlinking.
//!
//! The scan covers what a release cannot: a delete that failed after its rows
//! were gone, a temp file a crash or cancelled request left behind (issues
//! 2069, 2071, 2076).

use std::time::{Duration, SystemTime};

use crate::media::{self, Media};
use crate::store::Store;

/// A temp file older than this belongs to no request still running.
const TEMP_FILE_GRACE: Duration = Duration::from_secs(60 * 60);
/// Bytes written before their row exist briefly by design; older ones with
/// no row are leaks.
const ORPHAN_FILE_GRACE: Duration = Duration::from_secs(24 * 60 * 60);

/// Unlinks `hex`'s bytes unless a row still points at them. A failure keeps
/// the file, which the scan retries later.
pub async fn release(store: &Store, media: &Media, hex: &str) {
    let Some(sha256) = media::from_hex(hex) else {
        return;
    };
    let _guard = media.blob_guard().await;
    match store.attachment_summary(&sha256).await {
        Ok(None) => {}
        Ok(Some(_)) => return,
        Err(err) => {
            tracing::warn!(error = %err, attachment = %hex, "could not check an attachment before deleting its file");
            return;
        }
    }
    if let Err(err) = media.delete_attachment(hex).await {
        tracing::warn!(error = %err, attachment = %hex, "failed to delete a released attachment file");
    }
}

/// Removes stale temp files and old bytes no row points at; returns how many
/// files went.
pub async fn collect_garbage(
    store: &Store,
    media: &Media,
    now: SystemTime,
) -> anyhow::Result<usize> {
    let mut removed = collect_stale_previews(store, media, now).await?;
    for (name, modified) in media.attachment_files().await? {
        let age = now.duration_since(modified).unwrap_or_default();
        if name.starts_with(".tmp-") {
            if age >= TEMP_FILE_GRACE && media.remove_temp_file(&name).await.is_ok() {
                removed += 1;
            }
            continue;
        }
        if age < ORPHAN_FILE_GRACE || !is_content_name(&name) {
            continue;
        }
        let Some(sha256) = media::from_hex(&name) else {
            continue;
        };
        let _guard = media.blob_guard().await;
        if store.attachment_summary(&sha256).await?.is_none() {
            media.delete_attachment(&name).await?;
            removed += 1;
        }
    }
    Ok(removed)
}

/// Removes previews whose attachment is gone; `delete_attachment` covers the normal path.
async fn collect_stale_previews(
    store: &Store,
    media: &Media,
    now: SystemTime,
) -> anyhow::Result<usize> {
    let mut removed = 0;
    for (name, modified) in media.previews().files().await? {
        let age = now.duration_since(modified).unwrap_or_default();
        let stale_temp = name.starts_with(".tmp-") && age >= TEMP_FILE_GRACE;
        let hex = name.split('.').next().unwrap_or_default();
        let orphan = age >= ORPHAN_FILE_GRACE
            && is_content_name(hex)
            && match media::from_hex(hex) {
                Some(sha256) => store.attachment_summary(&sha256).await?.is_none(),
                None => false,
            };
        if (stale_temp || orphan) && media.previews().remove_file(&name).await.is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

/// A sha256 in lowercase hex: the only names content files have.
fn is_content_name(name: &str) -> bool {
    name.len() == 64
        && name
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_lowercase_sha256_names_count_as_content() {
        assert!(is_content_name(&"a".repeat(64)));
        assert!(!is_content_name(&"A".repeat(64)));
        assert!(!is_content_name(&"a".repeat(63)));
        assert!(!is_content_name(".tmp-0190"));
        assert!(!is_content_name("space-banner"));
    }
}
