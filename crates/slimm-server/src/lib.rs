// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! slim-m home server.
//!
//! The binary in `main.rs` is a thin wrapper; the server logic lives here as a
//! library so it can be exercised by integration tests.

mod attachment_text;
pub mod auth;
pub mod blobs;
pub mod bot_ui;
pub mod call_history;
pub mod code_runner;
pub mod components;
pub mod config;
pub mod cors;
pub mod data_key;
pub mod db;
pub mod emoji;
pub mod ephemeral;
pub mod export;
mod forward_backfill;
mod forward_events;
pub(crate) mod hidden_chars;
pub mod http;
pub mod hub;
pub mod identity;
pub mod ids;
pub mod limits;
pub mod media;
pub mod mentions;
pub mod module_runtime;
mod net_guard;
pub mod notifications;
pub use notifications::notification_schedule;
pub mod permissions;
pub mod presence;
pub use presence::presence_activity;
pub use presence::typing;
pub use presence::viewing;
mod process_metrics;
pub mod push;
pub mod ratelimit;
pub mod room_cleanup;
mod sidecar_url;
pub mod store;
mod sweeps;
pub mod totp;
pub mod voice;
mod voice_session_sweeps;

pub use attachment_text::WORKER_ARG as PDF_WORKER_ARG;
pub use attachment_text::{Limit, PdfParse, PdfWorker, TextExtractor, run_pdf_worker};
pub use sweeps::{
    run_attachment_sweep_pass, run_message_retention_sweep_pass, run_token_sweep_pass,
    sweep_stale_call_rings, sweep_stale_call_rings_at, sweep_stale_voice_calls,
    sweep_stale_voice_calls_at,
};
pub use voice_session_sweeps::{close_stale_sessions, reconcile_on_startup};

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
    let allow_new_key = std::env::var("SLIMM_DATA_KEY_ALLOW_NEW").is_ok_and(|v| v == "1");
    let data_key = data_key::DataKey::load_guarded(
        config.data_key.as_deref(),
        &config.database_path,
        store.has_sealed_secrets().await?,
        allow_new_key,
    )?;
    let store = store.with_data_key(data_key);
    let store = match &config.modules_dir {
        Some(dir) => store.with_modules_dir(dir.into()),
        None => store,
    };
    store.seal_totp_secrets().await?;
    log_server_identity(&store).await?;
    warn_if_unclaimed(&store).await?;
    sweeps::spawn_token_sweep(store.clone());
    let media = media::Media::new(config.attachments_dir.clone(), config.attachment_max_bytes)?
        .with_total_ceiling(config.max_total_attachment_bytes);
    sweeps::spawn_attachment_sweep(store.clone(), media.clone());
    export::spawn_export_sweep(store.clone(), media.clone());
    sweeps::spawn_canvas_op_sweep(store.clone());
    forward_backfill::spawn_forward_backfill(store.clone(), media.clone());
    attachment_text::spawn_attachment_text_sweep(store.clone(), media.clone());
    let auth = auth::Auth::new(config.hash_concurrency)?;
    let hub = hub::Hub::new();
    tracing::info!(
        trust_proxy_hops = config.trust_proxy_hops,
        "rate limits key on the TCP peer unless SLIMM_TRUST_PROXY_HOPS names the proxies in front"
    );
    let limiter = ratelimit::RateLimiter::with_trusted_hops(config.trust_proxy_hops);
    let push = push::PushSender::new(&config)?;
    let voice = voice::VoiceService::new(&config)?;
    voice_session_sweeps::reconcile_on_startup(&store).await;
    sweeps::spawn_call_sweep(store.clone(), voice.clone(), hub.clone());
    voice_session_sweeps::spawn_retention_sweep(store.clone());
    sweeps::spawn_call_history_sweep(store.clone());
    sweeps::spawn_room_sweep(store.clone(), voice.clone(), hub.clone());
    sweeps::spawn_ring_sweep(voice.clone(), hub.clone(), store.clone(), push.clone());
    sweeps::spawn_message_retention_sweep(store.clone(), media.clone(), hub.clone());
    let gifs = http::gifs::GifSearch::new(&config)?;
    let link_previews =
        http::link_preview::LinkPreviews::new(&config, store.link_preview_image_key().await?);
    link_previews.set_override(store.link_previews_override().await?);
    let dock = http::dock::Dock::new(&config);
    let code_runner = code_runner::CodeRunner::new(&config)?;
    let state = http::AppState {
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
    };
    sweeps::spawn_module_schedule_sweep(state.clone());
    let _module_events = http::spawn_module_events(state.clone());
    let mut router = http::router(state);
    if let Some(discord) = http::linked_accounts::DiscordLinks::new(&config)? {
        router = router.layer(axum::Extension(discord));
    }
    let app = cors.apply(router);
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
