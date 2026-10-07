// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! slim-m home server.
//!
//! The binary in `main.rs` is a thin wrapper; the server logic lives here as a
//! library so it can be exercised by integration tests.

pub mod auth;
pub mod bot_ui;
pub mod code_runner;
pub mod components;
pub mod config;
pub mod cors;
pub mod db;
pub mod emoji;
pub mod ephemeral;
mod forward_backfill;
mod forward_events;
pub(crate) mod hidden_chars;
pub mod http;
pub mod hub;
pub mod identity;
pub mod ids;
pub mod media;
pub mod mentions;
pub mod module_runtime;
mod net_guard;
pub mod notification_schedule;
pub mod notifications;
pub mod permissions;
pub mod presence;
pub mod presence_activity;
mod process_metrics;
pub mod push;
pub mod ratelimit;
mod sidecar_url;
pub mod store;
mod sweeps;
pub mod totp;
pub mod typing;
pub mod viewing;
pub mod voice;

pub use sweeps::{
    sweep_stale_call_rings, sweep_stale_call_rings_at, sweep_stale_voice_calls,
    sweep_stale_voice_calls_at,
};

use std::net::SocketAddr;

use anyhow::Context as _;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Prints this deployment's identity fingerprint where its operator can read
/// it, in the same eight groups a joining client shows them.
///
/// Trust-on-first-use asks a joiner to confirm that code with whoever runs the
/// server. Until this log line existed that was an unanswerable request: the
/// fingerprint was derived inside `/version` and shown only to clients, so the
/// one person being asked to vouch for it had no copy to compare. It is public
/// information by construction - every client that connects is handed it - so
/// logging it discloses nothing. Generating the keypair on the first call is
/// also why this runs here: the line doubles as the record of when a
/// deployment's identity was established.
async fn log_server_identity(store: &store::Store) -> anyhow::Result<()> {
    let identity = store.server_identity().await?;
    tracing::info!(
        fingerprint = %identity.fingerprint_groups().join(" "),
        "server identity; a joining client shows this code, so confirm it matches"
    );
    Ok(())
}

/// Says so, loudly, while the deployment has no administrator yet.
///
/// The first account to register claims the deployment: it is granted the
/// admin role and seeds `@everyone` and a general channel. Until that
/// happens the invite gate is skipped entirely, because there is nobody to
/// issue an invite. So between `docker compose up` and the operator getting
/// round to registering, whoever reaches `/auth/register` first becomes the
/// permanent administrator - and the stack is already publicly reverse-proxied
/// by then.
///
/// That window is short and usually harmless, but it is invisible, which is
/// the part worth fixing. An operator who reads their own startup log should
/// not have to learn this from the source.
async fn warn_if_unclaimed(store: &store::Store) -> anyhow::Result<()> {
    if !store.is_bootstrapped().await? {
        tracing::warn!(
            "this deployment has no administrator yet; the first account to \
             register claims it, so register yours before sharing the address"
        );
    }
    Ok(())
}

/// Loads configuration, opens the embedded database (running migrations), and
/// serves the HTTP surface until a shutdown signal.
pub async fn run() -> anyhow::Result<()> {
    init_tracing();
    http::panic_guard::install_hook();
    let config = config::Config::from_env()?;
    // Before the database is touched, so a misconfigured origin list is a
    // startup error and not a half-initialized deployment.
    let cors = cors::CorsPolicy::new(&config)?;
    let pool = db::connect(&config).await?;

    let store = store::Store::new(pool);
    log_server_identity(&store).await?;
    warn_if_unclaimed(&store).await?;
    sweeps::spawn_token_sweep(store.clone());
    let media = media::Media::new(config.attachments_dir.clone(), config.attachment_max_bytes)?
        .with_total_ceiling(config.max_total_attachment_bytes);
    sweeps::spawn_attachment_sweep(store.clone(), media.clone());
    sweeps::spawn_canvas_op_sweep(store.clone());
    forward_backfill::spawn_forward_backfill(store.clone(), media.clone());
    let auth = auth::Auth::new(config.hash_concurrency)?;
    let hub = hub::Hub::new();
    let limiter = ratelimit::RateLimiter::with_trusted_hops(config.trust_proxy_hops);
    let push = push::PushSender::new(&config)?;
    let voice = voice::VoiceService::new(&config)?;
    sweeps::spawn_call_sweep(voice.clone(), hub.clone());
    sweeps::spawn_ring_sweep(voice.clone(), hub.clone(), store.clone(), push.clone());
    sweeps::spawn_message_retention_sweep(store.clone(), media.clone(), hub.clone());
    let gifs = http::gifs::GifSearch::new(&config)?;
    let link_previews = http::link_preview::LinkPreviews::new(&config);
    let dock = http::dock::Dock::new(&config);
    let code_runner = code_runner::CodeRunner::new(&config)?;
    let app = cors.apply(http::router(http::AppState {
        store,
        auth,
        hub,
        limiter,
        push,
        voice,
        media,
        gifs,
        link_previews,
        dock,
        code_runner,
    }));
    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding to {addr}"))?;
    tracing::info!(%addr, version = env!("CARGO_PKG_VERSION"), "slim-m server listening");

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;
    Ok(())
}

/// Imports a directory of images as custom emoji, printing a line per file.
///
/// Reads the same `SLIMM_`-prefixed configuration [`run`] does and opens the
/// same database and blob directory, so an operator points it at a deployment
/// by running it where the server runs, with no second place to configure. It
/// is safe to run against a live server: SQLite in WAL mode takes concurrent
/// writers from separate processes, and every emoji is its own transaction.
///
/// Errors if any file did not end up as an emoji, so a script sees a non-zero
/// exit rather than having to parse the report.
pub async fn import_emoji(dir: &std::path::Path) -> anyhow::Result<()> {
    init_tracing_to_stderr();
    let config = config::Config::from_env()?;
    let pool = db::connect(&config).await?;
    let store = store::Store::new(pool);
    let media = media::Media::new(config.attachments_dir.clone(), config.attachment_max_bytes)?
        .with_total_ceiling(config.max_total_attachment_bytes);

    let report = emoji::import::import_directory(&store, &media, dir).await?;
    print!("{report}");

    if !report.is_clean() {
        anyhow::bail!(
            "{} of {} files are not emoji",
            report.unimported(),
            report.files.len()
        );
    }
    Ok(())
}

/// Clears a member's second factor straight in the database, for an operator
/// who has file access and no administrator able to sign in.
///
/// Does what `DELETE /admin/users/{id}/totp` does: removes the factor and its
/// recovery codes, revokes every session, and writes a `totp_cleared` audit row
/// with no actor, since nobody was signed in. Safe beside a running server for
/// the same reason [`import_emoji`] is.
pub async fn clear_totp(username: &str) -> anyhow::Result<()> {
    init_tracing_to_stderr();
    let config = config::Config::from_env()?;
    let pool = db::connect(&config).await?;
    let store = store::Store::new(pool);

    let Some(user_id) = store.live_user_id_by_username(username).await? else {
        anyhow::bail!("no account is named {username:?}");
    };
    match store.clear_totp_factor(None, user_id).await {
        Ok(revoked) => {
            println!(
                "cleared two-factor for {username}; signed out {} session(s)",
                revoked.len()
            );
            Ok(())
        }
        Err(store::TotpError::NotEnrolled) => {
            anyhow::bail!("{username:?} has no two-factor authentication to clear")
        }
        Err(other) => anyhow::bail!("could not clear two-factor for {username:?}: {other:?}"),
    }
}

/// Connects to the local server and confirms `/healthz` returns 200. Used by the
/// container image's healthcheck, since distroless has no shell.
pub async fn healthcheck() -> anyhow::Result<()> {
    // Through Config, so the probe cannot disagree with what the server bound.
    let port = config::Config::from_env()?.port;

    let mut stream = TcpStream::connect(("127.0.0.1", port)).await?;
    stream
        .write_all(b"GET /healthz HTTP/1.0\r\nHost: localhost\r\n\r\n")
        .await?;

    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;
    let response = String::from_utf8_lossy(&response);

    if response.starts_with("HTTP/1.0 200") || response.starts_with("HTTP/1.1 200") {
        Ok(())
    } else {
        anyhow::bail!("health check failed: unexpected response")
    }
}

fn init_tracing() {
    init_tracing_to(false);
}

/// Sends logs to stderr instead of stdout.
///
/// The import subcommand prints a machine-readable report on stdout, and at a
/// non-default `SLIMM_LOG` the query logs interleave with it, so anything
/// parsing that report reads corrupted input. Serving keeps stdout, which is
/// what a container's log collector expects.
fn init_tracing_to_stderr() {
    init_tracing_to(true);
}

fn init_tracing_to(stderr: bool) {
    use tracing_subscriber::EnvFilter;
    let filter = EnvFilter::try_from_env("SLIMM_LOG").unwrap_or_else(|_| EnvFilter::new("info"));
    let builder = tracing_subscriber::fmt().with_env_filter(filter);
    if stderr {
        builder.with_writer(std::io::stderr).init();
    } else {
        builder.init();
    }
}

/// Resolves on Ctrl-C or SIGTERM so the container stops cleanly.
async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("install Ctrl-C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }

    tracing::info!("shutdown signal received, stopping");
}
