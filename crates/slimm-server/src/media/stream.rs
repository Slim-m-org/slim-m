// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Streaming an uploaded attachment to disk without buffering it whole.
//!
//! [`super::Media::write_attachment`] takes a `Vec` the caller already holds;
//! this path takes a byte stream and writes it to a temp file as it arrives,
//! folding each chunk into a running sha256 and refusing once the total passes
//! the caller's ceiling. A 1 GiB upload therefore costs a bounded amount of
//! memory rather than the whole file plus a copy. The temp file is placed at
//! its content-hash path only when the caller [`commit`](PendingAttachment::commit)s
//! it, so the type sniff and the deployment-ceiling check still run first.

use std::io;
use std::path::{Path, PathBuf};

use futures_util::{Stream, StreamExt};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use super::{remove, to_hex};

/// Leading bytes [`stream_attachment`] captures for the caller to sniff the
/// content type from. Every magic-number type in [`super::content_type`]
/// decides on bytes at the very start, and the webm doctype scan reads at most
/// 256, so this covers every allowlisted signature. The `text/plain` fallback
/// is the one type whose real check scans the whole file; on a streamed upload
/// it is decided from this prefix instead, which only changes the verdict for a
/// file whose bytes stop being valid text past this point - and such a file is
/// served as a forced download either way, so nothing that could render inline
/// is admitted that was not before.
const SNIFF_PREFIX_BYTES: usize = 512;

/// Why [`stream_attachment`] stopped before it could hand back a stored upload.
/// The HTTP layer maps each to a distinct status so a caller can tell "your
/// file is too big" from "we could not read it" from a server fault.
#[derive(Debug)]
pub enum StreamError {
    /// The body passed `max_bytes` mid-stream and was abandoned.
    TooLarge,
    /// The client's upload stream errored or was cut short before it ended.
    Body,
    /// Writing or flushing the temp file failed.
    Io(io::Error),
}

/// A streamed upload written to a temp file but not yet placed at its
/// content-hash path. Sniff [`sniff_prefix`](Self::sniff_prefix) to decide the
/// content type, then [`commit`](Self::commit) or [`abandon`](Self::abandon)
/// it. See [`super::Media::stream_attachment`].
pub struct PendingAttachment {
    final_path: PathBuf,
    temp_path: PathBuf,
    hex_id: String,
    size: u64,
    sniff_prefix: Vec<u8>,
    committed: bool,
}

impl PendingAttachment {
    /// The lowercase hex sha256 of the streamed bytes: their content id, and
    /// where [`commit`](Self::commit) will place them.
    pub fn hex_id(&self) -> &str {
        &self.hex_id
    }

    pub fn size(&self) -> u64 {
        self.size
    }

    /// The captured leading bytes, for the caller to sniff the content type.
    pub fn sniff_prefix(&self) -> &[u8] {
        &self.sniff_prefix
    }

    /// Places the streamed bytes at their content-hash path, or drops the temp
    /// file when those exact bytes are already stored - content addressing
    /// means an identical upload is one stored copy, not a second. Atomic
    /// within the attachments directory (a same-directory rename), the same
    /// guarantee `write_atomic` relies on.
    ///
    /// `commit` takes `self` by value, so [`Drop`] still runs when this
    /// returns - on the error path too. The rename is attempted before
    /// `committed` is ever set to true, and only a successful rename sets it,
    /// so a mid-rename failure (full disk, permissions, cross-device) is
    /// never mistaken for a stored upload. That failure is handled right
    /// here rather than by the `Drop` backstop: `temp_path` has already been
    /// taken out of `self` to move into `commit_temp`, so by the time
    /// `Drop::drop` runs on the returned `self`, `self.temp_path` is empty
    /// and the backstop finds nothing to clean up. This function therefore
    /// owns removing the temp file itself on a failed rename, best-effort,
    /// so the failure cannot leave an orphaned temp file behind.
    pub async fn commit(mut self) -> io::Result<()> {
        let temp_path = std::mem::take(&mut self.temp_path);
        let final_path = std::mem::take(&mut self.final_path);
        match commit_temp(temp_path.clone(), final_path).await {
            Ok(()) => {
                self.committed = true;
                Ok(())
            }
            Err(err) => {
                if let Err(remove_err) = remove(temp_path).await {
                    tracing::warn!(
                        error = %remove_err,
                        "failed to remove temp file after a failed attachment commit",
                    );
                }
                Err(err)
            }
        }
    }

    /// Removes the temp file without storing it, for a caller refusing the
    /// upload after streaming it (an unsupported type, or no room left).
    pub async fn abandon(mut self) -> io::Result<()> {
        self.committed = true;
        remove(std::mem::take(&mut self.temp_path)).await
    }
}

/// A backstop for the early-return and panic paths that never reach
/// [`commit`](PendingAttachment::commit) or [`abandon`](PendingAttachment::abandon):
/// a dropped-uncommitted upload must not leave its temp file behind.
/// Best-effort and synchronous because `Drop` cannot await; it is a single
/// unlink on a path this process just created.
impl Drop for PendingAttachment {
    fn drop(&mut self) {
        if !self.committed && !self.temp_path.as_os_str().is_empty() {
            let _ = std::fs::remove_file(&self.temp_path);
        }
    }
}

/// Streams `body` into a temp file under `attachments_dir`, returning a
/// [`PendingAttachment`] the caller commits or abandons. A failed stream
/// removes the temp file, so nothing is left on disk to reclaim.
pub(super) async fn stream_attachment<S, B, E>(
    attachments_dir: &Path,
    body: S,
    max_bytes: u64,
) -> Result<PendingAttachment, StreamError>
where
    S: Stream<Item = Result<B, E>>,
    B: AsRef<[u8]>,
{
    let temp_path = attachments_dir.join(format!(".tmp-{}", Uuid::now_v7()));
    // A cancelled request drops this future mid-stream, skipping the Err arm below.
    let mut cleanup = TempCleanup(Some(temp_path.clone()));
    let streamed = stream_to_temp(body, max_bytes, &temp_path).await;
    cleanup.0 = None;
    match streamed {
        Ok((hex_id, size, sniff_prefix)) => Ok(PendingAttachment {
            final_path: attachments_dir.join(&hex_id),
            temp_path,
            hex_id,
            size,
            sniff_prefix,
            committed: false,
        }),
        Err(err) => {
            let _ = remove(temp_path).await;
            Err(err)
        }
    }
}

/// Removes a temp file when dropped while still holding its path.
struct TempCleanup(Option<PathBuf>);

impl Drop for TempCleanup {
    fn drop(&mut self) {
        if let Some(path) = self.0.take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// Consumes `body`, writing every chunk to `temp_path` while folding it into a
/// running sha256 and refusing once the total passes `max_bytes`. Returns the
/// hex id, the byte count, and the captured sniff prefix; the temp file is the
/// caller's to place or remove.
async fn stream_to_temp<S, B, E>(
    body: S,
    max_bytes: u64,
    temp_path: &Path,
) -> Result<(String, u64, Vec<u8>), StreamError>
where
    S: Stream<Item = Result<B, E>>,
    B: AsRef<[u8]>,
{
    let mut body = std::pin::pin!(body);
    let mut file = tokio::fs::File::create(temp_path)
        .await
        .map_err(StreamError::Io)?;
    let mut hasher = Sha256::new();
    let mut size: u64 = 0;
    let mut prefix: Vec<u8> = Vec::with_capacity(SNIFF_PREFIX_BYTES);
    while let Some(chunk) = body.next().await {
        let chunk = chunk.map_err(|_| StreamError::Body)?;
        let bytes = chunk.as_ref();
        size = size.saturating_add(bytes.len() as u64);
        if size > max_bytes {
            return Err(StreamError::TooLarge);
        }
        hasher.update(bytes);
        if prefix.len() < SNIFF_PREFIX_BYTES {
            let room = SNIFF_PREFIX_BYTES - prefix.len();
            prefix.extend_from_slice(&bytes[..bytes.len().min(room)]);
        }
        file.write_all(bytes).await.map_err(StreamError::Io)?;
    }
    file.flush().await.map_err(StreamError::Io)?;
    Ok((to_hex(&hasher.finalize()), size, prefix))
}

/// Renames a streamed temp file to its content path, or drops it when the
/// content is already stored. On the blocking pool for the same reason
/// `write_atomic` is.
async fn commit_temp(temp_path: PathBuf, final_path: PathBuf) -> io::Result<()> {
    tokio::task::spawn_blocking(move || {
        if final_path.exists() {
            return std::fs::remove_file(&temp_path);
        }
        std::fs::rename(&temp_path, &final_path)
    })
    .await
    .unwrap_or_else(|e| Err(io::Error::other(e)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::Media;
    use futures_util::stream;

    fn chunks(parts: &[&[u8]]) -> impl Stream<Item = Result<Vec<u8>, io::Error>> {
        let owned: Vec<Result<Vec<u8>, io::Error>> = parts.iter().map(|p| Ok(p.to_vec())).collect();
        stream::iter(owned)
    }

    /// The id is the sha256 of the whole content regardless of how the stream
    /// was chunked, the size is the byte total, and the prefix is captured for
    /// sniffing. Mutating the hasher to fold only the first chunk, or the size
    /// to count one chunk, turns this red.
    #[tokio::test]
    async fn a_stream_hashes_and_sizes_the_whole_body() {
        let media = Media::for_tests();
        let whole = b"the quick brown fox".to_vec();
        let expected = to_hex(&Sha256::digest(&whole));

        let pending = media
            .stream_attachment(chunks(&[b"the quick ", b"brown fox"]), 1024)
            .await
            .expect("stream succeeds");

        assert_eq!(pending.hex_id(), expected, "id is the content sha256");
        assert_eq!(pending.size(), whole.len() as u64, "size is the byte total");
        assert_eq!(
            pending.sniff_prefix(),
            &whole[..],
            "prefix captured for sniff"
        );
    }

    /// A prefix is capped at [`SNIFF_PREFIX_BYTES`] even across many chunks, so
    /// a large upload does not buffer itself into the sniff prefix.
    #[tokio::test]
    async fn the_sniff_prefix_is_bounded() {
        let media = Media::for_tests();
        let big = vec![b'a'; SNIFF_PREFIX_BYTES * 4];

        let pending = media
            .stream_attachment(chunks(&[&big]), (big.len() as u64) + 1)
            .await
            .expect("stream succeeds");

        assert_eq!(pending.sniff_prefix().len(), SNIFF_PREFIX_BYTES);
    }

    /// Committing places the bytes at the content path; a second commit of the
    /// same content dedups to one stored copy rather than a second file.
    /// Removing the `final_path.exists()` guard makes the second commit leave a
    /// stray temp file, which this counts.
    #[tokio::test]
    async fn commit_stores_once_and_dedups_identical_content() {
        let media = Media::for_tests();
        let content: &[u8] = b"content-addressed bytes";

        let first = media
            .stream_attachment(chunks(&[content]), 1024)
            .await
            .unwrap();
        let hex = first.hex_id().to_owned();
        first.commit().await.unwrap();
        assert_eq!(
            media.read_attachment(&hex).await.unwrap(),
            content,
            "the bytes are readable at their content id"
        );

        let second = media
            .stream_attachment(chunks(&[content]), 1024)
            .await
            .unwrap();
        assert_eq!(second.hex_id(), hex, "identical content, identical id");
        second.commit().await.unwrap();

        let dir = &media.attachments_dir;
        let entries: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(
            entries,
            vec![std::ffi::OsString::from(&hex)],
            "one file, no temp"
        );
    }

    /// A commit whose rename fails must not orphan the temp file: the old
    /// code set `committed` and took the path out of `self` before ever
    /// attempting the rename, so the `Drop` backstop found nothing to clean
    /// up and the failed-to-place bytes sat on disk forever. Reverting
    /// `commit` to mark `committed` before calling `commit_temp`, or to drop
    /// the explicit `remove` on the error path, reds this.
    ///
    /// `final_path`'s parent does not exist, so `commit_temp` reaches and
    /// fails the actual rename rather than the already-stored dedup shortcut
    /// (which only fires when `final_path` itself already exists).
    #[tokio::test]
    async fn a_failed_commit_does_not_orphan_the_temp_file() {
        let media = Media::for_tests();
        let temp_path = media.attachments_dir.join(".tmp-failed-commit-test");
        tokio::fs::write(&temp_path, b"unplaceable")
            .await
            .expect("write the temp file the pending upload will point at");
        let final_path = media.attachments_dir.join("no-such-dir").join("final-name");
        let pending = PendingAttachment {
            final_path,
            temp_path: temp_path.clone(),
            hex_id: "deadbeef".to_string(),
            size: 11,
            sniff_prefix: Vec::new(),
            committed: false,
        };

        let result = pending.commit().await;

        assert!(result.is_err(), "the rename failure surfaces as an error");
        assert!(
            !temp_path.exists(),
            "a failed commit must not leave the temp file behind"
        );
    }

    /// Abandoning removes the temp file and stores nothing.
    #[tokio::test]
    async fn abandon_stores_nothing() {
        let media = Media::for_tests();
        let pending = media
            .stream_attachment(chunks(&[b"discard me"]), 1024)
            .await
            .unwrap();
        let hex = pending.hex_id().to_owned();
        pending.abandon().await.unwrap();

        assert!(media.read_attachment(&hex).await.is_err(), "not stored");
        let dir = &media.attachments_dir;
        assert_eq!(std::fs::read_dir(dir).unwrap().count(), 0, "no temp left");
    }

    /// Dropping a pending upload without commit or abandon still removes its
    /// temp file - the backstop for an early return between stream and commit.
    #[tokio::test]
    async fn dropping_uncommitted_removes_the_temp() {
        let media = Media::for_tests();
        {
            let _pending = media
                .stream_attachment(chunks(&[b"orphan"]), 1024)
                .await
                .unwrap();
        }
        let dir = &media.attachments_dir;
        assert_eq!(
            std::fs::read_dir(dir).unwrap().count(),
            0,
            "drop swept the temp"
        );
    }

    /// Exceeding `max_bytes` mid-stream is [`StreamError::TooLarge`] and leaves
    /// no temp file: the ceiling is enforced by the running count, not after
    /// the whole body is buffered.
    #[tokio::test]
    async fn over_the_ceiling_is_refused_and_leaves_nothing() {
        let media = Media::for_tests();
        let result = media
            .stream_attachment(chunks(&[b"12345", b"67890"]), 8)
            .await;

        assert!(matches!(result, Err(StreamError::TooLarge)));
        let dir = &media.attachments_dir;
        assert_eq!(
            std::fs::read_dir(dir).unwrap().count(),
            0,
            "no temp survives"
        );
    }

    /// A stream that yields an error is [`StreamError::Body`] and, likewise,
    /// leaves nothing behind.
    #[tokio::test]
    async fn a_severed_stream_is_a_body_error_and_leaves_nothing() {
        let media = Media::for_tests();
        let parts: Vec<Result<Vec<u8>, io::Error>> = vec![
            Ok(b"partial".to_vec()),
            Err(io::Error::other("connection reset")),
        ];
        let result = media.stream_attachment(stream::iter(parts), 1024).await;

        assert!(matches!(result, Err(StreamError::Body)));
        let dir = &media.attachments_dir;
        assert_eq!(
            std::fs::read_dir(dir).unwrap().count(),
            0,
            "no temp survives"
        );
    }
}
