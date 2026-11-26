// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The call-audio listener (decision 0105). Audio is held in memory only and
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
    let mut control = Control::new(Arc::clone(&config), pool, launcher);
    if let Some(speaker) = load_speaker(&config)? {
        control = control.with_speaker(speaker);
    }
    let app = control.router();
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

#[cfg(feature = "livekit-room")]
fn load_speaker(config: &Config) -> anyhow::Result<Option<slimm_listener::speak::Speaker>> {
    let Some(piper) = &config.piper else {
        return Ok(None);
    };
    tracing::info!(voice = %piper.model.display(), "speech enabled");
    Ok(Some(slimm_listener::speak::Speaker {
        synthesizer: Arc::new(slimm_listener::piper::Piper::new(
            piper.bin.clone(),
            piper.model.clone(),
        )?),
        stage: Arc::new(slimm_listener::stage::LiveKitStage),
    }))
}

#[cfg(not(feature = "livekit-room"))]
fn load_speaker(_: &Config) -> anyhow::Result<Option<slimm_listener::speak::Speaker>> {
    Ok(None)
}
