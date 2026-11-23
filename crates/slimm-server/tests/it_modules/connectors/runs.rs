// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A connector's manifest command and panel (add-on API 7): the host forwards a
//! member's run to the connector's own socket and waits, bounded, for the same
//! answer a WASM module gives. The connector sees the opaque caller id, only
//! the channels it may view, and nothing at all while it is off or gone.

use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};

use super::harness::ID;
use super::runs_world::{Live, SEND, VIEW, live, live_waiting, next_run};
use crate::support;

const SCENE: &str = r#"{"$slim":"scene/1","width":4,"height":4,"ops":[]}"#;

fn command_body(channel: &str) -> Value {
    json!({"input": "hi", "channel_id": channel})
}

/// The member's run and the connector's side of it, played at once.
async fn run_answered(l: &Live, body: Value, answer: Value) -> ((StatusCode, Value), Value) {
    let mut ws = l.connect().await;
    let connector = async {
        let frame = next_run(&mut ws)
            .await
            .expect("the connector is sent the run");
        let run_id = frame["run_id"].as_str().unwrap().to_owned();
        assert_eq!(
            l.answer(&l.token, &run_id, answer).await,
            StatusCode::NO_CONTENT
        );
        frame
    };
    let (ran, frame) = tokio::join!(l.run(body), connector);
    (ran, frame)
}

#[tokio::test]
async fn a_members_command_reaches_the_connector_and_its_answer_comes_back() {
    let l = live("slimm-conn-run", SEND).await;
    let general = l.w.general().await;
    let ((status, ran), frame) = run_answered(
        &l,
        command_body(&general),
        json!({"ok": true, "output": "two servers up"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{ran}");
    assert_eq!(ran, json!({"ok": true, "output": "two servers up"}));

    assert_eq!(frame["module_id"], ID);
    assert_eq!(frame["deadline_ms"], 6000);
    let request = &frame["request"];
    assert_eq!(request["command"], "servers");
    assert_eq!(request["input"], "hi");
    assert_eq!(request["context"]["channel_id"], general.as_str());
    assert_eq!(request["caller"]["name"], "member");
    let caller = request["caller"]["id"].as_str().unwrap();
    assert_eq!(caller.len(), 64, "the opaque per-module caller id");
    let text = frame.to_string();
    assert!(
        !text.contains(&l.member.id.to_string()),
        "the member's real id never reaches the connector: {text}"
    );
    assert!(
        request
            .get("settings")
            .is_none_or(|s| s.get("api_key").is_none()),
        "no secret rides the run"
    );
}

#[tokio::test]
async fn the_panel_and_slash_command_are_listed_and_the_panel_paints_the_scene() {
    let l = live("slimm-conn-panel", VIEW).await;
    let (status, panels) = support::app::call(
        &l.w.router,
        "GET",
        "/modules/panels",
        Some(&l.member.token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(panels[0]["module_id"], ID);
    assert_eq!(panels[0]["command"], "servers");
    assert_eq!(panels[0]["name"], "Servers");
    let (_, slash) = support::app::call(
        &l.w.router,
        "GET",
        "/modules/slash-commands",
        Some(&l.member.token),
        None,
    )
    .await;
    assert_eq!(slash[0]["module_id"], ID, "{slash}");

    let ((_, ran), _) = run_answered(
        &l,
        json!({"input": ""}),
        json!({"ok": true, "output": SCENE}),
    )
    .await;
    assert_eq!(ran, json!({"ok": true, "output": SCENE}));
}

#[tokio::test]
async fn an_offline_connector_answers_unavailable_without_waiting_for_it() {
    let l = live_waiting("slimm-conn-offline", VIEW, Some(Duration::from_secs(600))).await;
    let (status, ran) = l.run(json!({"input": ""})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(ran, json!({"ok": false, "error": "Jellyfin is offline"}));
}

#[tokio::test]
async fn a_silent_connector_times_out() {
    let l = live_waiting("slimm-conn-slow", VIEW, Some(Duration::from_millis(100))).await;
    let _ws = l.connect().await;
    let (_, ran) = l.run(json!({"input": "a"})).await;
    assert_eq!(
        ran,
        json!({"ok": false, "error": "Jellyfin did not answer in time"})
    );
}

#[tokio::test]
async fn a_member_cannot_stack_runs_on_a_connector_that_has_not_answered() {
    let l = live("slimm-conn-stack", VIEW).await;
    let mut ws = l.connect().await;
    let held = async { tokio::join!(l.run(json!({"input": "a"})), l.run(json!({"input": "b"}))) };
    let meanwhile = async {
        let first = next_run(&mut ws).await.expect("the first run is sent");
        let second = next_run(&mut ws).await.expect("the second run is sent");
        let (_, turned) = l.run(json!({"input": "c"})).await;
        for frame in [first, second] {
            let run_id = frame["run_id"].as_str().unwrap();
            let answer = json!({"ok": true, "output": "done"});
            assert_eq!(
                l.answer(&l.token, run_id, answer).await,
                StatusCode::NO_CONTENT
            );
        }
        turned
    };
    let ((first, second), turned) = tokio::join!(held, meanwhile);
    assert_eq!(turned["error"], "Jellyfin is busy; try again in a moment");
    for (_, ran) in [first, second] {
        assert_eq!(ran, json!({"ok": true, "output": "done"}));
    }
}

#[tokio::test]
async fn a_disabled_or_uninstalled_connector_is_sent_nothing() {
    let l = live("slimm-conn-off", VIEW).await;
    let mut ws = l.connect().await;
    l.w.set_enabled(false).await;
    let (status, _) = l.run(json!({"input": ""})).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert!(next_run(&mut ws).await.is_none());

    let (status, body) =
        l.w.as_owner("DELETE", &format!("/space/dock/modules/{ID}/install"), None)
            .await;
    assert!(status.is_success(), "{body}");
    let (status, _) = l.run(json!({"input": ""})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn the_connector_sees_only_channels_it_may_view_and_posts_only_where_it_may() {
    let l = live("slimm-conn-confined", 0).await;
    let general = l.w.general().await;
    let ((_, ran), frame) = run_answered(
        &l,
        json!({"input": "", "channel_id": general, "post_output": true}),
        json!({"ok": true, "output": "posted"}),
    )
    .await;
    assert!(
        frame["request"].get("context").is_none(),
        "a channel it cannot view is left out: {frame}"
    );
    assert_eq!(
        ran,
        json!({"ok": false, "error": "this connector may not post in this channel"})
    );
}

#[tokio::test]
async fn only_the_connector_answers_its_runs_and_a_malformed_answer_fails_the_run() {
    let l = live("slimm-conn-answer", VIEW).await;
    let mut ws = l.connect().await;
    let connector = async {
        let frame = next_run(&mut ws).await.unwrap();
        let run_id = frame["run_id"].as_str().unwrap().to_owned();
        let member = l.member.token.clone();
        assert_eq!(
            l.answer(&member, &run_id, json!({"ok": true, "output": "x"}))
                .await,
            StatusCode::FORBIDDEN
        );
        let stranger = uuid::Uuid::now_v7().to_string();
        assert_eq!(
            l.answer(&l.token, &stranger, json!({"ok": true, "output": "x"}))
                .await,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            l.answer(&l.token, &run_id, json!({"ok": true})).await,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            l.answer(&l.token, &run_id, json!({"ok": true, "output": "late"}))
                .await,
            StatusCode::NOT_FOUND,
            "a run is answered once"
        );
    };
    let ((_, ran), ()) = tokio::join!(l.run(json!({"input": ""})), connector);
    assert_eq!(
        ran,
        json!({"ok": false, "error": "module returned a malformed response"})
    );
}

#[tokio::test]
async fn an_answer_past_the_size_cap_is_refused() {
    let l = live("slimm-conn-cap", VIEW).await;
    let mut ws = l.connect().await;
    let connector = async {
        let frame = next_run(&mut ws).await.unwrap();
        let run_id = frame["run_id"].as_str().unwrap().to_owned();
        let huge = "x".repeat(1024 * 1024);
        assert_eq!(
            l.answer(&l.token, &run_id, json!({"ok": true, "output": huge}))
                .await,
            StatusCode::PAYLOAD_TOO_LARGE
        );
        assert_eq!(
            l.answer(&l.token, &run_id, json!({"ok": true, "output": "small"}))
                .await,
            StatusCode::NO_CONTENT
        );
    };
    let ((_, ran), ()) = tokio::join!(l.run(json!({"input": ""})), connector);
    assert_eq!(ran, json!({"ok": true, "output": "small"}));
}

/// Item 6 of the 2026-11-23 review: a connector's posted output reaches `@everyone` only when
/// the member who ran the command could have written it too, so a member cannot borrow the
/// connector's approval, nor the connector the member's.
#[tokio::test]
async fn posted_output_pings_everyone_only_when_member_and_connector_both_may() {
    use slimm_server::ids::MessageId;
    use slimm_server::permissions::Permissions;
    let mention = Permissions::MENTION_EVERYONE.bits();
    let mut doc = super::runs_world::with_surfaces();
    doc["connector"]["permissions"] = json!(["view_channel", "send_messages", "mention_everyone"]);
    let w = super::harness::world("slimm-conn-mention", &[]).await;
    *w.served.lock().unwrap() = doc;
    let token = w.installed(SEND | mention).await;
    sqlx::query("UPDATE roles SET permissions = permissions & ~? WHERE is_everyone = 1")
        .bind(mention)
        .execute(&w.pool)
        .await
        .unwrap();
    let member = support::app::register_account(&w.store, "member").await;
    let bystander = support::app::register_account(&w.store, "bystander").await;
    let role = w
        .store
        .create_role("players", Permissions::NONE, false)
        .await
        .unwrap();
    w.store.assign_role(member.id, role).await.unwrap();
    w.store
        .grant_module_permission(role, ID, "use")
        .await
        .unwrap();
    let addr = support::ws::serve(w.state.clone()).await;
    let l = Live {
        w,
        addr,
        token,
        member,
    };
    let general = l.w.general().await;
    let body = json!({"input": "", "channel_id": general, "post_output": true});
    let ((_, ran), _) = run_answered(
        &l,
        body.clone(),
        json!({"ok": true, "output": "@everyone look"}),
    )
    .await;
    let id = MessageId(ran["message_id"].as_str().unwrap().parse().unwrap());
    let pinged = l.w.store.mentioned_user_ids(id).await.unwrap();
    assert!(
        !pinged.contains(&bystander.id),
        "the member lacks MENTION_EVERYONE: {pinged:?}"
    );
    let mut ws = l.connect().await;
    let owner_run = async {
        support::app::call(
            &l.w.router,
            "POST",
            &format!("/modules/{ID}/commands/servers"),
            Some(&l.w.owner.token),
            Some(body),
        )
        .await
    };
    let connector = async {
        let frame = next_run(&mut ws)
            .await
            .expect("the run reaches the connector");
        let run_id = frame["run_id"].as_str().unwrap().to_owned();
        l.answer(
            &l.token,
            &run_id,
            json!({"ok": true, "output": "@everyone look"}),
        )
        .await
    };
    let ((_, ran), _) = tokio::join!(owner_run, connector);
    let id = MessageId(ran["message_id"].as_str().unwrap().parse().unwrap());
    let pinged = l.w.store.mentioned_user_ids(id).await.unwrap();
    assert!(pinged.contains(&bystander.id), "both hold it: {pinged:?}");
}
