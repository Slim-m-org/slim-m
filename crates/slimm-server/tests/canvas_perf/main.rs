// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a busy canvas costs the server: writes, op writes and the two feed
//! reads, on a canvas holding 10,000 objects, with payload sizes.
//!
//! ```text
//! cargo nextest run --release --test canvas_perf --run-ignored all --no-capture
//! ```
//!
//! Ignored by default because it writes thousands of rows and takes a while.
//! It is a measurement and gates nothing; `CANVAS_PERF_OUT` keeps the JSON.
//!
//! Every number is one process, one SQLite file on the local disk, a glibc
//! allocator and no network, so it bounds the server's own share of a request
//! from below. The production image is musl and sits behind a proxy.

use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::Request;
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, CanvasOpId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    CanvasOpRequest, ClearScope, PlaceError, PlaceRequest, Rect, ViewportQuery,
};
use tower::ServiceExt;

#[path = "../support/mod.rs"]
mod support;

mod perf;

use perf::{Report, Samples, fetch, place_one, register, stroke_props, time_get, time_ops, unit};
use support::app::app;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
/// Writes, reads and op writes at 10,000 and then 20,000 objects.
#[ignore = "canvas server measurement; run with --run-ignored all --no-capture"]
async fn a_ten_thousand_object_canvas() {
    let (store, _guard) = support::new_store("slimm-canvas-perf").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::USE_CANVAS)
                .union(Permissions::MANAGE_CANVAS),
            true,
        )
        .await
        .unwrap();
    let router = app(store.clone());
    let channel = store.create_channel("canvas", "voice").await.unwrap().id;
    let mut users = Vec::new();
    for i in 0..40 {
        users.push(register(&store, &format!("drawer{i}")).await);
    }
    let (_, author) = users[0].clone();
    let tokens: Vec<String> = users[1..31].iter().map(|u| u.0.clone()).collect();
    let mut report = Report(Vec::new());
    let mut seed = 20261020u64;

    println!("\n== writes: place one stroke, by how full the canvas already is\n");
    let mut ids_seen = 0usize;
    let mut seeded = Instant::now();
    for window in [(0usize, 200usize), (4_800, 5_000), (9_800, 10_000)] {
        while ids_seen < window.0 {
            place_one(&store, channel, author, &mut seed).await;
            ids_seen += 1;
        }
        let mut times = Vec::new();
        while ids_seen < window.1 {
            times.push(place_one(&store, channel, author, &mut seed).await);
            ids_seen += 1;
        }
        report.time(
            &format!("place a stroke, canvas holds {}..{}", window.0, window.1),
            Samples::of(times),
        );
    }
    report.value(
        "seeding 10,000 strokes one by one (s)",
        seeded.elapsed().as_secs_f64(),
        "s",
    );
    seeded = Instant::now();
    let mut notes = Vec::new();
    for i in 0..200 {
        let id = CanvasObjectId::generate();
        let props = json!({ "text": format!("Note {i}: plan the sprint, review and ship") });
        store
            .place_canvas_object(
                channel,
                author,
                id,
                PlaceRequest {
                    kind: "note",
                    bounds: (
                        20.0 + unit(&mut seed) * 1600.0,
                        20.0 + unit(&mut seed) * 900.0,
                        240.0,
                        140.0,
                    ),
                    props: &props.to_string(),
                    attachment: None,
                },
            )
            .await
            .expect("note");
        notes.push(id);
    }
    report.value("placing 200 notes (s)", seeded.elapsed().as_secs_f64(), "s");

    println!("\n== reads at 10,200 objects\n");
    let board = (0.0, 0.0, 1920.0, 1080.0);
    for (name, rect, limit) in [
        (
            "viewport, whole board, limit 2000 (the client's ask)",
            board,
            2000,
        ),
        ("viewport, whole board, default limit 500", board, 500),
        (
            "viewport, 2x zoom (960x540)",
            (480.0, 270.0, 1440.0, 810.0),
            2000,
        ),
        (
            "viewport, 4x zoom (480x270)",
            (720.0, 405.0, 1200.0, 675.0),
            2000,
        ),
    ] {
        let uri = format!(
            "/channels/{channel}/canvas/objects?min_x={}&min_y={}&max_x={}&max_y={}&limit={limit}",
            rect.0, rect.1, rect.2, rect.3
        );
        let (times, size) = time_get(&router, &tokens, &uri, 30).await;
        report.time(&format!("HTTP {name}"), times);
        report.value(
            &format!("payload {name} (KiB)"),
            size as f64 / 1024.0,
            "KiB",
        );
    }
    {
        let mut times = Vec::new();
        for _ in 0..30 {
            let query = ViewportQuery {
                view: Rect {
                    min_x: board.0,
                    min_y: board.1,
                    max_x: board.2,
                    max_y: board.3,
                },
                previous: None,
                after_seq: 0,
                limit: 2001,
            };
            let at = Instant::now();
            let _ = store.viewport_snapshot(channel, &query).await.unwrap();
            times.push(at.elapsed());
        }
        report.time(
            "store viewport_snapshot, whole board, limit 2000",
            Samples::of(times),
        );
    }

    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    report.value("canvas op head (seq)", head as f64, "");
    for (name, after, limit) in [
        (
            "ops feed, 1,900 behind (the edge of the 2,000 gap), page of 200",
            head - 1_900,
            200,
        ),
        (
            "ops feed, 500 behind, page of 100 (default)",
            head - 500,
            100,
        ),
        ("ops feed, 5 ops behind the head", head - 5, 100),
        ("ops feed, 3,000 behind (answers reset)", head - 3_000, 200),
    ] {
        let uri = format!("/channels/{channel}/canvas/ops?after_seq={after}&limit={limit}");
        let (times, size) = time_get(&router, &tokens, &uri, 30).await;
        report.time(&format!("HTTP {name}"), times);
        report.value(
            &format!("payload {name} (KiB)"),
            size as f64 / 1024.0,
            "KiB",
        );
    }
    {
        let at = Instant::now();
        let mut after = head - 1_900;
        let (mut bytes, mut pages) = (0usize, 0usize);
        loop {
            let uri = format!("/channels/{channel}/canvas/ops?after_seq={after}&limit=200");
            let request = Request::builder()
                .method("GET")
                .uri(&uri)
                .header(
                    "authorization",
                    format!("Bearer {}", users[1 + pages % 39].0),
                )
                .body(Body::empty())
                .unwrap();
            let response = router.clone().oneshot(request).await.unwrap();
            let body = axum::body::to_bytes(response.into_body(), usize::MAX)
                .await
                .unwrap();
            bytes += body.len();
            pages += 1;
            let page: Value = serde_json::from_slice(&body).unwrap();
            after = page["ops"]
                .as_array()
                .and_then(|ops| ops.last())
                .and_then(|op| op["seq"].as_i64())
                .unwrap_or(after);
            if !page["has_more"].as_bool().unwrap_or(false) {
                break;
            }
        }
        report.value(
            "catch-up from 1,900 behind, pages of 200 (requests)",
            pages as f64,
            "requests",
        );
        report.value(
            "catch-up from 1,900 behind (MiB)",
            bytes as f64 / 1_048_576.0,
            "MiB",
        );
        report.value(
            "catch-up from 1,900 behind, wall time (s)",
            at.elapsed().as_secs_f64(),
            "s",
        );
    }

    println!("\n== op writes at 10,200 objects (store level, one write transaction each)\n");
    let note = |i: usize| notes[i % notes.len()];
    let moved = time_ops(&store, channel, author, 200, |i| CanvasOpRequest::Move {
        object_id: note(i),
        x: 100.0 + i as f64,
        y: 100.0,
        w: 240.0,
        h: 140.0,
    });
    report.time("op: move a note", moved.await);
    let raised = time_ops(&store, channel, author, 200, |i| CanvasOpRequest::Reorder {
        object_id: note(i),
        z_index: 100_000 + i as i64,
    });
    report.time("op: reorder (bring to front)", raised.await);
    let edited = time_ops(&store, channel, author, 200, |i| CanvasOpRequest::Edit {
        object_id: note(i),
        props: json!({ "text": format!("edited {i}") }).to_string(),
    });
    report.time("op: edit a note", edited.await);
    let erased = time_ops(&store, channel, author, 100, |i| {
        CanvasOpRequest::Remove(vec![notes[i]])
    });
    report.time("op: remove one object (eraser stroke)", erased.await);

    println!("\n== a drawing session while others read (store level)\n");
    let readers: Vec<_> = (0..4)
        .map(|_| {
            let store = store.clone();
            tokio::spawn(async move {
                let query = ViewportQuery {
                    view: Rect {
                        min_x: 0.0,
                        min_y: 0.0,
                        max_x: 1920.0,
                        max_y: 1080.0,
                    },
                    previous: None,
                    after_seq: 0,
                    limit: 2001,
                };
                let until = Instant::now() + Duration::from_secs(8);
                let mut reads = 0u32;
                while Instant::now() < until {
                    let _ = store.viewport_snapshot(channel, &query).await.unwrap();
                    reads += 1;
                }
                reads
            })
        })
        .collect();
    let mut contended = Vec::new();
    let until = Instant::now() + Duration::from_secs(6);
    while Instant::now() < until {
        contended.push(place_one(&store, channel, author, &mut seed).await);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut total_reads = 0;
    for reader in readers {
        total_reads += reader.await.unwrap();
    }
    report.time(
        "place a stroke while 4 clients re-read the board",
        Samples::of(contended),
    );
    report.value(
        "whole-board reads completed in 8 s by 4 readers",
        f64::from(total_reads),
        "reads",
    );

    println!("\n== placing through the router (permission checks, JSON, fan-out)\n");
    let mut routed = Vec::new();
    for i in 0..200 {
        let (x, y, w, h, props) = stroke_props(&mut seed);
        let (token, _) = users[4 + i % 30].clone();
        let at = Instant::now();
        fetch(
            &router,
            "POST",
            &format!("/channels/{channel}/canvas/objects"),
            &token,
            Some(json!({
                "id": CanvasObjectId::generate().to_string(),
                "kind": "stroke",
                "x": x, "y": y, "w": w, "h": h,
                "props": serde_json::from_str::<Value>(&props).unwrap(),
            })),
        )
        .await;
        routed.push(at.elapsed());
    }
    report.time("HTTP POST place a stroke", Samples::of(routed));

    println!("\n== clear and restore of the whole canvas\n");
    let latest = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    let clear_id = CanvasOpId::generate();
    let at = Instant::now();
    store
        .submit_canvas_op(
            channel,
            author,
            clear_id,
            true,
            CanvasOpRequest::Clear {
                before_seq: latest,
                scope: ClearScope::default(),
            },
        )
        .await
        .expect("clear");
    report.value(
        "op: clear ~10,600 objects (ms)",
        at.elapsed().as_secs_f64() * 1000.0,
        "ms",
    );
    let at = Instant::now();
    store
        .submit_canvas_op(
            channel,
            author,
            CanvasOpId::generate(),
            true,
            CanvasOpRequest::Restore {
                target_op: clear_id,
            },
        )
        .await
        .expect("restore");
    report.value(
        "op: restore ~10,600 objects (ms)",
        at.elapsed().as_secs_f64() * 1000.0,
        "ms",
    );

    println!("\n== filled to the 20,000-object cap\n");
    let mut filling = Vec::new();
    loop {
        let (x, y, w, h, props) = stroke_props(&mut seed);
        let at = Instant::now();
        let placed = store
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
            .await;
        let took = at.elapsed();
        match placed {
            Ok(_) => filling.push(took),
            Err(PlaceError::ChannelFull) => {
                report.value(
                    "the refusal at the cap (ms)",
                    took.as_secs_f64() * 1000.0,
                    "ms",
                );
                break;
            }
            Err(other) => panic!("fill failed: {other:?}"),
        }
    }
    report.value(
        "objects placed to reach the cap",
        filling.len() as f64,
        "objects",
    );
    let tail = filling.split_off(filling.len().saturating_sub(200));
    report.time(
        "place a stroke, canvas holds ~19,800..20,000",
        Samples::of(tail),
    );
    {
        let uri = format!(
            "/channels/{channel}/canvas/objects?min_x=0&min_y=0&max_x=1920&max_y=1080&limit=2000"
        );
        let (times, size) = time_get(&router, &tokens, &uri, 30).await;
        report.time(
            "HTTP viewport, whole board, limit 2000, 20,000 objects",
            times,
        );
        report.value(
            "payload at 20,000 objects (KiB)",
            size as f64 / 1024.0,
            "KiB",
        );
    }

    report.flush();
}
