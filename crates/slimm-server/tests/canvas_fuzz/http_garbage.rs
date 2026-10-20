// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hostile and malformed request bodies and queries against the canvas routes:
//! none may answer with a server error, and what they leave behind must still
//! replay to the live table.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, UserId};
use tower::ServiceExt;

use crate::fixtures::{
    self, app, general, id, new_store_and_pool, post_object, register, stroke, submit_op,
};
use crate::repros::replay_matches_live;
use crate::script::Rng;

struct Pools {
    objects: Vec<String>,
    ops: Vec<String>,
    users: Vec<String>,
}

fn number(rng: &mut Rng, key: &str) -> Value {
    if rng.chance(60) {
        return match key {
            "w" | "h" => json!(1 + rng.below(500)),
            "z_index" | "before_seq" => json!(rng.below(60)),
            _ => json!(rng.range(-3000, 3000)),
        };
    }
    match rng.below(16) {
        0 => json!(0),
        1 => json!(-1),
        2 => json!(0.5),
        3 => json!(5_000_000.0),
        4 => json!(-5_000_000.0),
        5 => json!(8192),
        6 => json!(8193),
        7 => json!(9_007_199_254_740_993_i64),
        8 => json!(i64::MAX),
        9 => json!(i64::MIN),
        10 => json!(1e308),
        11 => json!(u64::MAX),
        12 => json!(-0.0),
        13 => json!(1u64 << 52),
        14 => json!((1i64 << 52) + 1),
        _ => json!(rng.range(-3000, 3000)),
    }
}

fn junk(rng: &mut Rng) -> Value {
    match rng.below(9) {
        0 => Value::Null,
        1 => json!(true),
        2 => json!("text"),
        3 => json!([]),
        4 => json!({}),
        5 => json!([1, 2]),
        6 => json!({ "a": { "b": [1, { "c": null }] } }),
        7 => json!(""),
        _ => json!("x".repeat(5000)),
    }
}

fn identifier(rng: &mut Rng, pool: &[String]) -> Value {
    match rng.below(30) {
        0 => json!("not-a-uuid"),
        1 => json!(""),
        2 => json!("00000000-0000-0000-0000-000000000000"),
        3 => json!(uuid::Uuid::now_v7().to_string()),
        4 => json!(uuid::Uuid::now_v7().simple().to_string()),
        5 => json!(pool.first().map(|s| s.to_uppercase()).unwrap_or_default()),
        6..=8 => json!(uuid::Uuid::now_v7().to_string()),
        _ if pool.is_empty() => json!(uuid::Uuid::now_v7().to_string()),
        _ => json!(pool[rng.below(pool.len() as u64) as usize]),
    }
}

fn field(rng: &mut Rng, key: &str, pools: &Pools) -> Value {
    if rng.chance(5) {
        return junk(rng);
    }
    match key {
        "object_ids" => {
            let n = if rng.chance(8) { 65 } else { rng.below(4) };
            Value::Array((0..n).map(|_| identifier(rng, &pools.objects)).collect())
        }
        "object_id" => identifier(rng, &pools.objects),
        "target_op" => identifier(rng, &pools.ops),
        "author_id" => identifier(rng, &pools.users),
        "kinds" => Value::Array(
            (0..rng.below(6))
                .map(|_| {
                    json!(["stroke", "note", "shape", "image", "window"][rng.below(5) as usize])
                })
                .collect(),
        ),
        "props" => json!({ "text": "hello" }),
        _ => number(rng, key),
    }
}

fn body(rng: &mut Rng, pools: &Pools) -> Value {
    let kinds = [
        "remove",
        "clear",
        "clear_scoped",
        "restore",
        "move",
        "reorder",
        "edit",
        "bogus",
        "",
    ];
    let kind = if rng.chance(4) {
        kinds[7 + rng.below(2) as usize]
    } else {
        kinds[rng.below(7) as usize]
    };
    let keys = [
        "object_ids",
        "before_seq",
        "target_op",
        "object_id",
        "x",
        "y",
        "w",
        "h",
        "z_index",
        "props",
        "kinds",
        "author_id",
    ];
    let wanted: &[&str] = match kind {
        "remove" => &["object_ids"],
        "clear" => &["before_seq"],
        "clear_scoped" => &["before_seq", "kinds", "author_id"],
        "restore" => &["target_op"],
        "move" => &["object_id", "x", "y", "w", "h"],
        "reorder" => &["object_id", "z_index"],
        "edit" => &["object_id", "props"],
        _ => &[],
    };
    let mut out =
        json!({ "id": if rng.chance(2) { json!("junk") } else { json!(id()) }, "kind": kind });
    for key in wanted {
        if rng.chance(96) {
            out[*key] = field(rng, key, pools);
        }
    }
    if rng.chance(12) {
        let key = keys[rng.below(keys.len() as u64) as usize];
        out[key] = field(rng, key, pools);
    }
    out
}

fn placement(rng: &mut Rng) -> Value {
    let kinds = ["stroke", "note", "shape", "stroke", "image", "gif", ""];
    let width = if rng.chance(5) { 7 } else { 4 };
    let mut out = json!({
        "id": if rng.chance(2) { json!("junk") } else { json!(id()) },
        "kind": kinds[rng.below(width) as usize],
        "x": number(rng, "x"), "y": number(rng, "y"), "w": number(rng, "w"), "h": number(rng, "h"),
        "props": if rng.chance(70) { json!({ "points": [0, 0, 1, 1] }) } else { junk(rng) },
    });
    if rng.chance(10) {
        out.as_object_mut()
            .unwrap()
            .remove(["x", "y", "w", "h", "props"][rng.below(5) as usize]);
    }
    out
}

async fn get(app: &Router, uri: &str, token: &str) -> StatusCode {
    let request = Request::builder()
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    app.clone().oneshot(request).await.unwrap().status()
}

fn query(rng: &mut Rng) -> String {
    let word = |rng: &mut Rng| match rng.below(8) {
        0 => "NaN".to_owned(),
        1 => "inf".to_owned(),
        2 => "-1e999".to_owned(),
        3 => "".to_owned(),
        4 => "abc".to_owned(),
        5 => "5000001".to_owned(),
        _ => rng.range(-3000, 3000).to_string(),
    };
    let mut parts = Vec::new();
    for key in [
        "min_x",
        "min_y",
        "max_x",
        "max_y",
        "prev_min_x",
        "prev_min_y",
        "prev_max_x",
        "prev_max_y",
        "after_seq",
        "limit",
    ] {
        if rng.chance(if key.starts_with("prev") { 25 } else { 90 }) {
            parts.push(format!("{key}={}", word(rng)));
        }
    }
    parts.join("&")
}

#[tokio::test]
async fn malformed_canvas_requests_never_answer_with_a_server_error() {
    for seed in 1..=4u64 {
        let (store, _pool, _guard) = new_store_and_pool().await;
        let (_, root) = register(&store, "root").await;
        let channel: ChannelId = general(&store).await;
        let router = app(store.clone());
        let mut tokens = Vec::new();
        let mut users: Vec<UserId> = vec![root];
        for n in 0..16 {
            let (token, user) = fixtures::member(&store, &format!("m{seed}-{n}")).await;
            tokens.push(token);
            users.push(user);
        }
        let mut pools = Pools {
            objects: Vec::new(),
            ops: Vec::new(),
            users: users.iter().map(ToString::to_string).collect(),
        };
        for n in 0..12 {
            let (status, placed) =
                post_object(&router, channel, &tokens[n % 3], stroke(&id())).await;
            assert_eq!(status, StatusCode::CREATED, "{placed}");
            pools
                .objects
                .push(placed["id"].as_str().unwrap().to_owned());
        }
        let mut rng = Rng::new(seed);
        let mut served = 0;
        let mut histogram = std::collections::BTreeMap::<String, u32>::new();
        for n in 0..640 {
            let token = &tokens[(n / 40) % tokens.len()];
            let (status, reply) = match rng.below(10) {
                0..=5 => submit_op(&router, channel, token, body(&mut rng, &pools)).await,
                6 | 7 => post_object(&router, channel, token, placement(&mut rng)).await,
                _ => (
                    get(
                        &router,
                        &format!("/channels/{channel}/canvas/objects?{}", query(&mut rng)),
                        token,
                    )
                    .await,
                    Value::Null,
                ),
            };
            assert!(
                !status.is_server_error(),
                "seed {seed} request {n} answered {status}: {reply}"
            );
            *histogram
                .entry(format!(
                    "{} {}",
                    status.as_u16(),
                    reply["error"]
                        .as_str()
                        .unwrap_or("")
                        .chars()
                        .take(40)
                        .collect::<String>()
                ))
                .or_default() += 1;
            if status.is_success() {
                served += 1;
            }
            if let Some(op) = reply["op"]["id"].as_str() {
                pools.ops.push(op.to_owned());
            }
            if let Some(object) = reply["id"].as_str().filter(|_| reply["kind"].is_string()) {
                pools.objects.push(object.to_owned());
            }
        }
        assert!(
            served > 20,
            "seed {seed}: only {served} requests were accepted ({histogram:?}), the generator is too hostile to test anything"
        );
        replay_matches_live(&store, channel)
            .await
            .unwrap_or_else(|e| panic!("seed {seed}: {e}"));
    }
}
