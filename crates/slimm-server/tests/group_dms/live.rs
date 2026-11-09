// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a group's participants, and nobody else, hear live over `/ws`.

use std::net::SocketAddr;
use std::time::Duration;

use serde_json::{Value, json};
use slimm_server::hub::Event;

use crate::rig::*;
use crate::support::ws::{Client, connect, read_frame, serve};

async fn socket(h: &Harness, addr: SocketAddr, who: &Person) -> Client {
    let ctx = h
        .store
        .authenticate(&who.token)
        .await
        .unwrap()
        .expect("a live session");
    let (ticket, _) = h.store.mint_ws_ticket(&ctx).await.unwrap();
    connect(addr, &ticket).await
}

/// The channel of the next `dm.changed` the socket hears.
async fn next_announcement(ws: &mut Client) -> String {
    let wanted = async {
        loop {
            let frame: Value = read_frame(ws).await;
            if frame["type"] == "dm.changed" {
                return frame["channel_id"].as_str().unwrap().to_owned();
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), wanted)
        .await
        .expect("timed out waiting for dm.changed")
}

/// Every `dm.changed` the socket hears before the sentinel that every connection receives.
async fn heard_until_sentinel(ws: &mut Client) -> Vec<String> {
    let mut heard = Vec::new();
    let drain = async {
        loop {
            let frame: Value = read_frame(ws).await;
            match frame["type"].as_str() {
                Some("dm.changed") => heard.push(frame["channel_id"].as_str().unwrap().to_owned()),
                Some("space.settings_changed") => return,
                _ => {}
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), drain)
        .await
        .expect("the sentinel frame never arrived");
    heard
}

/// Each socket hears the next announcement for `channel`; waiting keeps a later action from outrunning it.
async fn all_hear(sockets: &mut [&mut Client], channel: &str) {
    for ws in sockets {
        assert_eq!(next_announcement(ws).await, channel);
    }
}

#[tokio::test]
async fn a_group_roster_change_is_announced_to_participants_only() {
    let h = harness().await;
    let admin = person(&h, "admin").await;
    let (a, b, c, outsider) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
        person(&h, "dave").await,
    );
    let addr = serve(h.state.clone()).await;
    let mut alice = socket(&h, addr, &a).await;
    let mut bob = socket(&h, addr, &b).await;
    let mut carol = socket(&h, addr, &c).await;
    let mut dave = socket(&h, addr, &outsider).await;
    let mut root = socket(&h, addr, &admin).await;

    let channel = group_of(&h, &a, &[&b, &c]).await;
    all_hear(&mut [&mut alice, &mut bob, &mut carol], &channel).await;

    let uri = format!("/dms/groups/{channel}");
    call(&h, "PATCH", &uri, &b, Some(json!({ "name": "trip" }))).await;
    all_hear(&mut [&mut alice, &mut bob, &mut carol], &channel).await;

    call(&h, "POST", &format!("{uri}/leave"), &c, None).await;
    all_hear(&mut [&mut alice, &mut bob], &channel).await;

    h.hub.publish(Event::SpaceSettingsChanged);
    for (who, ws) in [
        ("alice", &mut alice),
        ("bob", &mut bob),
        ("carol, who has left", &mut carol),
        ("an outsider", &mut dave),
        ("an administrator", &mut root),
    ] {
        let extra = heard_until_sentinel(ws).await;
        assert!(extra.is_empty(), "{who} heard {extra:?}");
    }
}
