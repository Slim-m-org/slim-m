// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use serde_json::Value;
use uuid::Uuid;

use super::*;

/// The fixtures under `docs/modules/room-fixtures` are what a module author tests against.
fn fixture(name: &str) -> String {
    let path = format!(
        "{}/../../docs/modules/room-fixtures/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    std::fs::read_to_string(path).unwrap().trim_end().to_owned()
}

fn json(text: &str) -> RoomJson {
    RoomJson::new(RawValue::from_string(text.to_owned()).unwrap())
}

#[test]
fn the_input_fixture_is_exactly_what_the_host_sends() {
    let channel = ChannelId(Uuid::parse_str("01a1a929-1827-7e11-b45f-fa8008c5ac06").unwrap());
    let state =
        json(r#"{"board":"x........","next":"o","x":"5f2c7d0e9a1b3c4d","o":null,"winner":null}"#);
    let sent = input((channel, RoomKind::Voice), (1, Some(&state)), "4");
    assert_eq!(sent, fixture("room.input"));
}

#[test]
fn a_first_input_carries_no_state() {
    let channel = ChannelId(Uuid::now_v7());
    let sent: Value =
        serde_json::from_str(&input((channel, RoomKind::Channel), (0, None), "go")).unwrap();
    assert_eq!(sent["seq"], 0);
    assert_eq!(sent["state"], Value::Null);
    assert_eq!(sent["room"]["kind"], "channel");
}

#[test]
fn each_reply_fixture_is_accepted_as_what_it_says() {
    assert!(matches!(
        answer(&fixture("room.reply.state")),
        Ok(Answer::Next(Next { state, scene: None })) if state.get().contains("a8e1f6b2c9d04e7f")
    ));
    assert!(matches!(
        answer(&fixture("room.reply.scene")),
        Ok(Answer::Next(Next { scene: Some(scene), .. })) if scene.get().contains(r#""tap":"1""#)
    ));
    assert!(matches!(
        answer(&fixture("room.reply.reject")),
        Ok(Answer::Reject(reason)) if reason == "It is not your turn."
    ));
    assert!(matches!(
        answer(&fixture("room.reply.end")),
        Ok(Answer::End)
    ));
}

#[test]
fn a_reply_outside_the_contract_is_refused() {
    for reply in [
        "not json",
        r#"{"state":{}}"#,
        r#"{"$slim":"room/2","state":{}}"#,
        r#"{"$slim":"room/1"}"#,
        r#"{"$slim":"room/1","state":null}"#,
        r#"{"$slim":"room/1","state":{},"reject":"no"}"#,
        r#"{"$slim":"room/1","state":{},"end":true}"#,
        r#"{"$slim":"room/1","reject":"no","scene":{"$slim":"scene/1"}}"#,
        r#"{"$slim":"room/1","state":{},"scene":{"ops":[]}}"#,
        r#"{"$slim":"room/1","state":{},"scene":"scene/1"}"#,
        r#"{"$slim":"room/1","state":{},"scene":{"$slim":"scene/2"}}"#,
    ] {
        assert!(answer(reply).is_err(), "{reply}");
    }
}

#[test]
fn a_state_is_held_to_its_cap_and_a_reason_is_cut() {
    let padding = "x".repeat(MAX_STATE_BYTES - 2);
    let at_cap = format!(r#"{{"$slim":"room/1","state":"{padding}"}}"#);
    assert!(matches!(answer(&at_cap), Ok(Answer::Next(_))));
    let over = format!(r#"{{"$slim":"room/1","state":"{padding}x"}}"#);
    assert!(answer(&over).unwrap_err().contains("bytes"));
    let long = format!(r#"{{"$slim":"room/1","reject":"{}"}}"#, "r".repeat(500));
    assert!(matches!(
        answer(&long),
        Ok(Answer::Reject(reason)) if reason.chars().count() == MAX_REASON_CHARS
    ));
}

#[test]
fn a_scene_is_held_to_its_cap() {
    let scene = |pad: usize| {
        let head = r#"{"$slim":"scene/1","p":""#;
        format!(
            r#"{{"$slim":"room/1","state":1,"scene":{head}{}"}}}}"#,
            "s".repeat(pad - head.len() - 2)
        )
    };
    assert!(matches!(
        answer(&scene(MAX_SCENE_BYTES)),
        Ok(Answer::Next(_))
    ));
    assert!(
        answer(&scene(MAX_SCENE_BYTES + 1))
            .unwrap_err()
            .contains("scene is over")
    );
}
