// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Server log files on the data volume: one or more per UTC day, bounded by
//! age and by total size. `recent.rs` reads them back for a download.

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufWriter, Write};
use std::path::{Path, PathBuf};

use jiff::civil::Date;
use jiff::tz::TimeZone;
use jiff::{Span, Timestamp};

const PREFIX: &str = "slimm-server.";
const SUFFIX: &str = ".log";

/// How much log history the directory may hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileLimits {
    /// A file from this many days ago or earlier is deleted.
    pub keep_days: u32,
    /// Every log file together stays at or under this many bytes.
    pub max_total_bytes: u64,
    /// A file is closed and the next one started once it reaches this size.
    pub max_file_bytes: u64,
}

impl FileLimits {
    /// Splits `max_total_bytes` into eight files of at most 32 MiB each.
    pub fn new(keep_days: u32, max_total_bytes: u64) -> Self {
        Self {
            keep_days: keep_days.max(1),
            max_total_bytes,
            max_file_bytes: (max_total_bytes / 8).clamp(1, 32 * 1024 * 1024),
        }
    }
}

#[derive(Debug)]
pub(super) struct LogFile {
    pub(super) path: PathBuf,
    pub(super) day: Date,
    pub(super) index: u32,
    pub(super) bytes: u64,
}

struct Current {
    file: BufWriter<File>,
    day: Date,
    bytes: u64,
}

/// The append side: the file being written now, and the pruning of old ones.
pub struct RollingFiles {
    dir: PathBuf,
    limits: FileLimits,
    current: Option<Current>,
    warned: bool,
}

impl RollingFiles {
    pub fn open(dir: &Path, limits: FileLimits) -> io::Result<Self> {
        create_private_dir(dir)?;
        Ok(Self {
            dir: dir.to_owned(),
            limits,
            current: None,
            warned: false,
        })
    }

    pub fn append(&mut self, line: &[u8], now: Timestamp) -> io::Result<()> {
        let day = now.to_zoned(TimeZone::UTC).date();
        let max_file_bytes = self.limits.max_file_bytes;
        let full = |c: &Current| c.day != day || c.bytes >= max_file_bytes;
        let current = match self.current.take() {
            Some(current) if !full(&current) => current,
            stale => {
                if let Some(mut stale) = stale {
                    stale.file.flush()?;
                }
                self.start(day)?
            }
        };
        let current = self.current.insert(current);
        current.file.write_all(line)?;
        current.bytes += line.len() as u64;
        Ok(())
    }

    pub fn flush(&mut self) -> io::Result<()> {
        match &mut self.current {
            Some(current) => current.file.flush(),
            None => Ok(()),
        }
    }

    /// Reuses today's newest file while it has room, so a restart keeps appending to it.
    fn start(&mut self, day: Date) -> io::Result<Current> {
        create_private_dir(&self.dir)?;
        let newest = list(&self.dir)?
            .into_iter()
            .filter(|f| f.day == day)
            .max_by_key(|f| f.index);
        let (index, bytes) = match newest {
            Some(f) if f.bytes < self.limits.max_file_bytes => (f.index, f.bytes),
            Some(f) => (f.index + 1, 0),
            None => (0, 0),
        };
        let path = self.dir.join(file_name(day, index));
        let file = open_private_append(&path)?;
        if let Err(error) = self.prune(day, &path) {
            self.warn_once(&error);
        }
        Ok(Current {
            file: BufWriter::new(file),
            day,
            bytes,
        })
    }

    /// Best effort: a file that cannot be deleted is skipped, and logging goes on.
    fn warn_once(&mut self, error: &io::Error) {
        if !self.warned {
            self.warned = true;
            tracing::warn!(%error, dir = ?self.dir, "could not delete an old server log file");
        }
    }

    /// Leaves room for the current file to fill, so the total bound holds between rotations too.
    /// A file dated after today comes from a clock that ran ahead, and goes first.
    fn prune(&self, today: Date, current: &Path) -> io::Result<()> {
        let cutoff = today
            .checked_sub(Span::new().days(i64::from(self.limits.keep_days)))
            .unwrap_or(Date::MIN);
        let mut older: Vec<LogFile> = list(&self.dir)?
            .into_iter()
            .filter(|f| f.path != current)
            .collect();
        older.sort_by_key(|f| (f.day <= today, f.day, f.index));
        let budget = self
            .limits
            .max_total_bytes
            .saturating_sub(self.limits.max_file_bytes);
        let mut total: u64 = older.iter().map(|f| f.bytes).sum();
        let mut failed = None;
        for file in older {
            let in_range = file.day > cutoff && file.day <= today;
            if in_range && total <= budget {
                continue;
            }
            match fs::remove_file(&file.path) {
                Ok(()) => total = total.saturating_sub(file.bytes),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    total = total.saturating_sub(file.bytes);
                }
                Err(error) => failed = failed.or(Some(error)),
            }
        }
        failed.map_or(Ok(()), Err)
    }
}

fn file_name(day: Date, index: u32) -> String {
    format!("{PREFIX}{day}.{index:03}{SUFFIX}")
}

fn parse_name(name: &str) -> Option<(Date, u32)> {
    let stem = name.strip_prefix(PREFIX)?.strip_suffix(SUFFIX)?;
    let (day, index) = stem.split_once('.')?;
    Some((day.parse().ok()?, index.parse().ok()?))
}

/// The log files in `dir`; an entry that vanishes or cannot be read while listing is skipped.
pub(super) fn list(dir: &Path) -> io::Result<Vec<LogFile>> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir)?.flatten() {
        let name = entry.file_name();
        let Some((day, index)) = name.to_str().and_then(parse_name) else {
            continue;
        };
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if !metadata.is_file() {
            continue;
        }
        files.push(LogFile {
            path: entry.path(),
            day,
            index,
            bytes: metadata.len(),
        });
    }
    Ok(files)
}

/// Sets 0700 only on a directory it creates, so an operator's own shared directory keeps its mode.
fn create_private_dir(dir: &Path) -> io::Result<()> {
    if dir.is_dir() {
        return Ok(());
    }
    fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn open_private_append(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[cfg(test)]
pub(super) mod tests;
