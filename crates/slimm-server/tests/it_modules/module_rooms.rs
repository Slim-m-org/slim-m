// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared room state (decision 0131) with the noughts proof module: two
//! players and a late joiner play one game in a call through the real router
//! and socket, and everyone sees the same board in the same order.

use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::permissions::Permissions;

use crate::support;
use support::room_world::{RoomWorld, noughts_wasm, room_world};
use support::ws::{Client, assert_no_frame_of_type, connect, read_frame_of_type, serve};

async fn noughts(name: &str) -> RoomWorld {
    room_world(name, "noughts", noughts_wasm()).await
}

/// The next room frame, checked to be this game's.
async fn next_board(ws: &mut Client) -> Value {
    let frame = read_frame_of_type(ws, "module.room").await;
    assert_eq!(frame["module_id"], "noughts");
    frame
}

#[tokio::test]
async fn two_players_and_a_late_joiner_share_one_game() {
    let r = noughts("slimm-rooms-game").await;
    let addr = serve(r.w.state.clone()).await;
    let (ava, ben, cy) = (
        r.player("ava").await,
        r.player("ben").await,
        r.player("cy").await,
    );
    r.join_call(&ava);
    r.join_call(&ben);
    let mut ava_ws = connect(addr, &ava.ticket).await;
    let mut ben_ws = connect(addr, &ben.ticket).await;
    assert_eq!(r.room(&ava).await, Value::Null);

    let boards = [(&ava, "0", "x........"), (&ben, "4", "x...o....")];
    for (seq, (who, cell, board)) in boards.into_iter().enumerate() {
        let (status, answer) = r.input(who, cell).await;
        assert_eq!(status, StatusCode::OK, "{answer}");
        assert_eq!(answer["applied"], true, "{answer}");
        for ws in [&mut ava_ws, &mut ben_ws] {
            let frame = next_board(ws).await;
            assert_eq!(frame["seq"], seq as u64 + 1);
            assert_eq!(frame["state"]["board"], board);
        }
    }

    r.join_call(&cy);
    let caught_up = r.room(&cy).await;
    assert_eq!(caught_up["seq"], 2);
    assert_eq!(caught_up["state"]["board"], "x...o....");
    let mut cy_ws = connect(addr, &cy.ticket).await;

    for (who, cell) in [(&ava, "1"), (&ben, "8"), (&ava, "2")] {
        let (_, answer) = r.input(who, cell).await;
        assert_eq!(answer["applied"], true, "{answer}");
    }
    for ws in [&mut ava_ws, &mut ben_ws, &mut cy_ws] {
        let mut last = Value::Null;
        for seq in 3..=5 {
            last = next_board(ws).await;
            assert_eq!(last["seq"], seq);
        }
        assert_eq!(last["state"]["board"], "xxx.o...o");
        assert_eq!(last["state"]["winner"], "x");
    }
    let (_, watcher) = r.input(&cy, "5").await;
    assert_eq!(watcher["applied"], false);
    assert_eq!(watcher["seq"], 5);
}

#[tokio::test]
async fn inputs_sent_together_are_applied_one_after_the_other() {
    let r = noughts("slimm-rooms-order").await;
    let (ava, ben) = (r.player("ava").await, r.player("ben").await);
    r.join_call(&ava);
    r.join_call(&ben);
    let (a, b) = tokio::join!(r.input(&ava, "0"), r.input(&ben, "4"));
    assert_eq!(a.1["applied"], true, "{}", a.1);
    assert_eq!(b.1["applied"], true, "{}", b.1);
    let mut seqs = [a.1["seq"].as_u64(), b.1["seq"].as_u64()];
    seqs.sort_unstable();
    assert_eq!(seqs, [Some(1), Some(2)]);
    let room = r.room(&ava).await;
    assert_eq!(room["seq"], 2);
    let board = room["state"]["board"].as_str().unwrap().to_owned();
    assert_eq!(
        board.matches('x').count() + board.matches('o').count(),
        2,
        "{board}"
    );
}

#[tokio::test]
async fn a_refused_move_changes_nothing_and_reaches_only_the_sender() {
    let r = noughts("slimm-rooms-refused").await;
    let addr = serve(r.w.state.clone()).await;
    let (ava, ben) = (r.player("ava").await, r.player("ben").await);
    r.join_call(&ava);
    r.join_call(&ben);
    r.input(&ava, "0").await;
    let mut ben_ws = connect(addr, &ben.ticket).await;
    let (status, answer) = r.input(&ava, "1").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(answer["applied"], false);
    assert_eq!(answer["reason"], "not your turn");
    assert_eq!(answer["seq"], 1);
    assert_eq!(answer["state"]["board"], "x........");
    assert_no_frame_of_type(&mut ben_ws, "module.room").await;
}

#[tokio::test]
async fn only_people_in_the_call_send_input_and_only_viewers_read_it() {
    let r = noughts("slimm-rooms-access").await;
    let addr = serve(r.w.state.clone()).await;
    let (ava, outsider, hidden) = (
        r.player("ava").await,
        r.player("odd").await,
        r.player("hal").await,
    );
    r.join_call(&ava);
    let (status, _) = r.input(&outsider, "0").await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    r.w.store
        .set_member_overwrite(
            r.call,
            hidden.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
    r.join_call(&hidden);
    let mut hidden_ws = connect(addr, &hidden.ticket).await;
    let mut outsider_ws = connect(addr, &outsider.ticket).await;
    r.input(&ava, "0").await;
    read_frame_of_type(&mut outsider_ws, "module.room").await;
    assert_no_frame_of_type(&mut hidden_ws, "module.room").await;
    assert_eq!(r.rooms_in(&hidden, r.call).await.0, StatusCode::FORBIDDEN);
    assert_eq!(r.input(&hidden, "4").await.0, StatusCode::FORBIDDEN);
    assert_eq!(r.room(&outsider).await["seq"], 1);
}

#[tokio::test]
async fn the_board_goes_when_the_call_ends() {
    let r = noughts("slimm-rooms-call-end").await;
    let addr = serve(r.w.state.clone()).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    r.input(&ava, "0").await;
    let mut ws = connect(addr, &ava.ticket).await;
    assert_eq!(r.finish_call().await, StatusCode::NO_CONTENT);
    let frame = next_board(&mut ws).await;
    assert_eq!(frame["state"], Value::Null);
    assert_eq!(frame["ended"], "call_ended");
    assert_eq!(r.room(&ava).await, Value::Null);
}

#[tokio::test]
async fn the_module_can_end_its_own_room() {
    let r = noughts("slimm-rooms-module-end").await;
    let addr = serve(r.w.state.clone()).await;
    let ava = r.player("ava").await;
    r.join_call(&ava);
    r.input(&ava, "0").await;
    let mut ws = connect(addr, &ava.ticket).await;
    let (_, answer) = r.input(&ava, "end").await;
    assert_eq!(answer["applied"], true);
    assert_eq!(answer["state"], Value::Null);
    assert_eq!(next_board(&mut ws).await["ended"], "ended");
    assert_eq!(r.room(&ava).await, Value::Null);
    let (_, fresh) = r.input(&ava, "4").await;
    assert_eq!(fresh["seq"], 1);
}

#[tokio::test]
async fn a_text_channel_room_needs_send_messages() {
    let r = noughts("slimm-rooms-text").await;
    let ava = r.player("ava").await;
    let text = r.w.store.create_channel("games", "text").await.unwrap().id;
    let (status, answer) = r.input_in(&ava, text, "0").await;
    assert_eq!(status, StatusCode::OK, "{answer}");
    assert_eq!(answer["state"]["board"], "x........");

    r.w.store
        .set_member_overwrite(text, ava.id, Permissions::NONE, Permissions::SEND_MESSAGES)
        .await
        .unwrap();
    assert_eq!(r.input_in(&ava, text, "4").await.0, StatusCode::FORBIDDEN);
    assert_eq!(r.rooms_in(&ava, text).await.0, StatusCode::OK);
}
