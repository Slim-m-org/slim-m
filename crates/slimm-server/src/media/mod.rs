// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Filesystem-backed storage for attachment and avatar bytes. The
//! content-type allowlist that decides what may be stored and served at all
//! lives in [`content_type`], split out to keep this file under the review
//! budget once the allowlist grew past a handful of image types.
//!
//! Blobs live on disk beside the database rather than as SQLite rows:
//! Litestream replicates only the database file, so multi-megabyte blobs in
//! it would bloat exactly what gets streamed for no backup benefit. See
//! `deploy/README.md` for the backup gap this deliberately leaves.
//!
//! Every write lands via a temp-file-then-rename in the same directory, so a
//! concurrent read of a path being replaced (an avatar overwrite) never
//! observes a partially written file: rename is atomic within one filesystem.
//! File is written before any database row is updated to point at it, so a
//! crash between the two steps leaves an orphaned file (harmless, reclaimed
//! by the sweep or simply wasted bytes) rather than a row that promises bytes
//! which do not exist.
//!
//! `SLIMM_ATTACHMENTS_DIR` and `SLIMM_ATTACHMENT_MAX_BYTES` are ordinary
//! fields on the shared `Config` struct (see `src/config.rs`); this module
//! only turns the resulting path and byte limit into a working [`Media`]
//! handle.

use std::io;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use futures_util::Stream;
use uuid::Uuid;

mod content_type;
mod stream;
pub use content_type::{is_inline, sniff_content_type};
pub use stream::{PendingAttachment, StreamError};

/// Largest attachment a single upload may store, for [`Media::for_tests`],
/// which builds a handle without a `Config` to read the real default from.
/// Matches `default_attachment_max_bytes` in `src/config.rs`.
const DEFAULT_ATTACHMENT_MAX_BYTES: u64 = 1024 * 1024 * 1024;

/// How long one attachment upload may take in total.
///
/// The body idle timeout only bounds the gap between chunks, so a sender that
/// drips a byte every few seconds would otherwise hold an upload slot and its
/// temp file for as long as it likes. Long enough for a gigabyte over a slow
/// home uplink, and still finite.
const DEFAULT_UPLOAD_TIMEOUT: Duration = Duration::from_secs(30 * 60);

/// Longest a sanitized filename may be, in characters.
const FILENAME_MAX_CHARS: usize = 200;

/// Reduces a client-supplied filename to something safe to place inside a
/// quoted `Content-Disposition` header value: printable ASCII plus space
/// only, so a control character (a `\r` or `\n` would otherwise inject a new
/// header line) or non-ASCII text cannot reach the header at all, and no
/// quote, backslash, or path separator, so nothing can break out of the
/// quoted string. The path-separator strip is defence in depth only: storage
/// never uses this value as a path component (files are keyed by content
/// hash or user id), so a `../` sequence in a filename has nowhere to escape
/// to even before sanitizing.
pub fn sanitize_filename(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            let safe = (c.is_ascii_graphic() || c == ' ') && !matches!(c, '"' | '\\' | '/');
            if safe { c } else { '_' }
        })
        .take(FILENAME_MAX_CHARS)
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        "file".to_owned()
    } else {
        trimmed.to_owned()
    }
}

/// Lowercase hex, matching the idiom already used for the token and identity
/// fingerprint hashes elsewhere in this crate.
pub fn to_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

/// Parses a lowercase (or any-case) hex string back to bytes. `None` for
/// anything that is not a well-formed even-length hex string, which a
/// caller treats as "no such attachment" rather than trying to interpret it
/// as a path or otherwise.
pub fn from_hex(s: &str) -> Option<Vec<u8>> {
    if s.is_empty() || !s.len().is_multiple_of(2) || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

// --- Filesystem storage ---

/// A cloneable handle to the on-disk blob store. Cheap to clone (two
/// `PathBuf`s and a `u64`).
#[derive(Debug, Clone)]
pub struct Media {
    attachments_dir: PathBuf,
    avatars_dir: PathBuf,
    max_attachment_bytes: u64,
    /// The deployment-wide ceiling, or `None` for no ceiling. Carried here
    /// rather than on `AppState` because this is where the other size limit
    /// read out of `Config` already lives, and because `AppState` is built by
    /// hand in dozens of test files that have no opinion about it.
    max_total_attachment_bytes: Option<u64>,
    upload_timeout: Duration,
    /// Set only by [`Media::for_tests`]; always `None` in a real deployment,
    /// whose media root outlives the process on purpose.
    temp_root: Option<Arc<TempRoot>>,
}

/// Removes the tree it names once the last [`Media`] clone holding it drops.
///
/// Behind an `Arc` because `Media` is cloned into every `AppState` and axum
/// clones that per request; deleting on the first drop would take the
/// directory out from under a live test.
#[derive(Debug)]
struct TempRoot(PathBuf);

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl Media {
    /// Creates the storage directories if they do not already exist. Plain
    /// synchronous I/O rather than `spawn_blocking`: this runs once at
    /// process (or test) startup, never on a request path, so a brief block
    /// costs nothing a request would ever notice.
    pub fn new(root: impl Into<PathBuf>, max_attachment_bytes: u64) -> io::Result<Self> {
        let root = root.into();
        let attachments_dir = root.join("attachments");
        let avatars_dir = root.join("avatars");
        std::fs::create_dir_all(&attachments_dir)?;
        std::fs::create_dir_all(&avatars_dir)?;
        Ok(Self {
            attachments_dir,
            avatars_dir,
            max_attachment_bytes,
            max_total_attachment_bytes: None,
            upload_timeout: DEFAULT_UPLOAD_TIMEOUT,
            temp_root: None,
        })
    }

    /// A media store rooted in a fresh temp directory. Mirrors
    /// `PushSender::disabled()` and `VoiceService::disabled()`: a harmless
    /// stand-in so every integration test's `AppState` fixture does not have
    /// to think about storage unless it is actually exercising attachments.
    pub fn for_tests() -> Self {
        let root = std::env::temp_dir().join(format!("slimm-media-test-{}", Uuid::now_v7()));
        let mut media = Self::new(root.clone(), DEFAULT_ATTACHMENT_MAX_BYTES)
            .expect("create temp media directories");
        media.temp_root = Some(Arc::new(TempRoot(root)));
        media
    }

    /// Overrides the per-upload ceiling, consuming and returning self so a
    /// test that exercises refusal can pick a size it need not allocate.
    ///
    /// Exists so such a test can still start from [`Media::for_tests`] and
    /// keep its temp-directory guard, rather than reaching for [`Media::new`]
    /// and hand-rolling a root that nothing then deletes.
    pub fn with_attachment_max(mut self, max_attachment_bytes: u64) -> Self {
        self.max_attachment_bytes = max_attachment_bytes;
        self
    }

    pub fn max_attachment_bytes(&self) -> u64 {
        self.max_attachment_bytes
    }

    /// Sets the deployment-wide ceiling, consuming and returning self so
    /// `main` can build this in one expression.
    pub fn with_total_ceiling(mut self, ceiling: Option<u64>) -> Self {
        self.max_total_attachment_bytes = ceiling;
        self
    }

    pub fn max_total_attachment_bytes(&self) -> Option<u64> {
        self.max_total_attachment_bytes
    }

    /// Overrides the total upload time, so a test of the cut need not wait
    /// half an hour.
    pub fn with_upload_timeout(mut self, upload_timeout: Duration) -> Self {
        self.upload_timeout = upload_timeout;
        self
    }

    pub fn upload_timeout(&self) -> Duration {
        self.upload_timeout
    }

    fn attachment_path(&self, sha256_hex: &str) -> PathBuf {
        self.attachments_dir.join(sha256_hex)
    }

    fn avatar_path(&self, user_id: &str) -> PathBuf {
        self.avatars_dir.join(user_id)
    }

    pub async fn write_attachment(&self, sha256_hex: &str, bytes: Vec<u8>) -> io::Result<()> {
        write_atomic(self.attachment_path(sha256_hex), bytes).await
    }

    /// Streams `body` to a temp file under the attachments directory, hashing
    /// it as it goes and refusing at `max_bytes` so an oversized upload is
    /// abandoned mid-stream rather than buffered whole in memory - the whole
    /// point of this path over [`write_attachment`], which takes a `Vec` the
    /// caller already holds.
    ///
    /// The returned [`PendingAttachment`] carries the temp file, its
    /// content-hash id, its byte count, and a [`SNIFF_PREFIX_BYTES`] prefix for
    /// the caller to decide the content type from - a stream already written to
    /// disk cannot be re-read to sniff. The caller then
    /// [`commit`](PendingAttachment::commit)s or
    /// [`abandon`](PendingAttachment::abandon)s it; dropping it uncommitted
    /// removes the temp file, so any refusal past this point leaves nothing on
    /// disk, the same guarantee the size and ceiling checks upstream already
    /// promise.
    ///
    /// Generic over the chunk type so this module keeps no dependency on axum's
    /// body types; the HTTP layer passes its request body's data stream. The
    /// streaming machinery lives in [`stream`].
    pub async fn stream_attachment<S, B, E>(
        &self,
        body: S,
        max_bytes: u64,
    ) -> Result<PendingAttachment, StreamError>
    where
        S: Stream<Item = Result<B, E>>,
        B: AsRef<[u8]>,
    {
        stream::stream_attachment(&self.attachments_dir, body, max_bytes).await
    }

    pub async fn read_attachment(&self, sha256_hex: &str) -> io::Result<Vec<u8>> {
        read(self.attachment_path(sha256_hex)).await
    }

    /// Opens a stored attachment for streaming, returning the handle and its
    /// length, so a large download is served straight from disk rather than
    /// read into a `Vec` first. The length is read from this same handle, so
    /// it describes the bytes this handle will serve: writes here are atomic
    /// renames ([`write_atomic`]), so an open handle keeps the file it opened
    /// even if a concurrent write replaces the path.
    pub async fn open_attachment(&self, sha256_hex: &str) -> io::Result<(tokio::fs::File, u64)> {
        let file = tokio::fs::File::open(self.attachment_path(sha256_hex)).await?;
        let len = file.metadata().await?.len();
        Ok((file, len))
    }

    pub async fn delete_attachment(&self, sha256_hex: &str) -> io::Result<()> {
        remove(self.attachment_path(sha256_hex)).await
    }

    pub async fn write_avatar(&self, user_id: &str, bytes: Vec<u8>) -> io::Result<()> {
        write_atomic(self.avatar_path(user_id), bytes).await
    }

    pub async fn read_avatar(&self, user_id: &str) -> io::Result<Vec<u8>> {
        read(self.avatar_path(user_id)).await
    }

    pub async fn delete_avatar(&self, user_id: &str) -> io::Result<()> {
        remove(self.avatar_path(user_id)).await
    }
}

/// Writes `bytes` to `path` via a same-directory temp file plus rename, so a
/// concurrent reader of `path` never observes a partial write. The write and
/// the rename run together on the blocking pool so the pair is one hop off the
/// runtime rather than two, which is the same mechanism `tokio::fs` is built on.
async fn write_atomic(path: PathBuf, bytes: Vec<u8>) -> io::Result<()> {
    tokio::task::spawn_blocking(move || {
        let dir = path
            .parent()
            .expect("attachment and avatar paths always have a parent directory");
        let tmp_path = dir.join(format!(".tmp-{}", Uuid::now_v7()));
        std::fs::write(&tmp_path, &bytes)?;
        std::fs::rename(&tmp_path, &path)
    })
    .await
    .unwrap_or_else(|e| Err(io::Error::other(e)))
}

async fn read(path: PathBuf) -> io::Result<Vec<u8>> {
    tokio::task::spawn_blocking(move || std::fs::read(path))
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
}

/// Deletes a file, treating "already gone" as success: both the orphan sweep
/// and a message delete's attachment release call this for content that may
/// already have been cleaned up by a previous, interrupted attempt.
async fn remove(path: PathBuf) -> io::Result<()> {
    tokio::task::spawn_blocking(move || match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    })
    .await
    .unwrap_or_else(|e| Err(io::Error::other(e)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_header_and_path_injection() {
        assert_eq!(sanitize_filename("photo.png"), "photo.png");
        assert_eq!(sanitize_filename("my photo.png"), "my photo.png");
        assert_eq!(
            sanitize_filename("evil\r\nX-Injected: true.png"),
            "evil__X-Injected: true.png"
        );
        assert_eq!(sanitize_filename("say \"hi\".png"), "say _hi_.png");
        assert_eq!(sanitize_filename("../../etc/passwd"), ".._.._etc_passwd");
        assert_eq!(sanitize_filename(""), "file");
        assert_eq!(sanitize_filename("   "), "file");
    }

    #[test]
    fn hex_roundtrips() {
        let bytes = vec![0u8, 1, 255, 16, 128];
        let hex = to_hex(&bytes);
        assert_eq!(hex, "0001ff1080");
        assert_eq!(from_hex(&hex), Some(bytes));
        assert_eq!(from_hex("not-hex"), None);
        assert_eq!(from_hex("abc"), None, "odd length is rejected");
    }
}

#[cfg(test)]
mod temp_root_tests {
    use super::*;

    /// The builder exists so a test needing a smaller ceiling can still start
    /// from [`Media::for_tests`] and keep this guard. Reaching for
    /// [`Media::new`] instead is how the attachment fixture came to leave one
    /// directory per test on a shared 16 GiB tmpfs.
    #[test]
    fn overriding_the_upload_ceiling_keeps_the_temp_guard() {
        let media = Media::for_tests().with_attachment_max(4096);
        let root = media.attachments_dir.parent().unwrap().to_path_buf();
        assert_eq!(media.max_attachment_bytes(), 4096);
        assert!(root.exists(), "the root exists while a handle is held");

        drop(media);
        assert!(!root.exists(), "a ceiling override must not drop the guard");
    }

    #[test]
    fn a_test_media_root_is_removed_when_the_last_clone_drops() {
        let media = Media::for_tests();
        let root = media.attachments_dir.parent().unwrap().to_path_buf();
        assert!(root.exists(), "the root exists while a handle is held");

        let clone = media.clone();
        drop(media);
        assert!(root.exists(), "a surviving clone keeps the root alive");

        drop(clone);
        assert!(!root.exists(), "the last drop removes the root");
    }
}
