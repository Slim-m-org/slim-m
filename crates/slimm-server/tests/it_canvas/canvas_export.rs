// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Exporting a board into a new canvas channel (decision 0139): what is copied, and how faithfully.

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::hub::Hub;
use slimm_server::ids::{CanvasObjectId, ChannelId, UserId};
use slimm_server::store::{PlaceRequest, Store};
use sqlx::SqlitePool;

use crate::canvas_ops::fixtures::{new_store_and_pool, register};
use crate::support;
use crate::support::canvas::BoardChannels;

/// One live object as the copy is judged against the original.
#[derive(Debug, Clone, PartialEq, sqlx::FromRow)]
pub(crate) struct Row {
    pub id: CanvasObjectId,
    pub kind: String,
    pub z_index: i64,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub author_id: Option<UserId>,
    pub created_at: i64,
    pub props: String,
}

pub(crate) struct Rig {
    pub store: Store,
    pub pool: SqlitePool,
    pub app: Router,
    pub hub: Hub,
    pub token: String,
    pub admin: UserId,
    pub source: ChannelId,
    pub _guard: support::TestDbGuard,
}

impl Rig {
    pub(crate) async fn new() -> Self {
        let (store, pool, guard) = new_store_and_pool().await;
        let (token, admin) = register(&store, "root").await;
        let source = store
            .create_voice_with_canvas("minecraft")
            .await
            .unwrap()
            .id;
        let hub = Hub::new();
        Self {
            app: support::app::builder(store.clone())
                .hub(hub.clone())
                .router(),
            store,
            pool,
            hub,
            token,
            admin,
            source,
            _guard: guard,
        }
    }

    pub(crate) fn body(id: ChannelId, name: &str) -> Value {
        json!({ "id": id.to_string(), "name": name })
    }

    pub(crate) async fn export_from(
        &self,
        token: &str,
        source: ChannelId,
        body: Value,
    ) -> (StatusCode, Value) {
        let uri = format!("/channels/{source}/canvas/export");
        let request = support::app::request_json("POST", &uri, token, body);
        let response = tower::ServiceExt::oneshot(self.app.clone(), request)
            .await
            .unwrap();
        let status = response.status();
        (status, support::app::json_body_or_null(response).await)
    }

    pub(crate) async fn export(&self, body: Value) -> (StatusCode, Value) {
        self.export_from(&self.token, self.source, body).await
    }

    pub(crate) async fn place(&self, kind: &str, props: Value) -> CanvasObjectId {
        self.place_in(self.source, kind, (10.0, 20.0, 30.0, 40.0), props)
            .await
    }

    pub(crate) async fn place_in(
        &self,
        channel: ChannelId,
        kind: &str,
        bounds: (f64, f64, f64, f64),
        props: Value,
    ) -> CanvasObjectId {
        let id = CanvasObjectId::generate();
        self.store
            .place_canvas_object(
                channel,
                self.admin,
                id,
                PlaceRequest {
                    kind,
                    bounds,
                    props: &props.to_string(),
                    attachment: None,
                },
            )
            .await
            .unwrap();
        id
    }

    pub(crate) async fn rows(&self, channel: ChannelId) -> Vec<Row> {
        sqlx::query_as(
            "SELECT o.id, o.kind, o.z_index, o.x, o.y, o.w, o.h, o.author_id, o.created_at, p.props \
             FROM canvas_objects o JOIN canvas_object_props p ON p.object_id = o.id \
             WHERE o.channel_id = ? AND o.deleted_at IS NULL ORDER BY o.z_index, o.seq",
        )
        .bind(channel)
        .fetch_all(&self.pool)
        .await
        .unwrap()
    }

    pub(crate) async fn scalar(&self, sql: &'static str, channel: ChannelId) -> i64 {
        sqlx::query_scalar(sql)
            .bind(channel)
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }

    pub(crate) async fn exec(&self, sql: impl Into<String>) {
        sqlx::query(sqlx::AssertSqlSafe(sql.into()))
            .execute(&self.pool)
            .await
            .unwrap();
    }
}

pub(crate) fn props_of(row: &Row) -> Value {
    serde_json::from_str(&row.props).unwrap()
}

/// What a row says about itself, apart from its id.
fn shape(row: &Row) -> (String, i64, [f64; 4], Option<UserId>, i64) {
    (
        row.kind.clone(),
        row.z_index,
        [row.x, row.y, row.w, row.h],
        row.author_id,
        row.created_at,
    )
}

#[tokio::test]
async fn every_kind_is_copied_with_its_box_props_author_and_time() {
    let rig = Rig::new().await;
    rig.place(
        "stroke",
        json!({ "points": [0.0, 0.0, 3.0, 4.0], "width": 3.0 }),
    )
    .await;
    rig.place("note", json!({ "text": "stone", "color": "annotation" }))
        .await;
    rig.place("text", json!({ "text": "plan" })).await;
    rig.place("shape", json!({ "shape": "ellipse" })).await;
    rig.place("emoji", json!({ "emoji": "x" })).await;
    let before = rig.rows(rig.source).await;
    let id = ChannelId::generate();

    let (status, body) = rig.export(Rig::body(id, "minecraft canvas")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["copied"], 5);
    assert_eq!(body["skipped"], 0);
    assert_eq!(body["cleared"], 0);
    assert_eq!(body["channel"]["id"], id.to_string());
    assert_eq!(body["channel"]["kind"], "canvas");
    assert_eq!(body["channel"]["name"], "minecraft canvas");
    let after = rig.rows(id).await;
    assert_eq!(after.len(), 5);
    for (old, new) in before.iter().zip(&after) {
        assert_ne!(old.id, new.id, "an export mints a new id for every object");
        assert_eq!(shape(old), shape(new));
        assert_eq!(props_of(old), props_of(new));
    }
    assert_eq!(
        rig.rows(rig.source).await,
        before,
        "the source is untouched"
    );
}

#[tokio::test]
async fn a_copied_object_is_placed_by_one_dense_op_each() {
    let rig = Rig::new().await;
    for n in 0..3 {
        rig.place("note", json!({ "text": n.to_string() })).await;
    }
    let id = ChannelId::generate();
    rig.export(Rig::body(id, "copy")).await;

    let seqs: Vec<i64> = sqlx::query_scalar(
        "SELECT seq FROM canvas_ops WHERE channel_id = ? AND kind = 'place' ORDER BY seq",
    )
    .bind(id)
    .fetch_all(&rig.pool)
    .await
    .unwrap();
    assert_eq!(seqs, vec![1, 2, 3]);
    let targets = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_op_targets t JOIN canvas_objects o ON o.id = t.object_id \
             WHERE t.channel_id = ? AND o.channel_id = t.channel_id AND o.seq = t.seq",
            id,
        )
        .await;
    assert_eq!(targets, 3);
    let next = rig
        .scalar(
            "SELECT next_seq FROM channel_seq_counters WHERE channel_id = ? AND stream = 'canvas'",
            id,
        )
        .await;
    assert_eq!(next, 4);
}

#[tokio::test]
async fn authorship_survives_and_a_blocked_deleted_author_stays_hidden_on_the_copy() {
    let rig = Rig::new().await;
    let blocker = rig
        .store
        .create_user("blocker", "Blocker")
        .await
        .unwrap()
        .id;
    let gone = rig
        .place("note", json!({ "text": "from someone who left" }))
        .await;
    rig.exec("UPDATE canvas_objects SET author_id = NULL WHERE seq = 1")
        .await;
    sqlx::query("INSERT INTO blocked_author_canvas_objects (object_id, author_id) VALUES (?, ?)")
        .bind(gone)
        .bind(blocker)
        .execute(&rig.pool)
        .await
        .unwrap();
    rig.place("note", json!({ "text": "mine" })).await;
    rig.exec("UPDATE canvas_objects SET created_at = 1234 WHERE seq = 2")
        .await;

    let id = ChannelId::generate();
    rig.export(Rig::body(id, "copy")).await;

    let after = rig.rows(id).await;
    assert_eq!(after[0].author_id, None);
    assert_eq!(after[1].author_id, Some(rig.admin));
    assert_eq!(after[1].created_at, 1234);
    let hidden: Vec<(CanvasObjectId, UserId)> = sqlx::query_as(
        "SELECT object_id, author_id FROM blocked_author_canvas_objects WHERE object_id = ?",
    )
    .bind(after[0].id)
    .fetch_all(&rig.pool)
    .await
    .unwrap();
    assert_eq!(hidden, vec![(after[0].id, blocker)]);
    let still = rig
        .scalar("SELECT COUNT(*) FROM blocked_author_canvas_objects WHERE author_id IS NOT NULL AND object_id IN (SELECT id FROM canvas_objects WHERE channel_id = ?)", rig.source)
        .await;
    assert_eq!(still, 1, "the source row stays");
}

#[tokio::test]
async fn locks_and_scenes_are_copied_with_their_timers_nulled_and_media_slots_are_not() {
    let rig = Rig::new().await;
    let pinned = rig.place("note", json!({ "text": "pinned" })).await;
    let tile = rig
        .place("module", json!({ "module_id": "board", "tile": "Board" }))
        .await;
    rig.exec(
        "INSERT INTO installed_modules (id, name, version, artifact_sha256, enabled, installed_at) \
         VALUES ('board', 'Board', '0.1.0', 'x', 1, 0)",
    )
    .await;
    sqlx::query("INSERT INTO canvas_object_locks (object_id, channel_id, locked_by, locked_at) VALUES (?, ?, ?, 77)")
        .bind(pinned)
        .bind(rig.source)
        .bind(rig.admin)
        .execute(&rig.pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO canvas_tile_scenes (object_id, channel_id, output, ran_by, ran_at, refresh_due_at, refresh_until_at) \
         VALUES (?, ?, 'frame', ?, 5, 100, 200)",
    )
    .bind(tile)
    .bind(rig.source)
    .bind(rig.admin)
    .execute(&rig.pool)
    .await
    .unwrap();
    rig.exec(&format!(
        "INSERT INTO canvas_media_slots (channel_id, user_id, kind, x, y, w, h, locked, sent_to_back, updated_at) \
         VALUES (x'{}', x'{}', 'camera', 0, 0, 10, 10, 0, 0, 1)",
        hex(rig.source.0.as_bytes()),
        hex(rig.admin.0.as_bytes()),
    ))
    .await;

    let id = ChannelId::generate();
    let (status, body) = rig.export(Rig::body(id, "copy")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    let after = rig.rows(id).await;
    let lock: (i64, UserId) =
        sqlx::query_as("SELECT locked_at, locked_by FROM canvas_object_locks WHERE object_id = ?")
            .bind(after[0].id)
            .fetch_one(&rig.pool)
            .await
            .unwrap();
    assert_eq!(lock, (77, rig.admin));
    let scene: (String, Option<i64>, Option<i64>) = sqlx::query_as(
        "SELECT output, refresh_due_at, refresh_until_at FROM canvas_tile_scenes WHERE object_id = ?",
    )
    .bind(after[1].id)
    .fetch_one(&rig.pool)
    .await
    .unwrap();
    assert_eq!(scene, ("frame".to_owned(), None, None));
    let slots = rig
        .scalar(
            "SELECT COUNT(*) FROM canvas_media_slots WHERE channel_id = ?",
            id,
        )
        .await;
    assert_eq!(slots, 0);
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[tokio::test]
async fn an_image_keeps_its_bytes_while_either_board_holds_them() {
    let rig = Rig::new().await;
    let png = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    let request = axum::http::Request::builder()
        .method("POST")
        .uri("/attachments?filename=pasted.png")
        .header("authorization", format!("Bearer {}", rig.token))
        .body(axum::body::Body::from(png))
        .unwrap();
    let response = tower::ServiceExt::oneshot(rig.app.clone(), request)
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    let attachment = support::app::json_body(response).await["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let (status, _) = crate::canvas_ops::fixtures::post_object(
        &rig.app,
        rig.source,
        &rig.token,
        json!({ "id": CanvasObjectId::generate().to_string(), "kind": "image", "x": 0.0, "y": 0.0, "w": 64.0, "h": 64.0,
                "props": { "attachment": attachment, "content_type": "image/png" } }),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    let id = ChannelId::generate();
    let mut body = Rig::body(id, "copy");
    body["clear_source"] = json!(true);
    let (status, answer) = rig.export(body).await;
    assert_eq!(status, StatusCode::OK, "{answer}");
    assert_eq!(answer["cleared"], 1);
    let copies = rig
        .scalar("SELECT COUNT(*) FROM canvas_object_attachments a JOIN canvas_objects o ON o.id = a.object_id WHERE o.channel_id = ?", id)
        .await;
    assert_eq!(copies, 1);

    rig.exec("UPDATE attachments SET created_at = 0").await;
    rig.store.sweep_orphaned_attachments().await.unwrap();
    let kept = rig
        .scalar("SELECT COUNT(*) FROM attachments WHERE ? IS NOT NULL", id)
        .await;
    assert_eq!(
        kept, 1,
        "the copy on the new board holds the bytes after the source was cleared"
    );
}
