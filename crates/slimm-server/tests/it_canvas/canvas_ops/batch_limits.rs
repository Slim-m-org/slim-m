// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What an HTTP-only agent reads from a canvas refusal: which permission was missing, and
//! how long a remove may be inside a batch.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::canvas_ops::batch::{place, submit_batch};
use crate::canvas_ops::fixtures::{
    general, id, member, move_op, new_store, post_object, register, remove, stroke, submit_op,
};

fn names(body: &Value) -> Value {
    body["missing"].clone()
}

#[tokio::test]
async fn refusing_a_move_or_remove_of_anothers_object_names_manage_canvas() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let theirs = place(&app, channel, &root, stroke(&id())).await;

    let (status, body) = submit_op(&app, channel, &bob, remove(&id(), &[&theirs])).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["error"], "insufficient permissions");
    assert_eq!(names(&body), json!(["manage_canvas"]), "{body}");
    assert!(body.get("missing_permissions").is_none(), "{body}");

    let (status, body) = submit_op(
        &app,
        channel,
        &bob,
        move_op(&id(), &theirs, (1.0, 1.0, 1.0, 1.0)),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(names(&body), json!(["manage_canvas"]), "{body}");
}

#[tokio::test]
async fn a_batch_refusal_carries_the_missing_permission_beside_the_item() {
    let (store, _guard) = new_store().await;
    let (root, _) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let (bob, _) = member(&store, "bob").await;
    let mine = place(&app, channel, &bob, stroke(&id())).await;
    let theirs = place(&app, channel, &root, stroke(&id())).await;

    let (status, body) = submit_batch(
        &app,
        channel,
        &bob,
        vec![
            move_op(&id(), &mine, (1.0, 1.0, 1.0, 1.0)),
            move_op(&id(), &theirs, (1.0, 1.0, 1.0, 1.0)),
        ],
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(body["item_index"], 1);
    assert_eq!(body["item_code"], "forbidden");
    assert_eq!(names(&body), json!(["manage_canvas"]), "{body}");
}

#[tokio::test]
async fn a_member_without_use_canvas_is_told_so_but_a_hidden_channel_names_nothing() {
    let (store, _guard) = new_store().await;
    register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let (bob, bob_id) = member(&store, "bob").await;
    store
        .set_member_overwrite(channel, bob_id, Permissions::NONE, Permissions::USE_CANVAS)
        .await
        .unwrap();
    let (status, body) = post_object(&app, channel, &bob, stroke(&id())).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(names(&body), json!(["use_canvas"]), "{body}");

    store
        .set_member_overwrite(
            channel,
            bob_id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let (status, body) = post_object(&app, channel, &bob, stroke(&id())).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert!(body.get("missing").is_none(), "{body}");
}

#[tokio::test]
async fn a_remove_op_holds_64_ids_and_a_batch_chains_removes_up_to_its_own_cap() {
    let (store, _guard) = new_store().await;
    let (root, root_id) = register(&store, "root").await;
    let channel = general(&store).await;
    let app = crate::support::app::router(store.clone());
    let mut ids = Vec::new();
    for _ in 0..66 {
        ids.push(
            crate::canvas_ops::fixtures::place(&store, channel, root_id, 0)
                .await
                .to_string(),
        );
    }
    let all: Vec<&str> = ids.iter().map(String::as_str).collect();

    let (status, body) = submit_batch(&app, channel, &root, vec![remove(&id(), &all)]).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    let message = body["error"].as_str().unwrap();
    assert!(
        message.contains("64") && message.contains("200 ops"),
        "{message}"
    );

    let (status, body) = submit_batch(
        &app,
        channel,
        &root,
        vec![remove(&id(), &all[..64]), remove(&id(), &all[64..])],
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
}
