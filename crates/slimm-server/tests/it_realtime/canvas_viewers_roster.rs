// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /presence/canvas-viewers` for boards that are not space channels, and what its `since` may reveal.

use serde_json::Value;
use slimm_server::ids::ChannelId;

use crate::canvas_viewers_live::{World, set_visibility, watch, world};
use crate::support::app::call_as;
use crate::support::ws::user_ticket;

async fn roster(w: &World, token: &str) -> Vec<Value> {
    let (status, body) = call_as(&w.router, "GET", "/presence/canvas-viewers", token, None).await;
    assert_eq!(status, 200, "{body}");
    body["channels"].as_array().unwrap().clone()
}

fn board_of(channels: &[Value], board: ChannelId) -> Option<&Value> {
    channels
        .iter()
        .find(|c| c["channel_id"] == board.to_string())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

#[tokio::test]
async fn a_dm_boards_viewers_are_listed_for_its_participants_only() {
    let mut w = world().await;
    let (eve_token, _, _) = user_ticket(&w.store, "eve").await;
    let dm = w.store.open_dm(w.alice_id, w.bob_id).await.unwrap().id;
    watch(&mut w.alice, &[dm]).await;
    slimm_server::flush_canvas_viewers(&w.hub);

    let seen = roster(&w, &w.bob_token).await;
    let viewers = board_of(&seen, dm).expect("bob is told who is on their DM board");
    assert_eq!(viewers["viewers"][0]["user_id"], w.alice_id.to_string());
    assert!(board_of(&roster(&w, &eve_token).await, dm).is_none());

    set_visibility(&w, &w.alice_token, "hidden").await;
    slimm_server::flush_canvas_viewers(&w.hub);
    assert!(board_of(&roster(&w, &w.bob_token).await, dm).is_none());
    assert!(board_of(&roster(&w, &w.alice_token).await, dm).is_some());
}

#[tokio::test]
async fn time_spent_hidden_never_shows_up_in_since() {
    let mut w = world().await;
    set_visibility(&w, &w.alice_token, "hidden").await;
    watch(&mut w.alice, &[w.board]).await;
    slimm_server::flush_canvas_viewers(&w.hub);
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;

    let went_online = now_ms();
    set_visibility(&w, &w.alice_token, "online").await;
    slimm_server::flush_canvas_viewers(&w.hub);

    let seen = roster(&w, &w.bob_token).await;
    let since = board_of(&seen, w.board).unwrap()["viewers"][0]["since"]
        .as_i64()
        .unwrap();
    assert!(since >= went_online, "{since} < {went_online}");
}
