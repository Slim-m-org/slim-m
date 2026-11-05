// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reading the status the backup container writes (`scripts/backup-nightly.py`).
//!
//! The server only ever reads this file. Running the backup is the container's job, so a
//! compromised server cannot rewrite history and a stuck backup cannot stall the server.

use std::path::Path;

use serde::Deserialize;

/// A verified backup older than this is stale: two missed nightly runs.
pub const STALE_AFTER_MS: i64 = 48 * 60 * 60 * 1000;

const STATUS_FILE: &str = "status.json";
const MAX_ERROR_CHARS: usize = 300;

#[derive(Debug, Deserialize)]
struct StatusFile {
    ok: bool,
    #[serde(default)]
    error: Option<String>,
    #[serde(default)]
    last_verified_at_ms: Option<i64>,
    #[serde(default)]
    last_verified_bytes: Option<i64>,
}

/// What the status directory says, before any judgement about age.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackupState {
    /// No status directory is configured, so there is nothing to read.
    NotConfigured,
    /// Configured, but no run has written a status yet.
    Never,
    /// The newest run failed verification or could not finish.
    Failed(String),
    /// The newest run passed its restore drill.
    Verified,
    /// A status file exists but cannot be parsed.
    Unreadable,
}

/// The last verified backup and how the newest run went.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupReport {
    pub state: BackupState,
    pub verified_at_ms: Option<i64>,
    pub verified_bytes: Option<i64>,
}

impl BackupReport {
    pub fn not_configured() -> Self {
        Self::bare(BackupState::NotConfigured)
    }

    fn bare(state: BackupState) -> Self {
        Self {
            state,
            verified_at_ms: None,
            verified_bytes: None,
        }
    }

    /// Reads `<dir>/status.json`. A missing file is `Never`, a broken one `Unreadable`.
    pub fn read(dir: Option<&str>) -> Self {
        let Some(dir) = dir else {
            return Self::not_configured();
        };
        let text = match std::fs::read_to_string(Path::new(dir).join(STATUS_FILE)) {
            Ok(text) => text,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return Self::bare(BackupState::Never);
            }
            Err(_) => return Self::bare(BackupState::Unreadable),
        };
        match serde_json::from_str::<StatusFile>(&text) {
            Ok(file) => Self::from_file(file),
            Err(_) => Self::bare(BackupState::Unreadable),
        }
    }

    fn from_file(file: StatusFile) -> Self {
        let state = if file.ok {
            BackupState::Verified
        } else {
            let error = file.error.unwrap_or_default();
            BackupState::Failed(error.chars().take(MAX_ERROR_CHARS).collect())
        };
        Self {
            state,
            verified_at_ms: file.last_verified_at_ms,
            verified_bytes: file.last_verified_bytes,
        }
    }

    /// Whether the last verified backup is older than [`STALE_AFTER_MS`].
    pub fn is_stale(&self, now_ms: i64) -> bool {
        match self.state {
            BackupState::NotConfigured | BackupState::Never => false,
            _ => self
                .verified_at_ms
                .is_none_or(|at| now_ms - at > STALE_AFTER_MS),
        }
    }

    /// The sentence an alert carries, or `None` when nothing needs attention.
    pub fn problem(&self, now_ms: i64) -> Option<String> {
        match &self.state {
            BackupState::Failed(error) => Some(if error.is_empty() {
                "The nightly backup failed.".to_owned()
            } else {
                format!("The nightly backup failed: {error}")
            }),
            BackupState::Unreadable => Some("The backup status file cannot be read.".to_owned()),
            _ if self.is_stale(now_ms) => {
                Some("No verified backup in the last 48 hours.".to_owned())
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &std::path::Path, body: &str) {
        std::fs::write(dir.join(STATUS_FILE), body).unwrap();
    }

    struct Dir(std::path::PathBuf);

    impl Dir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("slimm-backup-status-{}", uuid::Uuid::now_v7()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> Option<&str> {
            self.0.to_str()
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn no_directory_is_not_configured_and_never_a_problem() {
        let report = BackupReport::read(None);
        assert_eq!(report.state, BackupState::NotConfigured);
        assert_eq!(report.problem(i64::MAX), None);
    }

    #[test]
    fn an_empty_directory_is_never_and_not_a_problem() {
        let dir = Dir::new();
        let report = BackupReport::read(dir.path());
        assert_eq!(report.state, BackupState::Never);
        assert_eq!(report.problem(i64::MAX), None);
    }

    #[test]
    fn a_fresh_pass_is_verified_and_quiet() {
        let dir = Dir::new();
        write(
            &dir.0,
            r#"{"ok":true,"last_verified_at_ms":1000,"last_verified_bytes":42}"#,
        );
        let report = BackupReport::read(dir.path());
        assert_eq!(report.state, BackupState::Verified);
        assert_eq!(report.verified_bytes, Some(42));
        assert_eq!(report.problem(1000 + STALE_AFTER_MS), None);
    }

    #[test]
    fn a_pass_older_than_48_hours_is_stale() {
        let dir = Dir::new();
        write(&dir.0, r#"{"ok":true,"last_verified_at_ms":1000}"#);
        let report = BackupReport::read(dir.path());
        assert!(report.problem(1001 + STALE_AFTER_MS).is_some());
    }

    #[test]
    fn a_failure_keeps_the_last_good_time_and_names_the_error() {
        let dir = Dir::new();
        write(
            &dir.0,
            r#"{"ok":false,"error":"drill: FAIL","last_verified_at_ms":5}"#,
        );
        let report = BackupReport::read(dir.path());
        assert_eq!(report.state, BackupState::Failed("drill: FAIL".into()));
        assert_eq!(report.verified_at_ms, Some(5));
        assert!(report.problem(6).unwrap().contains("drill: FAIL"));
    }

    #[test]
    fn garbage_is_unreadable_and_a_problem() {
        let dir = Dir::new();
        write(&dir.0, "not json");
        let report = BackupReport::read(dir.path());
        assert_eq!(report.state, BackupState::Unreadable);
        assert!(report.problem(0).is_some());
    }
}
