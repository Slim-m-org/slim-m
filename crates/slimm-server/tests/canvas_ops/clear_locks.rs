// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A clear and locked objects (decision 0085): the first clear leaves locked
//! objects standing and says which, a second one with only locked objects left
//! removes them, and an undo brings back whatever each one removed.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::ids::{CanvasObjectId, CanvasOpId, ChannelId, UserId};
use slimm_server::store::{
    CanvasOpBody, CanvasOpRequest, ClearScope, PlaceRequest, Store, SubmittedOp,
};

use crate::fixtures::{
    app, general, get_ops, id, new_store, post_object, register, stroke, submit_op,
};

async fn place(store: &Store, channel: ChannelId, author: UserId, kind: &str) -> CanvasObjectId {
    let object = CanvasObjectId::generate();
    let request = PlaceRequest {
        kind,
        bounds: (0.0, 0.0, 10.0, 10.0),
        props: "{}",
        attachment: None,
    };
    store
        .place_canvas_object(channel, author, object, request)
        .await
        .expect("placed");
    object
}

async fn clear(store: &Store, channel: ChannelId, actor: UserId, scope: ClearScope) -> SubmittedOp {
    let head = store
        .list_canvas_ops(channel, 0, 1)
        .await
        .unwrap()
        .latest_seq;
    store
        .submit_canvas_op(
            channel,
            actor,
            CanvasOpId::generate(),
            true,
            CanvasOpRequest::Clear {
                before_seq: head,
                scope,
            },
        )
        .await
        .unwrap()
}

async fn alive(store: &Store, channel: ChannelId) -> Vec<CanvasObjectId> {
    store
        .viewport_page(channel, world(), 0, 1000)
        .await
        .unwrap()
        .2
        .into_iter()
        .map(|o| o.id)
        .collect()
}

fn world() -> slimm_server::store::Rect {
    slimm_server::store::Rect {
        min_x: -1e6,
        min_y: -1e6,
        max_x: 1e6,
        max_y: 1e6,
    }
}

#[tokio::test]
async fn a_clear_leaves_locked_objects_and_a_second_clear_takes_them() {
    let (store, _guard) = new_store().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let pinned = place(&store, channel, actor, "image").await;
    let ink = place(&store, channel, actor, "stroke").await;
    store
        .set_canvas_object_lock(channel, pinned, actor, true, true)
        .await
        .unwrap();

    let first = clear(&store, channel, actor, ClearScope::default()).await;
    assert_eq!(
        (first.affected, first.spared_ids.clone()),
        (1, vec![pinned])
    );
    assert_eq!(alive(&store, channel).await, vec![pinned]);
    assert!(!alive(&store, channel).await.contains(&ink));

    let second = clear(&store, channel, actor, ClearScope::default()).await;
    assert_eq!((second.affected, second.spared_ids.len()), (1, 0));
    assert!(alive(&store, channel).await.is_empty());
}

#[tokio::test]
async fn a_scoped_clear_follows_the_same_rule() {
    let (store, _guard) = new_store().await;
    let (_, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let pinned = place(&store, channel, actor, "image").await;
    store
        .set_canvas_object_lock(channel, pinned, actor, true, true)
        .await
        .unwrap();
    let scope = ClearScope {
        kinds: vec!["image".to_owned()],
        author_id: None,
    };

    let only_locked_matches = clear(&store, channel, actor, scope).await;

    assert_eq!(only_locked_matches.affected, 1);
    assert!(alive(&store, channel).await.is_empty());
}

#[tokio::test]
async fn the_feed_names_the_spared_objects_so_a_replay_keeps_them() {
    let (store, _guard) = new_store().await;
    let (token, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let router = app(store.clone());
    let pinned = place(&store, channel, actor, "image").await;
    place(&store, channel, actor, "stroke").await;
    store
        .set_canvas_object_lock(channel, pinned, actor, true, true)
        .await
        .unwrap();
    clear(&store, channel, actor, ClearScope::default()).await;

    let page = store.list_canvas_ops(channel, 0, 50).await.unwrap();
    let CanvasOpBody::Clear { spared, .. } = &page.ops.last().unwrap().body else {
        panic!("the last op is the clear");
    };
    assert_eq!(spared, &vec![pinned]);

    let (status, body) = get_ops(&router, channel, &token, "after_seq=0").await;
    assert_eq!(status, StatusCode::OK);
    let last = body["ops"].as_array().unwrap().last().unwrap().clone();
    assert_eq!(last["kind"], json!("clear_scoped"), "{last}");
    assert_eq!(last["spared_ids"], json!([pinned.to_string()]));
}

#[tokio::test]
async fn a_replayed_clear_reports_the_same_count_and_an_undo_brings_back_what_it_took() {
    let (store, _guard) = new_store().await;
    let (token, actor) = register(&store, "root").await;
    let channel = general(&store).await;
    let router = app(store.clone());
    for _ in 0..3 {
        post_object(&router, channel, &token, stroke(&id())).await;
    }
    let op = id();
    let body = json!({ "id": op, "kind": "clear", "before_seq": 3 });
    let (_, first) = submit_op(&router, channel, &token, body.clone()).await;
    let (_, retry) = submit_op(&router, channel, &token, body).await;
    assert_eq!(first["op"]["affected"], json!(3));
    assert_eq!(retry["op"]["affected"], json!(3));
    assert_eq!(retry["fresh"], json!(false));
    let restore = json!({ "id": id(), "kind": "restore", "target_op": op });
    submit_op(&router, channel, &token, restore).await;
    assert_eq!(alive(&store, channel).await.len(), 3);
    let _ = actor;
}
