// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The server's one logging component (decision 0129): stdout for docker, the
//! same lines in rotating files on the data volume, and a detail mode a space
//! admin switches at runtime without a restart.

mod files;
mod format;
mod recent;
mod sink;
mod throttle;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use tracing::Dispatch;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, Registry, fmt, reload};

pub use files::{FileLimits, RollingFiles};
pub use recent::{RecentPlan, Segment, plan_recent, read_plan, read_segment};

use crate::config::Config;

/// How much the server logs beyond the operator's `SLIMM_LOG` filter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LogMode {
    /// `SLIMM_LOG` as set, `info` when unset: warnings, errors and lifecycle events.
    #[default]
    Off,
    /// Debug lines from the subsystems bug hunts start in, one short line each.
    Compact,
    /// Everything slim-m writes, down to trace, with source locations.
    Verbose,
}

impl LogMode {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "off" => Some(Self::Off),
            "compact" => Some(Self::Compact),
            "verbose" => Some(Self::Verbose),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Compact => "compact",
            Self::Verbose => "verbose",
        }
    }

    fn from_u8(raw: u8) -> Self {
        match raw {
            1 => Self::Compact,
            2 => Self::Verbose,
            _ => Self::Off,
        }
    }

    fn to_u8(self) -> u8 {
        match self {
            Self::Off => 0,
            Self::Compact => 1,
            Self::Verbose => 2,
        }
    }

    fn directives(self) -> &'static [&'static str] {
        match self {
            Self::Off => &[],
            Self::Compact => COMPACT_DIRECTIVES,
            Self::Verbose => VERBOSE_DIRECTIVES,
        }
    }
}

/// Calls and voice, sync and the socket, sign-in, push and media, plus one line per HTTP request.
/// A target matches by string prefix, so `voice` also takes `voice_transcripts` and `voice_notify`.
const COMPACT_DIRECTIVES: &[&str] = &[
    "slimm_server::voice=debug",
    "slimm_server::http::voice=debug",
    "slimm_server::call_audio=debug",
    "slimm_server::sweeps=debug",
    "slimm_server::http::ws=debug",
    "slimm_server::hub=debug",
    "slimm_server::presence=debug",
    "slimm_server::http::sync=debug",
    "slimm_server::http::read_states=debug",
    "slimm_server::http::read_sync=debug",
    "slimm_server::auth=debug",
    "slimm_server::http::auth=debug",
    "slimm_server::http::totp=debug",
    "slimm_server::http::reauth=debug",
    "slimm_server::push=debug",
    "slimm_server::http::push=debug",
    "slimm_server::media=debug",
    "slimm_server::http::attachment=debug",
    "slimm_server::logging=debug",
    "tower_http::trace::on_response=debug",
];

const VERBOSE_DIRECTIVES: &[&str] = &["slimm_server=trace", "tower_http=trace"];

/// The most debug or trace lines one call site writes per second.
const DEBUG_LINES_PER_SECOND: u32 = 50;

/// Where the logs go and how much of them is kept.
#[derive(Clone, Debug)]
pub struct LogSettings {
    /// `SLIMM_LOG`, the floor every mode adds to.
    pub base_filter: String,
    /// None keeps the logs on stdout only.
    pub dir: Option<PathBuf>,
    pub limits: FileLimits,
}

impl LogSettings {
    pub fn from_config(config: &Config) -> Self {
        let base_filter = std::env::var("SLIMM_LOG").unwrap_or_default();
        let dir = match (&config.log_dir, config.log_max_bytes) {
            (_, 0) => None,
            (Some(dir), _) => Some(PathBuf::from(dir)),
            (None, _) => Some(beside_database(&config.database_path)),
        };
        Self {
            base_filter,
            dir,
            limits: FileLimits::new(config.log_keep_days, config.log_max_bytes),
        }
    }
}

fn beside_database(database_path: &str) -> PathBuf {
    match Path::new(database_path).parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join("logs"),
        _ => PathBuf::from("logs"),
    }
}

/// A built logging stack and the handles that change it while it runs.
pub struct Logging {
    filter: reload::Handle<EnvFilter, Registry>,
    /// Holds the filter and the layout to one mode while either changes.
    switching: Mutex<()>,
    base: String,
    mode: Arc<AtomicU8>,
    files: Option<sink::FileSink>,
    dir: Option<PathBuf>,
    throttled: Arc<AtomicU64>,
}

/// What [`Logging::build`] made, before anything is installed.
pub struct Built {
    pub logging: Logging,
    pub dispatch: Dispatch,
    /// Why the files could not be opened; the stack then writes stdout only.
    pub file_error: Option<std::io::Error>,
}

impl Logging {
    /// `stdout` false leaves only the files, for a test that reads them back.
    pub fn build(settings: &LogSettings, stdout: bool) -> Built {
        let base = valid_base(&settings.base_filter);
        let (filter, handle) = reload::Layer::new(filter_for(&base, LogMode::Off));
        let mode = Arc::new(AtomicU8::new(LogMode::Off.to_u8()));
        let throttled = Arc::new(AtomicU64::new(0));
        let (files, file_error) = match &settings.dir {
            Some(dir) => {
                match RollingFiles::open(dir, settings.limits).and_then(sink::FileSink::spawn) {
                    Ok(sink) => (Some(sink), None),
                    Err(error) => (None, Some(error)),
                }
            }
            None => (None, None),
        };
        let stdout_layer =
            stdout.then(|| fmt::layer().event_format(format::ModeFormat::new(mode.clone())));
        let file_layer = files.clone().map(|sink| {
            fmt::layer()
                .fmt_fields(format::PlainFields::default())
                .event_format(format::ModeFormat::new(mode.clone()))
                .with_ansi(false)
                .with_writer(sink)
        });
        let subscriber = Registry::default()
            .with(filter)
            .with(throttle::Throttle::new(
                DEBUG_LINES_PER_SECOND,
                mode.clone(),
                throttled.clone(),
            ))
            .with(stdout_layer)
            .with(file_layer);
        Built {
            logging: Self {
                filter: handle,
                switching: Mutex::new(()),
                base,
                mode,
                dir: files.as_ref().and(settings.dir.clone()),
                files,
                throttled,
            },
            dispatch: Dispatch::new(subscriber),
            file_error,
        }
    }

    pub fn mode(&self) -> LogMode {
        LogMode::from_u8(self.mode.load(Ordering::Relaxed))
    }

    /// Swaps the filter and the line layout in place; the next event already follows it.
    pub fn set_mode(&self, mode: LogMode) {
        let _switching = self
            .switching
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Err(error) = self.filter.reload(filter_for(&self.base, mode)) {
            tracing::warn!(%error, "could not change the server log filter");
            return;
        }
        let before = self.mode.swap(mode.to_u8(), Ordering::Relaxed);
        if before != mode.to_u8() {
            tracing::info!(mode = mode.as_str(), "server logging mode changed");
        }
    }

    /// The directory the files are written to, when they are.
    pub fn dir(&self) -> Option<&Path> {
        self.dir.as_deref()
    }

    /// Returns once every line logged so far is in the files.
    pub fn flush(&self) {
        if let Some(files) = &self.files {
            files.flush();
        }
    }

    /// Says once a minute how many lines the throttle or a full queue dropped.
    pub fn spawn_drop_report(&'static self) {
        tokio::spawn(async move {
            let mut every = tokio::time::interval(Duration::from_secs(60));
            loop {
                every.tick().await;
                let throttled = self.throttled.swap(0, Ordering::Relaxed);
                let queue_full = self.files.as_ref().map_or(0, sink::FileSink::take_dropped);
                if throttled + queue_full > 0 {
                    tracing::info!(
                        throttled,
                        queue_full,
                        "dropped log lines in the last minute"
                    );
                }
            }
        });
    }
}

/// An unparseable `SLIMM_LOG` falls back to `info`, as it always has.
fn valid_base(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() || EnvFilter::try_new(raw).is_err() {
        "info".to_owned()
    } else {
        raw.to_owned()
    }
}

fn filter_for(base: &str, mode: LogMode) -> EnvFilter {
    let directives = std::iter::once(base)
        .chain(mode.directives().iter().copied())
        .collect::<Vec<_>>()
        .join(",");
    EnvFilter::try_new(directives).unwrap_or_else(|_| EnvFilter::new(base))
}

static INSTALLED: OnceLock<Logging> = OnceLock::new();

/// Installs the stack as the process's global subscriber, once.
pub fn install(settings: &LogSettings) -> anyhow::Result<&'static Logging> {
    let built = Logging::build(settings, true);
    built.dispatch.try_init()?;
    let logging = INSTALLED.get_or_init(|| built.logging);
    if let Some(error) = built.file_error {
        tracing::warn!(%error, dir = ?settings.dir, "server logs go to stdout only");
    }
    if let Some(dir) = logging.dir().filter(|dir| readable_by_others(dir)) {
        tracing::warn!(?dir, "the server log directory is readable by other users");
    }
    Ok(logging)
}

#[cfg(unix)]
fn readable_by_others(dir: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(dir).is_ok_and(|m| m.permissions().mode() & 0o077 != 0)
}

#[cfg(not(unix))]
fn readable_by_others(_dir: &Path) -> bool {
    false
}

static MODE_CHANGE: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Held across storing a new mode and applying it, so two admins changing it
/// at once cannot leave the stored mode and the running one apart.
pub async fn mode_change() -> tokio::sync::MutexGuard<'static, ()> {
    MODE_CHANGE.lock().await
}

/// Today's date in UTC, the calendar the log files are named in.
pub fn today() -> jiff::civil::Date {
    jiff::Timestamp::now()
        .to_zoned(jiff::tz::TimeZone::UTC)
        .date()
}

/// The installed stack; None in tests that never install one.
pub fn installed() -> Option<&'static Logging> {
    INSTALLED.get()
}

/// Applies `mode` to the installed stack, if there is one.
pub fn apply_mode(mode: LogMode) {
    if let Some(logging) = installed() {
        logging.set_mode(mode);
    }
}

#[cfg(test)]
mod tests;
