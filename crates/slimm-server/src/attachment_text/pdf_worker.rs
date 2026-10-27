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
const MEMORY_LIMIT_BYTES: u64 = 1024 * 1024 * 1024;
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
    Limited,
    /// The child could not be started; worth trying again later.
    Unavailable,
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
            std::env::current_exe()?,
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
        _ => {
            let _ = child.kill().await;
            PdfParse::Limited
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
