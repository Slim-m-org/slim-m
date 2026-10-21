// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Seeded random canvas sessions against the real store, exported as the wire JSON a client reads: the whole op feed and the live objects it ends at.
//! The Dart client replays them (`client/packages/app/test/features/canvas/canvas_server_feed_replay_test.dart`); `CANVAS_FEED_EXPORT_DIR` writes the files, otherwise the test only checks the feed is sound.

use std::path::PathBuf;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, ClearScope, PlaceRequest, Store};
use tower::ServiceExt;

use crate::fixtures::{app, general, get_ops, member, new_store, register};

/// xorshift64*: small, seeded, and the same on every platform.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn between(&mut self, lo: f64, hi: f64) -> f64 {
        lo + self.unit() * (hi - lo)
    }
}

struct Session {
    store: Store,
    channel: ChannelId,
    actors: Vec<(UserId, bool)>,
    objects: Vec<(CanvasObjectId, usize, &'static str)>,
    removals: Vec<(CanvasOpId, usize)>,
    rng: Rng,
}

impl Session {
    fn actor(&mut self) -> usize {
        self.rng.below(self.actors.len())
    }

    fn object(&mut self) -> Option<(CanvasObjectId, usize)> {
        let (id, owner, _) = *self
            .objects
            .get(self.rng.below(self.objects.len().max(1)))?;
        Some((id, owner))
    }

    fn note(&mut self) -> Option<(CanvasObjectId, usize)> {
        let notes: Vec<_> = self.objects.iter().filter(|o| o.2 == "note").collect();
        let (id, owner, _) = **notes.get(self.rng.below(notes.len().max(1)))?;
        Some((id, owner))
    }

    async fn place(&mut self) {
        let who = self.actor();
        let kind = ["stroke", "stroke", "note", "shape"][self.rng.below(4)];
        let (w, h) = (self.rng.between(10.0, 300.0), self.rng.between(10.0, 200.0));
        let (x, y) = (self.rng.between(0.0, 1500.0), self.rng.between(0.0, 800.0));
        let shape = ["rectangle", "ellipse", "line", "arrow"][self.rng.below(4)];
        let props = match kind {
            "stroke" => {
                json!({ "points": [0.0, 0.0, w / 2.0, h, w, 0.0], "width": 3.0, "color": "annotation" })
            }
            "note" => json!({ "text": format!("note {}", self.rng.below(1000)) }),
            _ => json!({ "shape": shape }),
        };
        let id = CanvasObjectId::generate();
        let props = props.to_string();
        let placed = self
            .store
            .place_canvas_object(
                self.channel,
                self.actors[who].0,
                id,
                PlaceRequest {
                    kind,
                    bounds: (x, y, w, h),
                    props: &props,
                    attachment: None,
                },
            )
            .await;
        if placed.is_ok() {
            self.objects.push((id, who, kind));
        }
    }

    async fn submit(&mut self, who: usize, request: CanvasOpRequest) -> Option<(CanvasOpId, i64)> {
        let id = CanvasOpId::generate();
        let (actor, moderator) = self.actors[who];
        let done = self
            .store
            .submit_canvas_op(self.channel, actor, id, moderator, request)
            .await
            .ok()?;
        Some((id, done.affected))
    }

    async fn step(&mut self) {
        let roll = self.rng.below(100);
        let head = self.store.latest_head(self.channel).await;
        if roll < 34 || self.objects.is_empty() {
            return self.place().await;
        }
        let who = self.actor();
        let Some((target, owner)) = self.object() else {
            return;
        };
        let by_owner = if roll.is_multiple_of(3) { who } else { owner };
        match roll {
            34..=50 => {
                let b = (
                    self.rng.between(0.0, 1500.0),
                    self.rng.between(0.0, 800.0),
                    self.rng.between(10.0, 300.0),
                    self.rng.between(10.0, 200.0),
                );
                let request = CanvasOpRequest::Move {
                    object_id: target,
                    x: b.0,
                    y: b.1,
                    w: b.2,
                    h: b.3,
                };
                self.submit(by_owner, request).await;
            }
            51..=58 => {
                let z_index = head + self.rng.below(20) as i64 - 8;
                self.submit(
                    by_owner,
                    CanvasOpRequest::Reorder {
                        object_id: target,
                        z_index,
                    },
                )
                .await;
            }
            59..=63 => {
                let Some((note, owner)) = self.note() else {
                    return;
                };
                let props = json!({ "text": format!("edit {}", self.rng.below(1000)) }).to_string();
                self.submit(
                    owner,
                    CanvasOpRequest::Edit {
                        object_id: note,
                        props,
                    },
                )
                .await;
            }
            64..=77 => {
                let mut ids = vec![target];
                for _ in 0..self.rng.below(3) {
                    if let Some((extra, _)) = self.object() {
                        ids.push(extra);
                    }
                }
                ids.dedup();
                if let Some((op, affected)) =
                    self.submit(by_owner, CanvasOpRequest::Remove(ids)).await
                    && affected > 0
                {
                    self.removals.push((op, by_owner));
                }
            }
            78..=83 => {
                let before_seq = self.rng.below((head + 1) as usize) as i64;
                let scope = match self.rng.below(3) {
                    0 => ClearScope::default(),
                    1 => ClearScope {
                        kinds: vec![["stroke", "note", "shape"][self.rng.below(3)].to_owned()],
                        author_id: None,
                    },
                    _ => ClearScope {
                        kinds: vec![],
                        author_id: Some(self.actors[self.rng.below(self.actors.len())].0),
                    },
                };
                let admin = 0;
                if let Some((op, affected)) = self
                    .submit(admin, CanvasOpRequest::Clear { before_seq, scope })
                    .await
                    && affected > 0
                {
                    self.removals.push((op, admin));
                }
            }
            84..=93 if !self.removals.is_empty() => {
                let (target_op, owner) = self.removals[self.rng.below(self.removals.len())];
                let who = if self.rng.below(2) == 0 { owner } else { 0 };
                self.submit(who, CanvasOpRequest::Restore { target_op })
                    .await;
            }
            _ => {
                let (actor, moderator) = self.actors[by_owner];
                let locked = self.rng.below(2) == 0;
                let _ = self
                    .store
                    .set_canvas_object_lock(self.channel, target, actor, moderator, locked)
                    .await;
            }
        }
    }
}

trait Head {
    async fn latest_head(&self, channel: ChannelId) -> i64;
}

impl Head for Store {
    async fn latest_head(&self, channel: ChannelId) -> i64 {
        self.list_canvas_ops(channel, 0, 1)
            .await
            .map_or(0, |p| p.latest_seq)
    }
}

async fn get_objects(app: &Router, channel: ChannelId, token: &str) -> Value {
    let uri = format!(
        "/channels/{channel}/canvas/objects?min_x=-4000000&min_y=-4000000&max_x=4000000&max_y=4000000&limit=2000"
    );
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri(uri)
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

async fn whole_feed(app: &Router, channel: ChannelId, token: &str) -> (Vec<Value>, i64) {
    let mut ops = Vec::new();
    let mut after = 0;
    loop {
        let (status, page) =
            get_ops(app, channel, token, &format!("after_seq={after}&limit=200")).await;
        assert_eq!(status, StatusCode::OK, "{page}");
        assert_eq!(page["reset"], json!(false), "a fresh feed never resets");
        let rows = page["ops"].as_array().unwrap().clone();
        let latest = page["latest_seq"].as_i64().unwrap();
        if let Some(last) = rows.last() {
            after = last["seq"].as_i64().unwrap();
        }
        ops.extend(rows);
        if page["has_more"] != json!(true) {
            return (ops, latest);
        }
    }
}

async fn run_seed(seed: u64, steps: usize) -> Value {
    let (store, _guard) = new_store().await;
    let (admin_token, admin) = register(&store, "root").await;
    let (_, ann) = member(&store, "ann").await;
    let (_, bob) = member(&store, "bob").await;
    let channel = general(&store).await;
    let router = app(store.clone());
    let mut session = Session {
        store: store.clone(),
        channel,
        actors: vec![(admin, true), (ann, false), (bob, false)],
        objects: Vec::new(),
        removals: Vec::new(),
        rng: Rng::new(seed),
    };
    for _ in 0..steps {
        session.step().await;
    }
    let (ops, latest) = whole_feed(&router, channel, &admin_token).await;
    assert_eq!(
        ops.len() as i64,
        latest,
        "the feed is dense: one op per seq"
    );
    let page = get_objects(&router, channel, &admin_token).await;
    let locked = store.list_canvas_object_locks(channel).await.unwrap();
    json!({
        "seed": seed,
        "latest_seq": latest,
        "ops": ops,
        "objects": page["objects"],
        "locked": locked.iter().map(ToString::to_string).collect::<Vec<_>>(),
    })
}

#[tokio::test]
async fn seeded_sessions_export_a_sound_feed() {
    let dir = std::env::var_os("CANVAS_FEED_EXPORT_DIR").map(PathBuf::from);
    for seed in 1..=8u64 {
        let session = run_seed(seed, 170).await;
        assert!(
            session["latest_seq"].as_i64().unwrap() > 20,
            "seed {seed} did too little"
        );
        if let Some(dir) = &dir {
            std::fs::create_dir_all(dir).unwrap();
            std::fs::write(
                dir.join(format!("canvas-feed-seed-{seed}.json")),
                serde_json::to_vec(&session).unwrap(),
            )
            .unwrap();
        }
    }
}
