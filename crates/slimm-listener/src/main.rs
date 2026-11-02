// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The call-audio listener (decision 0104). Audio is held in memory only and
//! never written anywhere; what leaves this process is text.

use std::sync::Arc;

use slimm_listener::config::Config;
use slimm_listener::control::Control;
use slimm_listener::stt::Pool;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("LISTENER_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    let config = Arc::new(Config::from_env()?);
    let transcriber = load_transcriber(&config)?;
    let pool = Arc::new(Pool::new(transcriber, config.threads));
    let launcher = slimm_listener::launch::real()?;
    let app = Control::new(Arc::clone(&config), pool, launcher).router();
    let listener = tokio::net::TcpListener::bind(config.listen).await?;
    tracing::info!(addr = %config.listen, model = %config.model.display(), "listening");
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}

#[cfg(feature = "whisper")]
fn load_transcriber(config: &Config) -> anyhow::Result<Arc<dyn slimm_listener::stt::Transcriber>> {
    Ok(Arc::new(slimm_listener::stt::WhisperTranscriber::load(
        &config.model,
    )?))
}

#[cfg(not(feature = "whisper"))]
fn load_transcriber(_: &Config) -> anyhow::Result<Arc<dyn slimm_listener::stt::Transcriber>> {
    anyhow::bail!("this build has no speech engine; build with the whisper feature")
}
