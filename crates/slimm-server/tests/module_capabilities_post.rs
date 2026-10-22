// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `message.post` of decision 0023 through the real command route: a post is
//! made as the invoking user, only where they could post, and is rate limited.

use axum::body::Body;
use axum::http::Request;
use serde_json::json;
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::NewMessage;
use sqlx::{Connection, Executor};

mod support;
use support::module_world::{Install, message_id_in, post_request, world};
use support::wasm_fixtures::host_call_loop_wasm;

#[tokio::test]
async fn a_post_lands_as_the_invoking_user_and_names_the_module() {
    let w = world("slimm-modcap-post").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "hello from a module");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    let answer = w.answer_in("announcer", Some(channel.id)).await;
    assert!(answer.starts_with("{'message_id':'"), "{answer}");

    let id = message_id_in(&answer);
    let message = w
        .store
        .message_including_deleted(id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(message.author_id, Some(w.user.id));
    assert_eq!(message.channel_id, channel.id);
    assert_eq!(message.content, "hello from a module");
    let origin = w.store.module_origin(id).await.unwrap().unwrap();
    assert_eq!(origin.module_id, "announcer");
    assert_eq!(origin.module_name, "Scorekeeper");
    assert!(!origin.background, "a person ran it");
    let embeds = w.store.embeds_for_messages(&[id]).await.unwrap();
    assert!(
        embeds.is_empty(),
        "the marker is a field, not a module-named embed"
    );
}

#[tokio::test]
async fn the_marker_reaches_readers_on_the_wire() {
    let w = world("slimm-modcap-post-wire").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "hello from a module");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    let id = message_id_in(&w.answer_in("announcer", Some(channel.id)).await);
    let page = w.list_messages_json(channel.id).await;
    let posted = page
        .iter()
        .find(|m| m["id"] == json!(id.to_string()))
        .expect("the post is listed");
    assert_eq!(
        posted["via_module"],
        json!({"id": "announcer", "name": "Scorekeeper", "background": false})
    );
    assert!(posted["embeds"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn a_post_hiding_text_is_refused_but_line_breaks_are_not() {
    let w = world("slimm-modcap-post-hidden").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let bidi = post_request(&channel.id.to_string(), "safe \u{202E}gnp.exe");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&bidi, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    assert_eq!(
        w.answer_in("announcer", Some(channel.id)).await,
        "{'error':'content contains hidden characters','ok':false}"
    );
    let lines = post_request(&channel.id.to_string(), "one\ntwo");
    w.install(Install {
        id: "liner",
        wasm: host_call_loop_wasm(&lines, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    let answer = w.answer_in("liner", Some(channel.id)).await;
    assert!(answer.starts_with("{'message_id':'"), "{answer}");
}

#[tokio::test]
async fn a_module_cannot_post_where_the_invoking_user_cannot() {
    let w = world("slimm-modcap-post-denied").await;
    let hidden = w.store.create_channel("staff", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            hidden.id,
            w.everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    let read_only = w.store.create_channel("news", "text").await.unwrap();
    w.store
        .set_role_overwrite(
            read_only.id,
            w.everyone,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    let denied = "{'error':'not permitted to post in that channel','ok':false}";
    for (module, channel) in [("into-staff", hidden.id), ("into-news", read_only.id)] {
        w.install(Install {
            id: module,
            wasm: host_call_loop_wasm(&post_request(&channel.to_string(), "sneaky"), 1),
            declared: &["message.post"],
            approved_host: &["message.post"],
        })
        .await;
        assert_eq!(w.answer_in(module, Some(channel)).await, denied);
    }
    let nowhere = "00000000-0000-0000-0000-000000000000";
    w.install(Install {
        id: "into-nowhere",
        wasm: host_call_loop_wasm(&post_request(nowhere, "x"), 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    let nowhere_id = ChannelId(nowhere.parse().unwrap());
    assert_eq!(w.answer_in("into-nowhere", Some(nowhere_id)).await, denied);
}

#[tokio::test]
async fn posting_is_rate_limited_within_a_run_and_across_runs() {
    let w = world("slimm-modcap-post-rate").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "spam");
    w.install(Install {
        id: "spammer",
        wasm: host_call_loop_wasm(&post, 5),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    assert_eq!(
        w.answer_in("spammer", Some(channel.id)).await,
        "{'error':'message.post budget for this run is exhausted','ok':false}"
    );

    // Three landed in that run; the per-user burst of five is nearly spent.
    w.install(Install {
        id: "spammer",
        wasm: host_call_loop_wasm(&post, 3),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    assert_eq!(
        w.answer_in("spammer", Some(channel.id)).await,
        "{'error':'message.post rate limit reached','ok':false}"
    );
}

#[tokio::test]
async fn a_module_cannot_post_into_a_channel_other_than_the_one_it_ran_in() {
    let w = world("slimm-modcap-post-elsewhere").await;
    let here = w.store.create_channel("here", "text").await.unwrap();
    let elsewhere = w.store.create_channel("elsewhere", "text").await.unwrap();
    let post = post_request(&elsewhere.id.to_string(), "@everyone look");
    w.install(Install {
        id: "redirector",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    assert_eq!(
        w.answer_in("redirector", Some(here.id)).await,
        "{'error':'message.post can only post in the channel the command was run from','ok':false}"
    );
    let landed = w.store.list_messages(elsewhere.id, None, 10).await.unwrap();
    assert!(landed.is_empty());
}

#[tokio::test]
async fn a_run_that_names_no_channel_is_offered_no_poster() {
    let w = world("slimm-modcap-post-no-channel").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "hi");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["kv.store", "message.post"],
        approved_host: &["kv.store", "message.post"],
    })
    .await;
    assert_eq!(
        w.answer("announcer").await,
        "{'error':'message.post needs a channel','ok':false}"
    );
}

#[tokio::test]
async fn running_a_code_block_cannot_post() {
    let w = world("slimm-modcap-post-code-block").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "posted by a code block");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["kv.store", "message.post"],
        approved_host: &["kv.store", "message.post"],
    })
    .await;
    let author = w.store.create_user("omar", "Omar").await.unwrap();
    let block = w
        .store
        .send_message(NewMessage::plain(
            channel.id,
            author.id,
            slimm_server::ids::MessageId::generate(),
            "```js\nanything\n```",
        ))
        .await
        .unwrap();
    let request = Request::builder()
        .method("POST")
        .uri(format!("/messages/{}/blocks/0/run", block.message.id))
        .header("authorization", format!("Bearer {}", w.token))
        .header("content-type", "application/json")
        .body(Body::from(
            json!({ "module_id": "announcer", "command": "run", "input": "x" }).to_string(),
        ))
        .unwrap();
    let body = w.send(request).await;
    let output = body["output"].as_str().unwrap_or_default();
    assert!(output.contains("message.post needs a channel"), "{body}");
    let landed = w.store.list_messages(channel.id, None, 10).await.unwrap();
    assert_eq!(landed.len(), 1, "only the block's own message exists");
}

#[tokio::test]
async fn a_failure_while_attributing_leaves_no_unattributed_message() {
    let w = world("slimm-modcap-post-atomic").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "half done");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    // Break the step that runs after the message insert, inside the same write.
    let mut other = sqlx::SqliteConnection::connect(&format!("sqlite://{}", w.db_path))
        .await
        .unwrap();
    other
        .execute("DROP TABLE module_message_origins")
        .await
        .unwrap();

    assert_eq!(
        w.answer_in("announcer", Some(channel.id)).await,
        "{'error':'message.post is unavailable','ok':false}"
    );
    let landed = w.store.list_messages(channel.id, None, 10).await.unwrap();
    assert!(landed.is_empty(), "the message rolled back with its stamp");
}

#[tokio::test]
async fn an_approved_post_run_without_a_channel_says_it_needs_one() {
    let w = world("slimm-modcap-post-nochannel").await;
    let channel = w.store.create_channel("general", "text").await.unwrap();
    let post = post_request(&channel.id.to_string(), "hello");
    w.install(Install {
        id: "announcer",
        wasm: host_call_loop_wasm(&post, 1),
        declared: &["message.post"],
        approved_host: &["message.post"],
    })
    .await;
    let answer = w.answer_in("announcer", None).await;
    assert!(answer.contains("message.post needs a channel"), "{answer}");
    assert!(!answer.contains("may not do"), "{answer}");
}
