// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! An unauthenticated flood of `/healthz` or unmatched paths writes no request
//! lines, so it cannot rotate retained logs away or use up Verbose's budget,
//! while the lines of real requests are all kept.

use axum::body::Body;
use axum::http::Request;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::logging::{FileLimits, LogMode, LogSettings, Logging, plan_recent, read_plan};
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::app;

const FINISHED: &str = "finished processing request";

async fn get(router: &axum::Router, path: &str, method: &str) {
    let request = Request::builder()
        .method(method)
        .uri(path)
        .body(Body::empty())
        .unwrap();
    router.clone().oneshot(request).await.unwrap();
}

async fn finished_lines(mode: LogMode, floods: usize, real: usize) -> usize {
    let (db_path, _db_guard) = support::TestDbGuard::new("slimm-log-noise");
    let (dir, _dir_guard) = support::TestDirGuard::new("slimm-log-noise-files");
    let config = Config {
        port: 0,
        database_path: db_path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let store = Store::new(db::connect(&config).await.unwrap());
    let router = app(store);
    let settings = LogSettings {
        base_filter: String::new(),
        dir: Some(dir),
        limits: FileLimits::new(14, 1 << 24),
    };
    let built = Logging::build(&settings, false);
    let _guard = tracing::dispatcher::set_default(&built.dispatch);
    built.logging.set_mode(mode);
    for _ in 0..floods {
        get(&router, "/healthz", "GET").await;
        get(&router, "/no/such/route", "GET").await;
    }
    for _ in 0..real {
        get(&router, "/version", "GET").await;
    }
    built.logging.flush();
    let plan = plan_recent(
        built.logging.dir().unwrap(),
        1 << 24,
        slimm_server::logging::today(),
    )
    .unwrap();
    let text = String::from_utf8(read_plan(&plan).unwrap()).unwrap();
    text.lines()
        .filter(|line| line.contains(FINISHED) && !line.contains("SLIMMPROBE"))
        .count()
}

#[tokio::test]
async fn a_healthz_and_unmatched_flood_writes_no_request_lines_in_compact() {
    assert_eq!(finished_lines(LogMode::Compact, 300, 3).await, 3);
}

#[tokio::test]
async fn verbose_keeps_every_real_request_line_during_a_junk_flood() {
    assert_eq!(finished_lines(LogMode::Verbose, 300, 120).await, 120);
}
