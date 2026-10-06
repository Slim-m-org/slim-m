// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The exact wire shapes of Piston's own API (`engineer-man/piston`), matched
//! rather than designed: `POST /api/v2/execute` to run one block, and
//! `GET /api/v2/runtimes` to learn what a configured instance actually has
//! installed. Nothing here is this project's own protocol; a field renamed
//! or dropped on Piston's side is a wire break to notice here, not a spec to
//! renegotiate.

use serde::{Deserialize, Serialize};

use super::{Enabled, RunOutcome};
use crate::net_guard::read_capped;

/// This server's own wall-clock ceiling on the *run* stage, passed to Piston
/// explicitly rather than trusted to its default (3000ms) or however an
/// operator's instance happens to be configured - see the parent module's
/// doc on ceilings being the server's, not the runner's.
const RUN_TIMEOUT_MS: u64 = 5_000;
/// Same, for the *compile* stage Piston's protocol always carries even for
/// an interpreted language like Python.
const COMPILE_TIMEOUT_MS: u64 = 10_000;
/// Memory ceiling for each stage, in bytes. Piston's own default is `-1`
/// (unbounded) unless an operator has set `PISTON_LIMIT_*` themselves; this
/// server asks for a concrete ceiling regardless, for the same reason it
/// sets its own timeouts above.
const MEMORY_LIMIT_BYTES: i64 = 256 * 1024 * 1024;

/// Most of a Piston response this server will read before giving up on it -
/// enforced by capping the read itself, not by reading the body whole and
/// truncating after, so a hostile or broken runner cannot make this server
/// hold an unbounded response in memory. In the same refuse-rather-than-
/// absorb style `http::canvas_write::MAX_PROPS_BYTES` already uses.
pub(super) const MAX_RESPONSE_BYTES: usize = 64 * 1024;

#[derive(Serialize)]
struct ExecuteRequest<'a> {
    language: &'a str,
    /// Always `"*"`, Piston's own "any matching version" selector - this
    /// server never tracks which exact version an instance has installed;
    /// see [`super::CodeRunner::run`]'s doc.
    version: &'a str,
    files: [ExecuteFile<'a>; 1],
    run_timeout: u64,
    compile_timeout: u64,
    run_memory_limit: i64,
    compile_memory_limit: i64,
}

#[derive(Serialize)]
struct ExecuteFile<'a> {
    content: &'a str,
}

#[derive(Deserialize)]
struct ExecuteResponse {
    #[serde(default)]
    compile: Option<StageResult>,
    run: StageResult,
}

#[derive(Deserialize)]
struct StageResult {
    #[serde(default)]
    output: String,
    code: Option<i64>,
    signal: Option<String>,
}

impl StageResult {
    /// A stage that neither exited non-zero nor was killed by a signal - the
    /// latter is what a wall-clock or memory ceiling being hit looks like on
    /// the wire.
    fn succeeded(&self) -> bool {
        self.code == Some(0) && self.signal.is_none()
    }

    /// This stage's own combined stdout/stderr, or - when it was killed
    /// rather than exiting on its own - a short note plus whatever it
    /// printed before that.
    fn describe(&self) -> String {
        match &self.signal {
            Some(signal) => format!("terminated by signal {signal}\n{}", self.output),
            None => self.output.clone(),
        }
    }
}

/// One entry of `GET /api/v2/runtimes`; only the field this broker reads.
#[derive(Deserialize)]
pub(super) struct Runtime {
    pub(super) language: String,
}

/// `POST {base}/api/v2/execute`. `language` and `code` are the whole of what
/// a caller supplies; see the parent module's doc for why nothing else rides
/// along. Never propagates a transport error: every failure mode answers a
/// clean [`RunOutcome`].
pub(super) async fn execute(enabled: &Enabled, language: &str, code: &str) -> RunOutcome {
    let request = ExecuteRequest {
        language,
        version: "*",
        files: [ExecuteFile { content: code }],
        run_timeout: RUN_TIMEOUT_MS,
        compile_timeout: COMPILE_TIMEOUT_MS,
        run_memory_limit: MEMORY_LIMIT_BYTES,
        compile_memory_limit: MEMORY_LIMIT_BYTES,
    };
    let response = match enabled
        .http
        .post(format!("{}/api/v2/execute", enabled.base_url))
        .json(&request)
        .send()
        .await
    {
        Ok(response) => response,
        Err(err) if err.is_timeout() => {
            return RunOutcome::failure("the code runner did not answer in time");
        }
        Err(_) => return RunOutcome::failure("the code runner could not be reached"),
    };
    if !response.status().is_success() {
        return RunOutcome::failure("the code runner refused the request");
    }
    let bytes = match read_capped(response, MAX_RESPONSE_BYTES).await {
        Ok(bytes) => bytes,
        Err(_) => return RunOutcome::failure("the code runner's response was too large"),
    };
    let Ok(parsed) = serde_json::from_slice::<ExecuteResponse>(&bytes) else {
        return RunOutcome::failure("the code runner returned a malformed response");
    };
    if let Some(compile) = &parsed.compile
        && !compile.succeeded()
    {
        return RunOutcome::failure(compile.describe());
    }
    if !parsed.run.succeeded() {
        return RunOutcome::failure(parsed.run.describe());
    }
    RunOutcome {
        ok: true,
        payload: parsed.run.output,
    }
}

/// `GET {base}/api/v2/runtimes`: what this instance actually has installed,
/// so discovery can offer a Run affordance only for a language this specific
/// deployment's runner declares - never a hardcoded list, and never
/// something this server decides on the runner's behalf. `None` on any
/// failure (unreachable, non-2xx, oversized, malformed), which callers treat
/// as "nothing extra to offer" rather than an error - the same clean-no-op
/// posture an unconfigured runner already gets.
pub(super) async fn runtimes(enabled: &Enabled) -> Option<Vec<Runtime>> {
    let response = enabled
        .http
        .get(format!("{}/api/v2/runtimes", enabled.base_url))
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let bytes = read_capped(response, MAX_RESPONSE_BYTES).await.ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    use axum::Json;
    use axum::extract::State;
    use axum::routing::{get, post};
    use serde_json::{Value, json};
    use tokio::net::TcpListener;
    use tokio::sync::Mutex;

    use super::*;

    fn enabled_at(base_url: String, timeout: Duration) -> Enabled {
        Enabled {
            http: reqwest::Client::builder().timeout(timeout).build().unwrap(),
            base_url,
        }
    }

    /// Starts a fake Piston serving `execute_body` from `/api/v2/execute`
    /// and `runtimes_body` from `/api/v2/runtimes`, and hands back the
    /// captured request body of the *last* `/execute` call it received (so a
    /// test can assert on exactly what this broker sent).
    async fn fake_piston(
        execute_body: Value,
        runtimes_body: Value,
    ) -> (String, Arc<Mutex<Option<Value>>>) {
        let captured: Arc<Mutex<Option<Value>>> = Arc::new(Mutex::new(None));
        let captured_for_route = captured.clone();
        let router = axum::Router::new()
            .route(
                "/api/v2/execute",
                post(
                    move |State(state): State<Arc<Mutex<Option<Value>>>>,
                          Json(body): Json<Value>| {
                        let execute_body = execute_body.clone();
                        async move {
                            *state.lock().await = Some(body);
                            Json(execute_body)
                        }
                    },
                ),
            )
            .route(
                "/api/v2/runtimes",
                get(move || {
                    let runtimes_body = runtimes_body.clone();
                    async move { Json(runtimes_body) }
                }),
            )
            .with_state(captured_for_route);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        (format!("http://{addr}"), captured)
    }

    fn ok_execute_response(output: &str) -> Value {
        json!({ "run": { "output": output, "stdout": output, "stderr": "", "code": 0, "signal": null } })
    }

    #[tokio::test]
    async fn a_successful_run_reports_ok_and_the_run_output() {
        let (base_url, _captured) = fake_piston(ok_execute_response("hello\n"), json!([])).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        let outcome = execute(&enabled, "python", "print('hello')").await;
        assert!(outcome.ok);
        assert_eq!(outcome.payload, "hello\n");
    }

    #[tokio::test]
    async fn a_nonzero_exit_reports_failure_with_the_output() {
        let body = json!({ "run": { "output": "boom", "stdout": "", "stderr": "boom", "code": 1, "signal": null } });
        let (base_url, _captured) = fake_piston(body, json!([])).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        let outcome = execute(&enabled, "python", "raise Exception('boom')").await;
        assert!(!outcome.ok);
        assert_eq!(outcome.payload, "boom");
    }

    #[tokio::test]
    async fn a_killed_run_names_the_signal_that_killed_it() {
        let body = json!({ "run": { "output": "", "stdout": "", "stderr": "", "code": null, "signal": "SIGKILL" } });
        let (base_url, _captured) = fake_piston(body, json!([])).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        let outcome = execute(&enabled, "python", "while True: pass").await;
        assert!(!outcome.ok);
        assert!(outcome.payload.contains("SIGKILL"), "{}", outcome.payload);
    }

    #[tokio::test]
    async fn a_failed_compile_stage_short_circuits_before_run_is_read() {
        let body = json!({
            "compile": { "output": "syntax error", "stdout": "", "stderr": "syntax error", "code": 1, "signal": null },
            "run": { "output": "should not be reached", "stdout": "", "stderr": "", "code": 0, "signal": null }
        });
        let (base_url, _captured) = fake_piston(body, json!([])).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        let outcome = execute(&enabled, "java", "not valid java").await;
        assert!(!outcome.ok);
        assert_eq!(outcome.payload, "syntax error");
    }

    /// The whole point of the broker: this server hands the runner the
    /// block that triggered it and nothing else - no token, no user id, no
    /// session, no deployment handle. Proven by inspecting the actual
    /// captured request body, not by reading the source.
    #[tokio::test]
    async fn the_request_carries_only_the_language_and_code() {
        let (base_url, captured) = fake_piston(ok_execute_response("ok"), json!([])).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        execute(&enabled, "python", "print('secret-free')").await;

        let sent = captured.lock().await.clone().expect("execute was called");
        let obj = sent.as_object().expect("request body is a JSON object");
        let allowed_keys = [
            "language",
            "version",
            "files",
            "run_timeout",
            "compile_timeout",
            "run_memory_limit",
            "compile_memory_limit",
        ];
        for key in obj.keys() {
            assert!(
                allowed_keys.contains(&key.as_str()),
                "unexpected field {key:?} in the runner request - only the \
                 block that triggered it may ride along"
            );
        }
        assert_eq!(sent["language"], "python");
        assert_eq!(sent["files"][0]["content"], "print('secret-free')");
        for forbidden in ["token", "user_id", "session", "api_key", "channel_id"] {
            assert!(!sent.to_string().contains(forbidden), "{forbidden} leaked");
        }
    }

    #[tokio::test]
    async fn a_runner_that_never_answers_fails_quickly_rather_than_hanging() {
        let hit = Arc::new(AtomicBool::new(false));
        let hit_in_route = hit.clone();
        let router = axum::Router::new().route(
            "/api/v2/execute",
            post(move || {
                let hit_in_route = hit_in_route.clone();
                async move {
                    hit_in_route.store(true, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    Json(json!({}))
                }
            }),
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });

        // Stands in for `CLIENT_TIMEOUT`, so the ceiling is proved without a 20s wait.
        let enabled = enabled_at(format!("http://{addr}"), Duration::from_millis(200));

        let started = Instant::now();
        let outcome = execute(&enabled, "python", "while True: pass").await;
        assert!(!outcome.ok);
        assert!(hit.load(Ordering::SeqCst), "the fake runner was reached");
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "a hung runner must not hang the caller: took {:?}",
            started.elapsed()
        );
    }

    #[tokio::test]
    async fn an_oversized_response_is_refused_not_absorbed() {
        let huge_output = "a".repeat(MAX_RESPONSE_BYTES * 2);
        let (base_url, _captured) = fake_piston(ok_execute_response(&huge_output), json!([])).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        let outcome = execute(&enabled, "python", "print('a' * 1000000)").await;
        assert!(!outcome.ok);
        assert!(outcome.payload.contains("too large"), "{}", outcome.payload);
    }

    #[tokio::test]
    async fn runtimes_lists_every_language_the_instance_declares() {
        let list = json!([
            { "language": "python", "version": "3.10.0", "aliases": ["py"] },
            { "language": "lua", "version": "5.4.0", "aliases": [] },
        ]);
        let (base_url, _captured) = fake_piston(ok_execute_response("unused"), list).await;
        let enabled = enabled_at(base_url, Duration::from_secs(5));

        let languages: Vec<String> = runtimes(&enabled)
            .await
            .unwrap()
            .into_iter()
            .map(|r| r.language)
            .collect();
        assert_eq!(languages, vec!["python".to_owned(), "lua".to_owned()]);
    }

    #[tokio::test]
    async fn an_unreachable_runner_reports_no_runtimes_rather_than_erroring() {
        // Nothing is listening on this port.
        let enabled = enabled_at("http://127.0.0.1:1".to_owned(), Duration::from_millis(200));
        assert!(runtimes(&enabled).await.is_none());
    }
}
