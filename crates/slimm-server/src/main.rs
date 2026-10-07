// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! slim-m home server binary. All logic lives in the `slimm_server` library;
//! this only picks which entry point an invocation asked for.

/// musl's own allocator cost the shipped image about three times glibc's CPU
/// per delivered message; see docs/dependencies.md for the measurement.
#[global_allocator]
static ALLOCATOR: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

/// Hands a burst's freed pages back to the system within about a second
/// instead of jemalloc's default ten.
#[unsafe(export_name = "_rjem_malloc_conf")]
pub static MALLOC_CONF: &[u8; 63] =
    b"background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:1000\0";

const USAGE: &str =
    "usage: slimm-server [--healthcheck | import-emoji <directory> | clear-totp <username>]";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        // No arguments is the server itself, which is how the container image
        // runs it: the Dockerfile sets an ENTRYPOINT and no CMD.
        None => slimm_server::run().await,
        // `--healthcheck` is how the distroless container image checks liveness.
        Some("--healthcheck") => slimm_server::healthcheck().await,
        Some("import-emoji") => match args.next() {
            Some(dir) => slimm_server::import_emoji(std::path::Path::new(&dir)).await,
            None => anyhow::bail!("import-emoji needs a directory\n{USAGE}"),
        },
        Some("clear-totp") => match args.next() {
            Some(username) => slimm_server::clear_totp(&username).await,
            None => anyhow::bail!("clear-totp needs a username\n{USAGE}"),
        },
        // Refused rather than ignored: an unrecognised argument silently
        // starting a server is how a typo becomes a no-op nobody notices.
        Some(other) => anyhow::bail!("unknown argument {other:?}\n{USAGE}"),
    }
}
