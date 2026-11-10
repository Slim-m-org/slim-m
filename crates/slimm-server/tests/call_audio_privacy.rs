// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member whose presence is hidden is never named to the rest of the call by
//! a call-audio session: not on the REST read, not in the ask or answer
//! response, and not in the live `voice.call_audio` frame. They still see
//! themselves.
#![allow(dead_code)]

use std::collections::BTreeSet;
use std::time::Duration;

use axum::http::StatusCode;
use serde_json::{Value, json};

mod support;
use support::call_audio_world::{Person, Rig};
use support::ws::{Client, connect, read_frame, serve};

fn names(list: &Value) -> BTreeSet<String> {
    list.as_array()
        .expect("a list of user ids")
        .iter()
        .map(|id| id.as_str().expect("a user id").to_owned())
        .collect()
}

fn set(people: &[&Person]) -> BTreeSet<String> {
    people.iter().map(|p| p.id.to_string()).collect()
}

async fn hide(rig: &Rig, who: &Person) {
    let (status, body) = rig
        .call(
            who,
            "PATCH",
            "/presence",
            Some(json!({ "visibility": "hidden" })),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

async fn socket(rig: &Rig, addr: std::net::SocketAddr, who: &Person) -> Client {
    let ctx = rig
        .store
        .authenticate(&who.token)
        .await
        .unwrap()
        .expect("a live session");
    let (ticket, _) = rig.store.mint_ws_ticket(&ctx).await.unwrap();
    connect(addr, &ticket).await
}

/// The next `voice.call_audio` frame, skipping everything else the socket carries.
async fn next_session_frame(ws: &mut Client) -> Value {
    let wanted = async {
        loop {
            let frame = read_frame(ws).await;
            if frame["type"] == "voice.call_audio" {
                return frame;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), wanted)
        .await
        .expect("timed out waiting for a voice.call_audio frame")
}

#[tokio::test]
async fn the_rest_views_leave_a_hidden_member_out_but_show_them_themselves() {
    let rig = Rig::start("call-audio-hidden-rest", 3).await;
    let (asker, hidden, viewer) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    for person in [asker, hidden, viewer] {
        rig.join(person).await;
    }
    hide(&rig, hidden).await;

    let (status, body) = rig.ask(asker).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(names(&body["session"]["included"]), set(&[asker]));
    assert_eq!(
        names(&body["session"]["pending"]),
        set(&[viewer]),
        "the asker is not told the hidden member is in the call"
    );

    let seen_by_viewer = rig.status(viewer).await;
    assert_eq!(names(&seen_by_viewer["session"]["pending"]), set(&[viewer]));

    let seen_by_hidden = rig.status(hidden).await;
    assert_eq!(
        names(&seen_by_hidden["session"]["pending"]),
        set(&[hidden, viewer]),
        "the hidden member still sees themselves"
    );

    let (status, body) = rig.answer(viewer, true).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(names(&body["session"]["included"]), set(&[asker, viewer]));
    assert_eq!(
        names(&body["session"]["pending"]),
        BTreeSet::new(),
        "the answer does not name the hidden member who has yet to reply"
    );
}

#[tokio::test]
async fn the_live_frame_leaves_a_hidden_member_out_for_everyone_else() {
    let rig = Rig::start("call-audio-hidden-frame", 3).await;
    let (asker, hidden, viewer) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    let addr = serve(rig.state.clone()).await;
    let mut viewer_ws = socket(&rig, addr, viewer).await;
    let mut hidden_ws = socket(&rig, addr, hidden).await;
    for person in [asker, hidden, viewer] {
        rig.join(person).await;
    }
    hide(&rig, hidden).await;

    rig.ask(asker).await;
    let to_viewer = next_session_frame(&mut viewer_ws).await;
    assert_eq!(to_viewer["state"]["status"], "asking");
    assert_eq!(names(&to_viewer["state"]["included"]), set(&[asker]));
    assert_eq!(names(&to_viewer["state"]["pending"]), set(&[viewer]));

    let to_hidden = next_session_frame(&mut hidden_ws).await;
    assert_eq!(
        names(&to_hidden["state"]["pending"]),
        set(&[hidden, viewer]),
        "the hidden member's own frame names them"
    );

    rig.answer(viewer, true).await;
    let to_viewer = next_session_frame(&mut viewer_ws).await;
    assert_eq!(
        names(&to_viewer["state"]["included"]),
        set(&[asker, viewer])
    );
    assert_eq!(names(&to_viewer["state"]["pending"]), BTreeSet::new());
}
