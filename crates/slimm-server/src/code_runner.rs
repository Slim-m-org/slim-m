// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The code-runner broker: this server's half of running a fenced code
//! block through a self-hosted Piston instance (`engineer-man/piston`).
//!
//! **slim-m builds no runner of its own and executes nothing itself.** This
//! module speaks Piston's own existing `POST /api/v2/execute` and
//! `GET /api/v2/runtimes` protocol exactly (see [`piston`]) rather than
//! inventing a parallel one - the operator points `SLIMM_CODE_RUNNER_URL` at
//! a Piston instance they run and trust, the same relationship this project
//! already has with the push relay and a self-hosted LiveKit.
//!
//! [`CodeRunner`] is the same first-class two-state shape `push::PushSender`
//! models for the push relay: `SLIMM_CODE_RUNNER_URL` is optional, and
//! absent is the default, fully supported state - a deployment that never
//! sets it behaves exactly as it does today, with no Run affordance on any
//! code block and nothing resembling a startup error.
//!
//! **The server brokers and never executes.** Every call this file makes
//! carries exactly the block that triggered it - a language name and the
//! code - and nothing else: no token, no session, no way for the runner to
//! call back into this deployment. Whatever a compromised or misbehaving
//! runner does, the worst it can produce is a wrong answer in the block that
//! asked for it (see docs/decisions/0007's sharpest-edged constraint).
//!
//! **Ceilings are the server's, not Piston's.** Piston already implements
//! real sandboxing - no network access by default, an unprivileged user and
//! Linux namespaces per submission, CPU/wall-time and memory caps, output
//! truncation, SIGKILL on misbehaviour - and this file does not reimplement
//! any of it. What it adds on top: an explicit `run_timeout`/`compile_timeout`
//! and memory ceiling on every request rather than trusting Piston's own
//! defaults or however an operator's instance happens to be configured
//! ([`piston::execute`]), an outer HTTP client timeout ([`CLIENT_TIMEOUT`])
//! so a runner that never answers at all cannot hang the request that asked
//! for it, and a hard cap on how much of a response this server will ever
//! read ([`piston::MAX_RESPONSE_BYTES`]), refusing rather than absorbing
//! anything past it - the same style `http::canvas_write::MAX_PROPS_BYTES`
//! already uses. `Class::CodeRunner` (`crate::ratelimit::class::Class`) is
//! the matching rate-limit ceiling, charged once per actual invocation
//! (`http::module_commands::execute_code_runner`).
//!
//! **Trusting the operator, not the code.** Running arbitrary code from
//! whoever can type in a channel is a real risk regardless of how well
//! Piston sandboxes it; that is why the permission bit this ships with
//! (`Permissions::RUN_CODE`) defaults to nobody and why reaching this at all
//! needs configuration an operator adds deliberately, never something a
//! deployment gets by default. An operator who enables it is trusting the
//! people in their own space, the same trust every other write permission
//! in this project already rests on - and it is worth saying plainly rather
//! than dressing this up as more exotic than it is.
//!
//! **Which languages** a deployment can offer is read from the runner
//! itself ([`CodeRunner::languages`], `GET /api/v2/runtimes`) rather than
//! kept as a list in this codebase, so a client is never offered a Run
//! button for a language nothing has confirmed is actually installed on
//! this specific instance - see PR #1211.

mod piston;

use std::sync::Arc;
use std::time::Duration;

use crate::config::Config;
use crate::sidecar_url;

/// The outer bound on one whole call to the runner - the mechanism that
/// keeps a runner that never answers at all from hanging the request that
/// triggered it. Comfortably above the run+compile timeouts this server
/// asks Piston for (`piston::RUN_TIMEOUT_MS` / `piston::COMPILE_TIMEOUT_MS`),
/// so a legitimate slow compile fails on Piston's own ceiling first and this
/// one only ever fires against a runner that is not answering at all.
const CLIENT_TIMEOUT: Duration = Duration::from_secs(20);

/// Talks to a configured Piston instance. Cheap to clone: an
/// `Option<Arc<_>>`, the same shape `push::PushSender` uses.
#[derive(Clone)]
pub struct CodeRunner {
    inner: Option<Arc<Enabled>>,
}

struct Enabled {
    http: reqwest::Client,
    base_url: String,
    /// The last discovery answer and until when it stands, so every
    /// Run-button lookup is not a round trip to the runner.
    languages: std::sync::Mutex<Option<(std::time::Instant, Vec<String>)>>,
}

/// How long a discovery answer is reused before the runner is asked again.
const LANGUAGES_TTL: Duration = Duration::from_secs(60);

/// How long a failed discovery stands before the runner is asked again:
/// short, so one blip does not hide Run buttons for a minute, long enough
/// that a runner that hangs costs one bounded wait per interval, not per lookup.
const FAILED_LANGUAGES_TTL: Duration = Duration::from_secs(10);

/// One invocation's outcome: `ok` plus a single payload, the exact shape
/// `http::module_commands::CommandOutcome` already answers with, so a run
/// through this broker renders identically to one through an installed
/// module.
pub struct RunOutcome {
    pub ok: bool,
    pub payload: String,
}

impl RunOutcome {
    fn failure(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            payload: message.into(),
        }
    }
}

impl CodeRunner {
    /// Builds a broker from process config. Disabled, quietly, unless
    /// `SLIMM_CODE_RUNNER_URL` is set. Fails at startup if a configured URL's
    /// scheme is not safe to reach in cleartext - see
    /// `sidecar_url::validate` - the same posture the push relay's own URL
    /// already gets.
    pub fn new(config: &Config) -> anyhow::Result<Self> {
        Self::with_timeout(config, CLIENT_TIMEOUT)
    }

    /// [`Self::new`] with an explicit outer timeout, so tests can exercise
    /// "a runner that hangs does not hang the server" without waiting out
    /// the real bound.
    pub fn with_timeout(config: &Config, timeout: Duration) -> anyhow::Result<Self> {
        let inner = match &config.code_runner_url {
            Some(url) => {
                sidecar_url::validate(url, "SLIMM_CODE_RUNNER_URL")?;
                let http = reqwest::Client::builder()
                    .timeout(timeout)
                    .redirect(reqwest::redirect::Policy::none())
                    .build()
                    .expect("building the code runner HTTP client");
                Some(Arc::new(Enabled {
                    http,
                    base_url: url.trim_end_matches('/').to_owned(),
                    languages: std::sync::Mutex::new(None),
                }))
            }
            None => {
                tracing::info!("SLIMM_CODE_RUNNER_URL not set; code execution is disabled");
                None
            }
        };
        Ok(Self { inner })
    }

    /// A broker that never reaches a runner - the explicit choice tests and
    /// an unconfigured deployment's own request path both need.
    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// Whether this broker will actually reach a runner.
    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// Every language a configured runner currently declares
    /// (`GET /api/v2/runtimes`), for discovery to offer a Run affordance
    /// against. Empty when disabled or when the runner could not be
    /// reached: a runner having a bad moment loses its Run buttons for that
    /// request rather than failing the whole discovery list, the same
    /// clean-no-op posture an unconfigured runner already gets.
    ///
    /// Each name appears once, aliases included (`cpp` for `c++`), so a fence
    /// tagged with either gets a Run button. An answer is reused for
    /// [`LANGUAGES_TTL`]; when the runner fails, the last good answer stands
    /// for [`FAILED_LANGUAGES_TTL`] before it is asked again.
    pub async fn languages(&self) -> Vec<String> {
        let Some(enabled) = &self.inner else {
            return Vec::new();
        };
        let cached = lock_languages(enabled).clone();
        let now = std::time::Instant::now();
        if let Some((good_until, languages)) = &cached
            && now < *good_until
        {
            return languages.clone();
        }
        let (languages, ttl) = match piston::runtimes(enabled).await {
            Some(runtimes) => (
                runtimes
                    .into_iter()
                    .flat_map(|runtime| std::iter::once(runtime.language).chain(runtime.aliases))
                    .collect::<std::collections::BTreeSet<_>>()
                    .into_iter()
                    .collect(),
                LANGUAGES_TTL,
            ),
            None => (
                cached.map(|(_, stale)| stale).unwrap_or_default(),
                FAILED_LANGUAGES_TTL,
            ),
        };
        *lock_languages(enabled) = Some((now + ttl, languages.clone()));
        languages
    }

    /// Runs `code` as `language` and returns Piston's own outcome, ceilings
    /// applied. Never panics and never propagates a transport error to the
    /// caller: a timeout, an oversized response, or a malformed reply are
    /// all a clean `RunOutcome { ok: false, .. }`, matching how
    /// `module_commands::execute_command` already answers a host-level
    /// failure. `language` is forwarded to Piston as-is; Piston is the
    /// authority on what it has installed, so an unknown language is simply
    /// a Piston-reported failure rather than a distinct code path here.
    pub async fn run(&self, language: &str, code: &str) -> RunOutcome {
        let Some(enabled) = &self.inner else {
            return RunOutcome::failure("no code runner is configured for this deployment");
        };
        piston::execute(enabled, language, code).await
    }
}

fn lock_languages(
    enabled: &Enabled,
) -> std::sync::MutexGuard<'_, Option<(std::time::Instant, Vec<String>)>> {
    match enabled.languages.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_broker_reports_disabled() {
        assert!(!CodeRunner::disabled().is_enabled());
    }

    #[tokio::test]
    async fn disabled_broker_run_is_a_clean_failure_not_a_panic() {
        let outcome = CodeRunner::disabled().run("python", "print(1)").await;
        assert!(!outcome.ok);
        assert!(!outcome.payload.is_empty());
    }

    /// A failed discovery stands only [`FAILED_LANGUAGES_TTL`], so a runner
    /// that errors once and then recovers gets its Run buttons back soon after.
    #[tokio::test]
    async fn a_failed_discovery_is_retried_once_its_short_window_passes() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let calls = Arc::new(AtomicUsize::new(0));
        let counted = calls.clone();
        let router = axum::Router::new().route(
            "/api/v2/runtimes",
            axum::routing::get(move || {
                let first = counted.fetch_add(1, Ordering::SeqCst) == 0;
                async move {
                    if first {
                        Err(axum::http::StatusCode::INTERNAL_SERVER_ERROR)
                    } else {
                        Ok(axum::Json(
                            serde_json::json!([{ "language": "python", "version": "3" }]),
                        ))
                    }
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let runner = CodeRunner::new(&Config {
            code_runner_url: Some(format!("http://{addr}")),
            ..Config::default()
        })
        .unwrap();
        let enabled = runner.inner.as_ref().unwrap();

        assert!(runner.languages().await.is_empty());
        let (good_until, _) = lock_languages(enabled).clone().unwrap();
        assert!(good_until <= std::time::Instant::now() + FAILED_LANGUAGES_TTL);
        assert!(
            runner.languages().await.is_empty(),
            "within the window: no new ask"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        lock_languages(enabled).as_mut().unwrap().0 = std::time::Instant::now();
        assert_eq!(runner.languages().await, ["python"]);
    }

    #[tokio::test]
    async fn disabled_broker_reports_no_languages() {
        assert!(CodeRunner::disabled().languages().await.is_empty());
    }

    #[test]
    fn a_cleartext_public_runner_url_is_rejected_at_startup() {
        let config = Config {
            code_runner_url: Some("http://runner.example.com".to_owned()),
            ..Config::default()
        };
        assert!(CodeRunner::new(&config).is_err());
    }

    #[test]
    fn a_loopback_runner_url_is_allowed_over_http() {
        let config = Config {
            code_runner_url: Some("http://127.0.0.1:2000".to_owned()),
            ..Config::default()
        };
        assert!(CodeRunner::new(&config).is_ok());
    }

    #[test]
    fn no_configured_url_builds_a_disabled_broker() {
        let config = Config::default();
        let runner = CodeRunner::new(&config).unwrap();
        assert!(!runner.is_enabled());
    }
}
