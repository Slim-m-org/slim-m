// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Runs a step list against a real store and the oracle side by side.

use std::collections::{BTreeMap, HashMap};

use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{CanvasOpRequest, ClearScope, LockError, PlaceRequest, Store};
use sqlx::SqlitePool;

use crate::compare::{Got, map_place, map_submit};
use crate::oracle::{Fail, Oracle, Pred, props_for};
use crate::replay::Client;
use crate::script::{Act, Cfg, Fence, Kind, Rng, Step};

#[derive(Clone, Debug)]
pub struct Violation {
    pub sig: String,
    pub step: usize,
    pub detail: String,
}

pub type Check = Result<(), Violation>;

pub struct Report {
    pub fatal: Option<Violation>,
    pub soft: Vec<Violation>,
    pub stats: BTreeMap<String, u64>,
}

pub struct Done {
    pub act: Act,
    pub writer: usize,
}

pub struct World {
    pub store: Store,
    pub pool: SqlitePool,
    pub channel: ChannelId,
    pub writers: Vec<UserId>,
    pub oracle: Oracle,
    pub obj_ids: HashMap<u32, CanvasObjectId>,
    pub op_ids: HashMap<u32, CanvasOpId>,
    pub history: HashMap<u32, Done>,
    pub shadows: Vec<Client>,
    pub soft: Vec<Violation>,
    pub stats: BTreeMap<String, u64>,
    pub swept_once: bool,
    pub replay_broken: bool,
    pub rng: Rng,
    image: Option<Vec<u8>>,
    _guard: crate::support::TestDbGuard,
}

pub fn v(sig: impl Into<String>, step: usize, detail: impl Into<String>) -> Violation {
    Violation {
        sig: sig.into(),
        step,
        detail: detail.into(),
    }
}

impl World {
    pub async fn new(cfg: &Cfg, seed: u64, with_images: bool) -> Self {
        let (store, pool, guard) = crate::support::new_store_with_pool("slimm-canvas-fuzz").await;
        let mut writers = vec![crate::support::app::register_id(&store, "w0").await];
        for i in 1..cfg.writers {
            let name = format!("w{i}");
            writers.push(
                store
                    .create_account(&name, &name, "not-a-real-hash")
                    .await
                    .unwrap()
                    .id,
            );
        }
        let channel = store.list_channels().await.unwrap()[0].id;
        if cfg.cap != 20_000 {
            store.set_canvas_object_cap(cfg.cap).await.unwrap();
        }
        let mods = (0..cfg.writers).map(|i| i == 0 || i == 3).collect();
        let image = if with_images {
            Some(upload_png(&store, &writers).await)
        } else {
            None
        };
        Self {
            oracle: Oracle::new(mods, cfg.cap),
            store,
            pool,
            channel,
            writers,
            obj_ids: HashMap::new(),
            op_ids: HashMap::new(),
            history: HashMap::new(),
            shadows: Vec::new(),
            soft: Vec::new(),
            stats: BTreeMap::new(),
            swept_once: false,
            replay_broken: false,
            rng: Rng::new(seed ^ 0x00C0_FFEE),
            image,
            _guard: guard,
        }
    }

    pub fn obj_id(&mut self, label: u32) -> CanvasObjectId {
        *self
            .obj_ids
            .entry(label)
            .or_insert_with(CanvasObjectId::generate)
    }

    fn op_id(&mut self, label: u32) -> CanvasOpId {
        *self
            .op_ids
            .entry(label)
            .or_insert_with(CanvasOpId::generate)
    }

    fn request(&mut self, act: &Act) -> CanvasOpRequest {
        match act {
            Act::Move { obj, b } => CanvasOpRequest::Move {
                object_id: self.obj_id(*obj),
                x: b.0,
                y: b.1,
                w: b.2,
                h: b.3,
            },
            Act::Edit { obj, text } => CanvasOpRequest::Edit {
                object_id: self.obj_id(*obj),
                props: props_for(Kind::Note, *text),
            },
            Act::Reorder { obj, z } => CanvasOpRequest::Reorder {
                object_id: self.obj_id(*obj),
                z_index: *z,
            },
            Act::Remove { objs } => {
                CanvasOpRequest::Remove(objs.iter().map(|o| self.obj_id(*o)).collect())
            }
            Act::Restore { op } => CanvasOpRequest::Restore {
                target_op: self.op_id(*op),
            },
            Act::Clear {
                fence,
                kinds,
                author,
            } => {
                let latest = self.oracle.latest;
                let before_seq = match fence {
                    Fence::Head => latest,
                    Fence::Behind(n) => (latest - n).max(0),
                    Fence::Ahead(n) => latest + n,
                    Fence::Zero => 0,
                };
                let kinds = kinds.iter().map(|k| k.as_str().to_owned()).collect();
                CanvasOpRequest::Clear {
                    before_seq,
                    scope: ClearScope {
                        kinds,
                        author_id: author.map(|a| self.writers[a]),
                    },
                }
            }
            other => unreachable!("not an op request: {other:?}"),
        }
    }

    pub async fn run(&mut self, steps: &[Step], prelude: usize) -> Check {
        let joins = [0, steps.len() / 3, 2 * steps.len() / 3];
        for (i, step) in steps.iter().enumerate() {
            if joins.contains(&i) {
                let client = Client::cold(&self.store, self.channel)
                    .await
                    .map_err(|e| v("shadow:cold_fetch", i, e))?;
                self.shadows.push(client);
            }
            self.step(i, step).await?;
            if i < prelude && i % 150 != 149 {
                continue;
            }
            self.check_cheap(i).await?;
            self.poll_shadows(i).await?;
            if i % 20 == 19 && i >= prelude {
                self.check_deep(i).await?;
            }
        }
        self.check_deep(steps.len()).await
    }

    async fn step(&mut self, i: usize, step: &Step) -> Check {
        let src = match &step.act {
            Act::Retry { of } => match self.history.get(of) {
                Some(done) => Step {
                    label: *of,
                    writer: done.writer,
                    act: done.act.clone(),
                },
                None => return Ok(()),
            },
            _ => step.clone(),
        };
        match &src.act {
            Act::SetCap(n) => {
                self.store
                    .set_canvas_object_cap(*n)
                    .await
                    .map_err(|e| v("set_cap:failed", i, e.to_string()))?;
                self.oracle.cap = *n;
                return Ok(());
            }
            Act::SetMod { who, on } => {
                self.oracle.mods[*who] = *on;
                return Ok(());
            }
            Act::Restart => {
                self.store = Store::new(self.pool.clone());
                return Ok(());
            }
            Act::AgeAndSweep => return self.age_and_sweep(i).await,
            Act::Lock { obj, on } => return self.lock(i, &src, *obj, *on).await,
            _ => {}
        }
        let is_retry = matches!(step.act, Act::Retry { .. });
        let (pred, got) = if matches!(src.act, Act::Place { .. }) {
            self.run_place(&src).await
        } else {
            self.run_op(&src).await
        };
        self.compare(i, &src, &pred, got)?;
        self.remember(&src, is_retry);
        Ok(())
    }

    async fn run_place(&mut self, src: &Step) -> (Pred, Result<Got, Fail>) {
        let Act::Place { kind, b, text } = &src.act else {
            unreachable!("caller matched Place")
        };
        let id = self.obj_id(src.label);
        let props = props_for(*kind, *text);
        let attachment = if *kind == Kind::Image {
            self.image.clone()
        } else {
            None
        };
        let pred = self.oracle.predict(src);
        let request = PlaceRequest {
            kind: kind.as_str(),
            bounds: *b,
            props: &props,
            attachment: attachment.as_deref(),
        };
        let placed = self
            .store
            .place_canvas_object(self.channel, self.writers[src.writer], id, request)
            .await;
        (pred, map_place(placed))
    }

    async fn run_op(&mut self, src: &Step) -> (Pred, Result<Got, Fail>) {
        let request = self.request(&src.act);
        let pred = self.oracle.predict(src);
        let op_id = self.op_id(src.label);
        let moderator = self.oracle.mods[src.writer];
        let outcome = self
            .store
            .submit_canvas_op(
                self.channel,
                self.writers[src.writer],
                op_id,
                moderator,
                request,
            )
            .await;
        (pred, map_submit(outcome))
    }

    fn remember(&mut self, src: &Step, is_retry: bool) {
        if !is_retry {
            self.history.insert(
                src.label,
                Done {
                    act: src.act.clone(),
                    writer: src.writer,
                },
            );
        }
    }

    async fn lock(&mut self, i: usize, src: &Step, obj: u32, on: bool) -> Check {
        let id = self.obj_id(obj);
        let moderator = self.oracle.mods[src.writer];
        let pred: Result<bool, Fail> = match self.oracle.objs.get_mut(&obj) {
            None => Err(Fail::NotFound),
            Some(o) if !o.alive => Err(Fail::NotFound),
            Some(o) if !moderator && o.author != src.writer => Err(Fail::NotAuthorized),
            Some(o) => {
                let changed = o.locked != on;
                o.locked = on;
                Ok(changed)
            }
        };
        let got = match self
            .store
            .set_canvas_object_lock(self.channel, id, self.writers[src.writer], moderator, on)
            .await
        {
            Ok(version) => Ok(version.is_some()),
            Err(LockError::NotFound) => Err(Fail::NotFound),
            Err(LockError::NotAuthorized) => Err(Fail::NotAuthorized),
            Err(LockError::Internal(e)) => Err(Fail::Internal(format!("{e:#}"))),
        };
        self.remember(src, false);
        if pred == got {
            return Ok(());
        }
        Err(v(
            "lock:outcome",
            i,
            format!(
                "lock obj {obj} on={on} by w{}: expected {pred:?}, store said {got:?}",
                src.writer
            ),
        ))
    }

    async fn poll_shadows(&mut self, i: usize) -> Check {
        let want = self
            .table_alive()
            .await
            .map_err(|e| v("table:read", i, e))?;
        let page = 1 + self.rng.below(6) as i64;
        for (n, shadow) in self.shadows.iter_mut().enumerate() {
            shadow
                .catch_up(&self.store, self.channel, page, true)
                .await
                .map_err(|e| v("shadow:feed", i, e))?;
            if let Some(diff) =
                crate::replay::first_diff(&format!("shadow {n}"), &shadow.alive(), &want)
            {
                return Err(v("shadow:diverged_from_table", i, diff));
            }
        }
        Ok(())
    }

    pub fn tally(self, fatal: Option<Violation>) -> Report {
        Report {
            fatal,
            soft: self.soft,
            stats: self.stats,
        }
    }
}

async fn upload_png(store: &Store, writers: &[UserId]) -> Vec<u8> {
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;
    let app = crate::support::app::router(store.clone());
    let mut sha = Vec::new();
    for &writer in writers {
        let token = store
            .open_session(writer, "cli")
            .await
            .unwrap()
            .access_token;
        let request = Request::builder()
            .method("POST")
            .uri("/attachments?filename=fuzz.png")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::from(vec![
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            ]))
            .unwrap();
        let response = app.clone().oneshot(request).await.unwrap();
        assert_eq!(
            response.status(),
            axum::http::StatusCode::CREATED,
            "png upload"
        );
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        sha = slimm_server::media::from_hex(body["id"].as_str().unwrap()).unwrap();
    }
    sha
}

pub async fn run(steps: &[Step], cfg: &Cfg, seed: u64) -> Report {
    let with_images = steps.iter().any(|s| {
        matches!(
            s.act,
            Act::Place {
                kind: Kind::Image,
                ..
            }
        )
    });
    let mut world = World::new(cfg, seed, with_images).await;
    let fatal = world.run(steps, cfg.prelude.min(steps.len())).await.err();
    world.tally(fatal)
}
