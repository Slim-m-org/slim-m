// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Code runner discovery: each language once with its aliases, cached, and a
//! hung runner answered within the discovery bound (issues 2073, 2074).

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axum::Router;
use axum::routing::get;
use serde_json::json;
use slimm_server::code_runner::CodeRunner;
use slimm_server::config::Config;
use tokio::net::TcpListener;

fn runner_at(base_url: String) -> CodeRunner {
    let config = Config {
        code_runner_url: Some(base_url),
        ..Config::default()
    };
    CodeRunner::new(&config).unwrap()
}

#[tokio::test]
async fn languages_are_deduplicated_with_aliases_and_cached() {
    let hits = Arc::new(AtomicUsize::new(0));
    let counted = hits.clone();
    let router = Router::new().route(
        "/api/v2/runtimes",
        get(move || {
            counted.fetch_add(1, Ordering::SeqCst);
            async {
                axum::Json(json!([
                    { "language": "python", "version": "3.10.0", "aliases": ["py", "py3"] },
                    { "language": "python", "version": "2.7.18", "aliases": ["py"] },
                    { "language": "c++", "version": "10.2.0", "aliases": ["cpp", "g++"] },
                ]))
            }
        }),
    );
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let runner = runner_at(format!("http://{addr}"));

    assert_eq!(
        runner.languages().await,
        ["c++", "cpp", "g++", "py", "py3", "python"]
    );
    runner.languages().await;
    assert_eq!(
        hits.load(Ordering::SeqCst),
        1,
        "the second lookup went back to the runner"
    );
}

#[tokio::test]
async fn a_runner_that_never_answers_does_not_stall_discovery() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((socket, _)) = listener.accept().await {
            held.push(socket);
        }
    });
    let runner = runner_at(format!("http://{addr}"));

    let started = Instant::now();
    assert!(runner.languages().await.is_empty());
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "discovery waited {:?} on a hung runner",
        started.elapsed()
    );
}
