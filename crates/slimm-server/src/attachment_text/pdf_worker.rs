// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! PDF parsing in a child process of this same binary.
//!
//! lopdf inflates every stream without a bound, so a small hostile file can
//! ask for gigabytes. In a child the damage is capped by the kernel (address
//! space and CPU rlimits set before the first byte is read) and by a wall
//! clock the parent enforces with a kill. The server itself never parses.

use std::ffi::OsString;
use std::io;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, Command};
use tokio::sync::Semaphore;

use super::extract::{Kind, MAX_PDF_BYTES, extract};

/// The hidden subcommand `main` routes to [`run_pdf_worker`].
pub const WORKER_ARG: &str = "--extract-pdf-text";
/// Well under the 512 MiB the compose file gives the whole container, so the cgroup OOM killer never has to choose.
const MEMORY_LIMIT_BYTES: u64 = 192 * 1024 * 1024;
const CPU_LIMIT_SECONDS: u64 = 15;
const WALL_LIMIT: Duration = Duration::from_secs(20);
const MAX_OUTPUT_BYTES: u64 = 1024 * 1024;

/// One parse at a time, so abandoned or slow children cannot pile up.
static SLOT: Semaphore = Semaphore::const_new(1);

/// How a parse ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PdfParse {
    Text(String),
    /// The child finished and found no text.
    NoText,
    /// The child hit a limit or crashed: the file is hostile or hopeless.
    Limited(Limit),
    /// The child could not be started; worth trying again later.
    Unavailable,
}

/// Why a child was stopped, so a big honest PDF is told apart from a broken one in the log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Limit {
    /// Killed by the memory or CPU rlimit (an allocation failure aborts, the CPU limit signals).
    Resources,
    /// Still running when the parent's wall clock ran out.
    WallClock,
    /// Exited with an error or died some other way.
    Failed,
}

#[derive(Debug, Clone)]
pub struct PdfWorker {
    program: PathBuf,
    args: Vec<OsString>,
    wall_limit: Duration,
}

impl PdfWorker {
    /// This binary re-run as the PDF worker.
    pub fn current_exe() -> io::Result<Self> {
        Ok(Self::command(
            own_executable()?,
            vec![WORKER_ARG.into()],
            WALL_LIMIT,
        ))
    }

    /// An arbitrary worker command, so a test can aim at the built binary or a stand-in.
    pub fn command(program: PathBuf, args: Vec<OsString>, wall_limit: Duration) -> Self {
        Self {
            program,
            args,
            wall_limit,
        }
    }

    /// Waits for the single slot, then runs `before_parse` once the child is
    /// up and before it is fed, so the caller can record the attempt first.
    pub async fn parse<F, Fut>(&self, bytes: Vec<u8>, before_parse: F) -> PdfParse
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = ()>,
    {
        let Ok(_slot) = SLOT.acquire().await else {
            return PdfParse::Unavailable;
        };
        let spawned = Command::new(&self.program)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(err) => {
                tracing::warn!(error = %err, "could not start the pdf worker");
                return PdfParse::Unavailable;
            }
        };
        before_parse().await;
        collect(&mut child, bytes, self.wall_limit).await
    }
}

/// `/proc/self/exe` keeps working after the binary on disk is replaced, where `current_exe` yields a " (deleted)" path.
#[cfg(target_os = "linux")]
pub(super) fn own_executable() -> io::Result<PathBuf> {
    Ok(PathBuf::from("/proc/self/exe"))
}

#[cfg(not(target_os = "linux"))]
pub(super) fn own_executable() -> io::Result<PathBuf> {
    std::env::current_exe()
}

#[cfg(unix)]
fn limit_of(status: std::process::ExitStatus) -> Limit {
    use std::os::unix::process::ExitStatusExt;
    match status.signal() {
        Some(libc::SIGABRT | libc::SIGXCPU | libc::SIGKILL) => Limit::Resources,
        _ => Limit::Failed,
    }
}

#[cfg(not(unix))]
fn limit_of(_status: std::process::ExitStatus) -> Limit {
    Limit::Failed
}

async fn collect(child: &mut Child, bytes: Vec<u8>, wall_limit: Duration) -> PdfParse {
    let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return PdfParse::Unavailable;
    };
    let mut out = Vec::new();
    let run = async {
        let feed = async move {
            let _ = stdin.write_all(&bytes).await;
        };
        let mut limited = stdout.take(MAX_OUTPUT_BYTES);
        let (_, read) = tokio::join!(feed, limited.read_to_end(&mut out));
        match read {
            Ok(_) => child.wait().await,
            Err(err) => Err(err),
        }
    };
    let status = tokio::time::timeout(wall_limit, run).await;
    match status {
        Ok(Ok(status)) if status.success() => match String::from_utf8(out) {
            Ok(text) if !text.is_empty() => PdfParse::Text(text),
            _ => PdfParse::NoText,
        },
        Ok(Ok(status)) => PdfParse::Limited(limit_of(status)),
        Err(_) => {
            let _ = child.kill().await;
            PdfParse::Limited(Limit::WallClock)
        }
        Ok(Err(_)) => {
            let _ = child.kill().await;
            PdfParse::Limited(Limit::Failed)
        }
    }
}

/// The child's side: limits first, then PDF bytes on stdin and text on stdout.
pub fn run_pdf_worker() -> anyhow::Result<()> {
    use std::io::{Read, Write};
    apply_limits()?;
    let mut bytes = Vec::new();
    std::io::stdin()
        .lock()
        .take(MAX_PDF_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_PDF_BYTES {
        return Ok(());
    }
    if let Some(text) = extract(Kind::Pdf, &bytes) {
        std::io::stdout().lock().write_all(text.as_bytes())?;
    }
    Ok(())
}

#[cfg(unix)]
fn apply_limits() -> anyhow::Result<()> {
    // The resource constant's type differs between glibc and musl, so a macro rather than a function.
    macro_rules! limit {
        ($resource:expr, $value:expr) => {{
            let limit = libc::rlimit {
                rlim_cur: $value as libc::rlim_t,
                rlim_max: $value as libc::rlim_t,
            };
            // SAFETY: `limit` is a valid rlimit that outlives the call.
            if unsafe { libc::setrlimit($resource, &limit) } != 0 {
                return Err(io::Error::last_os_error().into());
            }
        }};
    }
    limit!(libc::RLIMIT_AS, MEMORY_LIMIT_BYTES);
    limit!(libc::RLIMIT_CPU, CPU_LIMIT_SECONDS);
    limit!(libc::RLIMIT_CORE, 0u64);
    Ok(())
}

#[cfg(not(unix))]
fn apply_limits() -> anyhow::Result<()> {
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn the_worker_binary_is_resolved_through_proc_not_a_path_that_can_go_stale() {
        let path = own_executable().unwrap();
        assert_eq!(path, PathBuf::from("/proc/self/exe"));
        assert_eq!(
            std::fs::canonicalize(path).unwrap(),
            std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap()
        );
    }
}
