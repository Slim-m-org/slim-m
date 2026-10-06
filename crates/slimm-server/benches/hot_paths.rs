// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hot-path benchmarks.
//!
//! `uuid_now_v7` and `version_json_serialize` are the original baseline
//! benchmarks and keep their names so committed `perf/baselines/` files stay
//! comparable. `hub_publish_fanout` drives the real `slimm_server::hub::Hub`.

use criterion::{Criterion, black_box, criterion_group, criterion_main};
use serde::Serialize;
use slimm_server::hub::{Event, Hub};
use slimm_server::ids::UserId;

/// Mirrors the response shape served by `GET /version` in `src/http.rs`.
#[derive(Serialize)]
struct Version {
    name: &'static str,
    version: &'static str,
    protocol: u32,
}

/// Every stored message and event gets a UUIDv7 identity, so its generation
/// cost sits on the write path of every mutation the server accepts.
fn bench_uuid_v7(c: &mut Criterion) {
    c.bench_function("uuid_now_v7", |b| {
        b.iter(|| black_box(uuid::Uuid::now_v7()));
    });
}

/// `/version` is served on every client handshake, so its serialization
/// cost, however small, runs on the connection-setup path.
fn bench_version_json(c: &mut Criterion) {
    let body = Version {
        name: "slim-m",
        version: env!("CARGO_PKG_VERSION"),
        protocol: 1,
    };

    c.bench_function("version_json_serialize", |b| {
        b.iter(|| {
            black_box(serde_json::to_vec(black_box(&body)).expect("serialize /version body"))
        });
    });
}

/// Every durable write fans out through `Hub::publish`, so its cost with a
/// realistic subscriber count bounds how fast the server can accept mutations.
fn bench_hub_publish_fanout(c: &mut Criterion) {
    let hub = Hub::new();
    let _subscribers: Vec<_> = (0..64).map(|_| hub.subscribe()).collect();

    c.bench_function("hub_publish_fanout_64", |b| {
        b.iter(|| hub.publish(black_box(Event::PresenceChanged(UserId::generate()))));
    });
}

criterion_group!(
    hot_paths,
    bench_uuid_v7,
    bench_version_json,
    bench_hub_publish_fanout
);
criterion_main!(hot_paths);
