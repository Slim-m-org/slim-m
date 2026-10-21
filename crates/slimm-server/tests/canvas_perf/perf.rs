// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Timing samples, a JSON report and canvas fixtures for `canvas_perf`.

use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, PlaceRequest, Store};
use tower::ServiceExt;

const POINTS: usize = 48;

/// Microsecond samples, summarised the way the client benchmarks do.
pub struct Samples(Vec<f64>);

impl Samples {
    pub fn of(times: Vec<Duration>) -> Self {
        let mut us: Vec<f64> = times.iter().map(|t| t.as_secs_f64() * 1e6).collect();
        us.sort_by(|a, b| a.partial_cmp(b).expect("finite"));
        Self(us)
    }

    pub fn at(&self, q: f64) -> f64 {
        let i = ((q * self.0.len() as f64) as usize).min(self.0.len() - 1);
        self.0[i]
    }

    pub fn json(&self) -> Value {
        json!({
            "n": self.0.len(),
            "p50_ms": self.at(0.5) / 1000.0,
            "p95_ms": self.at(0.95) / 1000.0,
            "p99_ms": self.at(0.99) / 1000.0,
            "max_ms": self.0.last().copied().unwrap_or(0.0) / 1000.0,
        })
    }
}

pub struct Report(pub Vec<Value>);

impl Report {
    pub fn time(&mut self, name: &str, samples: Samples) {
        println!(
            "{name:<56} p50 {:>8.3} ms  p95 {:>8.3}  p99 {:>8.3}  max {:>8.3}  (n={})",
            samples.at(0.5) / 1000.0,
            samples.at(0.95) / 1000.0,
            samples.at(0.99) / 1000.0,
            samples.0.last().copied().unwrap_or(0.0) / 1000.0,
            samples.0.len()
        );
        let mut row = samples.json();
        row["name"] = json!(name);
        self.0.push(row);
    }

    pub fn value(&mut self, name: &str, value: f64, unit: &str) {
        println!("{name:<56} {value:>12.1} {unit}");
        self.0
            .push(json!({ "name": name, "value": value, "unit": unit }));
    }

    pub fn flush(&self) {
        if let Ok(dir) = std::env::var("CANVAS_PERF_OUT") {
            std::fs::create_dir_all(&dir).expect("output dir");
            std::fs::write(
                format!("{dir}/server_canvas.json"),
                serde_json::to_string_pretty(&json!({ "rows": self.0 })).expect("json"),
            )
            .expect("write json");
        }
    }
}

pub async fn register(store: &Store, name: &str) -> (String, UserId) {
    let account = store
        .create_account(name, name, "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id)
}

/// Deterministic pseudo-random in [0, 1), so two runs draw the same board.
pub fn unit(seed: &mut u64) -> f64 {
    *seed = seed
        .wrapping_mul(6364136223846793005)
        .wrapping_add(1442695040888963407);
    ((*seed >> 33) as f64) / ((1u64 << 31) as f64)
}

/// A pen stroke as the client sends it: `POINTS` relative points, a width and a colour.
pub fn stroke_props(seed: &mut u64) -> (f64, f64, f64, f64, String) {
    let mut heading = unit(seed) * std::f64::consts::TAU;
    let (mut px, mut py) = (0.0f64, 0.0f64);
    let mut pts = vec![(0.0f64, 0.0f64)];
    for _ in 1..POINTS {
        heading += (unit(seed) - 0.5) * 0.6;
        px += heading.cos() * 5.0;
        py += heading.sin() * 5.0;
        pts.push((px, py));
    }
    let min_x = pts.iter().map(|p| p.0).fold(f64::MAX, f64::min);
    let min_y = pts.iter().map(|p| p.1).fold(f64::MAX, f64::min);
    let max_x = pts.iter().map(|p| p.0).fold(f64::MIN, f64::max);
    let max_y = pts.iter().map(|p| p.1).fold(f64::MIN, f64::max);
    let flat: Vec<f64> = pts
        .iter()
        .flat_map(|p| [round2(p.0 - min_x), round2(p.1 - min_y)])
        .collect();
    let w = max_x - min_x;
    let h = max_y - min_y;
    let x = 40.0 + unit(seed) * (1920.0 - 80.0 - w);
    let y = 40.0 + unit(seed) * (1080.0 - 80.0 - h);
    let props = json!({ "points": flat, "width": 3.0, "color": "ink" }).to_string();
    (x, y, w, h, props)
}

pub fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

pub async fn place_one(
    store: &Store,
    channel: ChannelId,
    author: UserId,
    seed: &mut u64,
) -> Duration {
    let (x, y, w, h, props) = stroke_props(seed);
    let at = Instant::now();
    store
        .place_canvas_object(
            channel,
            author,
            CanvasObjectId::generate(),
            PlaceRequest {
                kind: "stroke",
                bounds: (x, y, w, h),
                props: &props,
                attachment: None,
            },
        )
        .await
        .expect("placed");
    at.elapsed()
}

pub async fn fetch(
    app: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> usize {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    let request = match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string())),
        None => {
            builder = builder.header("accept", "application/json");
            builder.body(Body::empty())
        }
    }
    .unwrap();
    let response = app.clone().oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert!(
        status == StatusCode::OK || status == StatusCode::CREATED,
        "{method} {uri}: {status} {}",
        String::from_utf8_lossy(&bytes)
    );
    bytes.len()
}

/// Times `n` GETs of `uri`, rotating through `tokens` so no one account's
/// rate budget runs out, and returns the samples with the last payload size.
pub async fn time_get(router: &Router, tokens: &[String], uri: &str, n: usize) -> (Samples, usize) {
    let (mut times, mut size) = (Vec::new(), 0);
    for i in 0..n {
        let at = Instant::now();
        size = fetch(router, "GET", uri, &tokens[i % tokens.len()], None).await;
        times.push(at.elapsed());
    }
    (Samples::of(times), size)
}

/// Times `n` canvas ops built by `make`, each its own write transaction.
pub async fn time_ops(
    store: &Store,
    channel: ChannelId,
    actor: UserId,
    n: usize,
    make: impl Fn(usize) -> CanvasOpRequest,
) -> Samples {
    let mut times = Vec::new();
    for i in 0..n {
        let at = Instant::now();
        store
            .submit_canvas_op(channel, actor, CanvasOpId::generate(), true, make(i))
            .await
            .expect("op");
        times.push(at.elapsed());
    }
    Samples::of(times)
}
