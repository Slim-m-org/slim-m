// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Resumable uploads: one large attachment sent as ordered parts, each its
//! own request, so no single request crosses a proxy's body cap (Cloudflare's
//! is 100 MB) or read timeout.
//!
//! A session is a directory holding `meta.json` and the `data` received so
//! far. The data file's length is the resume offset, so a session survives a
//! dropped connection and a server restart alike, and a part cut short
//! mid-stream still leaves only bytes that belong where they landed. Parts
//! are hashed as they arrive, so completing a large file is instant; only a
//! session that outlived a restart is re-read from disk.

use std::collections::{HashMap, HashSet};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{Stream, StreamExt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use super::to_hex;

/// Largest single part. Comfortably under Cloudflare's 100 MB request cap.
pub const UPLOAD_PART_MAX_BYTES: u64 = 64 * 1024 * 1024;

/// How long an unfinished session keeps its bytes before the sweep drops it.
pub const UPLOAD_SESSION_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// Open sessions one member may hold at once, since each reserves disk.
pub const MAX_OPEN_SESSIONS_PER_USER: usize = 8;

/// Leading bytes handed back for sniffing; matches `stream::SNIFF_PREFIX_BYTES`.
const SNIFF_PREFIX_BYTES: usize = 512;

const META_FILE: &str = "meta.json";
const DATA_FILE: &str = "data";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UploadMeta {
    /// The uploader's id, as text.
    pub user_id: String,
    pub filename: String,
    pub size: u64,
    pub created_at: i64,
}

/// Why a part was not appended.
#[derive(Debug)]
pub enum AppendError {
    /// No such session.
    Missing,
    /// Another request is writing this session right now.
    Busy,
    /// The part did not start where the data ends; carries the real offset.
    OffsetMismatch(u64),
    /// The part is over [`UPLOAD_PART_MAX_BYTES`] or runs past the declared size.
    TooLarge,
    /// The client's stream failed; the bytes that did arrive are kept.
    Body,
    Io(io::Error),
}

/// A session whose bytes are all in, hashed and ready to place.
#[derive(Debug)]
pub struct FinishedUpload {
    pub hex_id: String,
    pub size: u64,
    pub sniff_prefix: Vec<u8>,
}

/// Handle to the sessions directory; cheap to clone.
#[derive(Debug, Clone)]
pub struct Uploads {
    dir: PathBuf,
    attachments_dir: PathBuf,
    in_flight: Arc<Mutex<HashSet<Uuid>>>,
    running: Arc<Mutex<HashMap<Uuid, RunningHash>>>,
}

/// The hash of a session's first `offset` bytes, carried between parts.
#[derive(Debug, Clone)]
struct RunningHash {
    offset: u64,
    hasher: Sha256,
    prefix: Vec<u8>,
}

impl RunningHash {
    fn empty() -> Self {
        Self {
            offset: 0,
            hasher: Sha256::new(),
            prefix: Vec::with_capacity(SNIFF_PREFIX_BYTES),
        }
    }

    fn update(&mut self, bytes: &[u8]) {
        if self.prefix.len() < SNIFF_PREFIX_BYTES {
            let take = (SNIFF_PREFIX_BYTES - self.prefix.len()).min(bytes.len());
            self.prefix.extend_from_slice(&bytes[..take]);
        }
        self.hasher.update(bytes);
        self.offset += bytes.len() as u64;
    }

    fn finish(self) -> FinishedUpload {
        FinishedUpload {
            hex_id: to_hex(&self.hasher.finalize()),
            size: self.offset,
            sniff_prefix: self.prefix,
        }
    }
}

/// Marks a session busy until dropped, so two requests never write one file.
struct Claim {
    in_flight: Arc<Mutex<HashSet<Uuid>>>,
    id: Uuid,
}

impl Drop for Claim {
    fn drop(&mut self) {
        self.in_flight
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&self.id);
    }
}

impl Uploads {
    pub(super) fn new(dir: PathBuf, attachments_dir: PathBuf) -> Self {
        Self {
            dir,
            attachments_dir,
            in_flight: Arc::default(),
            running: Arc::default(),
        }
    }

    fn lock_running(&self) -> std::sync::MutexGuard<'_, HashMap<Uuid, RunningHash>> {
        self.running
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The carried hash if it covers exactly `offset` bytes; `None` means the
    /// session will be re-read from disk when it completes.
    fn take_running(&self, id: Uuid, offset: u64) -> Option<RunningHash> {
        let carried = self.lock_running().remove(&id);
        match carried {
            Some(running) if running.offset == offset => Some(running),
            _ if offset == 0 => Some(RunningHash::empty()),
            _ => None,
        }
    }

    fn session_dir(&self, id: Uuid) -> PathBuf {
        self.dir.join(id.to_string())
    }

    fn claim(&self, id: Uuid) -> Option<Claim> {
        let mut set = self
            .in_flight
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        set.insert(id).then(|| Claim {
            in_flight: self.in_flight.clone(),
            id,
        })
    }

    pub async fn create(&self, meta: UploadMeta) -> io::Result<Uuid> {
        let id = Uuid::now_v7();
        let dir = self.session_dir(id);
        let json = serde_json::to_vec(&meta).map_err(io::Error::other)?;
        blocking(move || {
            std::fs::create_dir_all(&dir)?;
            std::fs::File::create(dir.join(DATA_FILE))?;
            std::fs::write(dir.join(META_FILE), json)
        })
        .await?;
        Ok(id)
    }

    /// The session's metadata and how many bytes it holds, or `None` if it
    /// does not exist.
    pub async fn status(&self, id: Uuid) -> io::Result<Option<(UploadMeta, u64)>> {
        let dir = self.session_dir(id);
        blocking(move || read_status(&dir)).await
    }

    /// How many sessions `user_id` holds open.
    pub async fn open_sessions_for(&self, user_id: String) -> io::Result<usize> {
        let dir = self.dir.clone();
        blocking(move || {
            Ok(list_sessions(&dir)?
                .filter(|(_, meta)| meta.user_id == user_id)
                .count())
        })
        .await
    }

    /// Appends `body` at `offset`, returning the new length. Refuses a part
    /// that does not start exactly where the data ends, so a retried part can
    /// never be written twice.
    pub async fn append<S, B, E>(&self, id: Uuid, offset: u64, body: S) -> Result<u64, AppendError>
    where
        S: Stream<Item = Result<B, E>>,
        B: AsRef<[u8]>,
    {
        let _claim = self.claim(id).ok_or(AppendError::Busy)?;
        let dir = self.session_dir(id);
        let status_dir = dir.clone();
        let (meta, held) = blocking(move || read_status(&status_dir))
            .await
            .map_err(AppendError::Io)?
            .ok_or(AppendError::Missing)?;
        if held != offset {
            return Err(AppendError::OffsetMismatch(held));
        }
        let room = meta.size.saturating_sub(offset).min(UPLOAD_PART_MAX_BYTES);
        let mut file = tokio::fs::OpenOptions::new()
            .append(true)
            .open(dir.join(DATA_FILE))
            .await
            .map_err(AppendError::Io)?;
        let mut running = self.take_running(id, offset);
        let mut body = std::pin::pin!(body);
        let mut written: u64 = 0;
        let mut outcome = Ok(());
        while let Some(chunk) = body.next().await {
            let Ok(chunk) = chunk else {
                outcome = Err(AppendError::Body);
                break;
            };
            let bytes = chunk.as_ref();
            if written + bytes.len() as u64 > room {
                outcome = Err(AppendError::TooLarge);
                break;
            }
            if let Err(err) = file.write_all(bytes).await {
                outcome = Err(AppendError::Io(err));
                break;
            }
            written += bytes.len() as u64;
            if let Some(running) = running.as_mut() {
                running.update(bytes);
            }
        }
        file.flush().await.map_err(AppendError::Io)?;
        if let Some(running) = running {
            self.lock_running().insert(id, running);
        }
        outcome.map(|()| offset + written)
    }

    /// Hashes a complete session and returns what the caller needs to
    /// decide whether to [`place`](Self::place) it. `None` when the session
    /// is missing or still short of its declared size.
    pub async fn finish(&self, id: Uuid) -> Result<Option<FinishedUpload>, AppendError> {
        let _claim = self.claim(id).ok_or(AppendError::Busy)?;
        let dir = self.session_dir(id);
        let status_dir = dir.clone();
        let Some((meta, held)) = blocking(move || read_status(&status_dir))
            .await
            .map_err(AppendError::Io)?
        else {
            return Ok(None);
        };
        if held != meta.size {
            return Ok(None);
        }
        if let Some(running) = self.take_running(id, held).filter(|r| r.offset == held) {
            return Ok(Some(running.finish()));
        }
        blocking(move || hash_file(&dir.join(DATA_FILE)))
            .await
            .map(Some)
            .map_err(AppendError::Io)
    }

    /// Moves a finished session's bytes to their content-hash path, or drops
    /// them when those bytes are already stored, then removes the session.
    pub async fn place(&self, id: Uuid, hex_id: &str) -> io::Result<()> {
        self.lock_running().remove(&id);
        let dir = self.session_dir(id);
        let final_path = self.attachments_dir.join(hex_id);
        blocking(move || {
            if !final_path.exists() {
                std::fs::rename(dir.join(DATA_FILE), &final_path)?;
            }
            remove_dir(&dir)
        })
        .await
    }

    pub async fn discard(&self, id: Uuid) -> io::Result<()> {
        self.lock_running().remove(&id);
        let dir = self.session_dir(id);
        blocking(move || remove_dir(&dir)).await
    }

    /// Removes sessions older than [`UPLOAD_SESSION_TTL`] and any directory
    /// without readable metadata; returns how many went.
    pub async fn sweep_expired(&self, now_ms: i64) -> io::Result<usize> {
        let dir = self.dir.clone();
        let in_flight = self.in_flight.clone();
        let running = self.running.clone();
        let cutoff = now_ms - UPLOAD_SESSION_TTL.as_millis() as i64;
        blocking(move || {
            let mut removed = 0;
            for entry in std::fs::read_dir(&dir)? {
                let path = entry?.path();
                let id = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .and_then(|n| Uuid::parse_str(n).ok());
                let busy = id.is_some_and(|id| {
                    in_flight
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .contains(&id)
                });
                let expired = read_meta(&path).is_none_or(|meta| meta.created_at < cutoff);
                if expired && !busy {
                    remove_dir(&path)?;
                    if let Some(id) = id {
                        running
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .remove(&id);
                    }
                    removed += 1;
                }
            }
            Ok(removed)
        })
        .await
    }
}

fn read_meta(dir: &Path) -> Option<UploadMeta> {
    let bytes = std::fs::read(dir.join(META_FILE)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn read_status(dir: &Path) -> io::Result<Option<(UploadMeta, u64)>> {
    let Some(meta) = read_meta(dir) else {
        return Ok(None);
    };
    match std::fs::metadata(dir.join(DATA_FILE)) {
        Ok(m) => Ok(Some((meta, m.len()))),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn list_sessions(dir: &Path) -> io::Result<impl Iterator<Item = (PathBuf, UploadMeta)>> {
    Ok(std::fs::read_dir(dir)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let path = entry.path();
            read_meta(&path).map(|meta| (path, meta))
        }))
}

fn hash_file(path: &Path) -> io::Result<FinishedUpload> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    let mut size: u64 = 0;
    let mut prefix = Vec::with_capacity(SNIFF_PREFIX_BYTES);
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        if prefix.len() < SNIFF_PREFIX_BYTES {
            let take = (SNIFF_PREFIX_BYTES - prefix.len()).min(n);
            prefix.extend_from_slice(&buf[..take]);
        }
        hasher.update(&buf[..n]);
        size += n as u64;
    }
    Ok(FinishedUpload {
        hex_id: to_hex(&hasher.finalize()),
        size,
        sniff_prefix: prefix,
    })
}

fn remove_dir(dir: &Path) -> io::Result<()> {
    match std::fs::remove_dir_all(dir) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> io::Result<T> + Send + 'static,
) -> io::Result<T> {
    tokio::task::spawn_blocking(f)
        .await
        .unwrap_or_else(|e| Err(io::Error::other(e)))
}

#[cfg(test)]
mod tests;
