// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module hearing a voice call (decision 0105), end to end through the
//! routes, a real WebSocket to a fake listener, and signed LiveKit webhooks.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::call_audio::runtime;

mod support;
use support::call_audio_world::{KEEPS, MODULE, PURPOSE, Rig, now_ms};
use support::room_service::RoomService;
use support::wait::wait_for;

async fn wait_frames(rig: &Rig, kind: &'static str, count: usize) {
    wait_for("the listener to receive the frames", || {
        let have = rig.listener.of_type(kind).len();
        async move { (have >= count).then_some(()) }
    })
    .await;
}

#[tokio::test]
async fn a_request_waits_for_everyone_and_starts_when_all_have_said_yes() {
    let rig = Rig::start("call-audio-unanimous", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;

    let (status, body) = rig.ask(a).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["session"]["status"], "asking");
    assert_eq!(body["session"]["purpose"], PURPOSE);
    assert_eq!(body["session"]["keeps"], KEEPS);
    assert_eq!(body["session"]["included"], json!([a.id.to_string()]));
    assert_eq!(body["session"]["pending"], json!([b.id.to_string()]));
    assert!(
        rig.listener.of_type("start").is_empty(),
        "nothing is heard while it waits"
    );

    let (status, body) = rig.answer(b, true).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    rig.wait_session(Some("on")).await;
    wait_frames(&rig, "start", 1).await;
    let start = &rig.listener.of_type("start")[0];
    assert_eq!(start["livekit_url"], "ws://lan-livekit:7880");
    assert!(start["token"].as_str().unwrap().split('.').count() == 3);
    let mut want = vec![a.id.to_string(), b.id.to_string()];
    want.sort();
    assert_eq!(rig.listener.include_sets(), vec![want]);
}

#[tokio::test]
async fn the_status_route_offers_the_module_only_to_someone_who_may_start_it() {
    let rig = Rig::start("call-audio-startable", 1).await;
    let body = rig.status(&rig.people[0]).await;
    assert_eq!(body["session"], json!(null));
    assert_eq!(body["startable"][0]["module_id"], MODULE);
    assert_eq!(body["startable"][0]["purpose"], PURPOSE);

    rig.arm(&[]).await;
    assert_eq!(rig.status(&rig.people[0]).await["startable"], json!([]));
}

#[tokio::test]
async fn one_no_ends_the_ask_without_naming_anyone_and_a_wait_follows() {
    let rig = Rig::start("call-audio-decline", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;

    let (status, body) = rig.answer(b, false).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["session"], json!(null));
    rig.wait_session(None).await;
    assert!(rig.listener.of_type("start").is_empty());

    let (status, _) = rig.ask(a).await;
    assert_eq!(
        status,
        StatusCode::TOO_MANY_REQUESTS,
        "the sixty second wait"
    );
}

#[tokio::test]
async fn an_ask_nobody_finishes_lapses_and_starts_the_same_wait() {
    let rig = Rig::start("call-audio-lapse", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;

    for outcome in rig.state.call_audio.tick(now_ms() + 61_000) {
        runtime::apply(&rig.state, outcome).await;
    }
    rig.wait_session(None).await;
    assert!(rig.listener.of_type("start").is_empty());
    assert_eq!(rig.ask(a).await.0, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn a_joiner_is_left_out_until_they_say_yes() {
    let rig = Rig::start("call-audio-joiner-yes", 3).await;
    let (a, b, c) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    wait_frames(&rig, "start", 1).await;

    rig.join(c).await;
    let view = rig.status(c).await;
    assert_eq!(view["session"]["pending"], json!([c.id.to_string()]));
    assert_eq!(
        rig.listener.include_sets().len(),
        1,
        "no new set for a silent joiner"
    );

    rig.answer(c, true).await;
    wait_frames(&rig, "include", 1).await;
    let mut all = vec![a.id.to_string(), b.id.to_string(), c.id.to_string()];
    all.sort();
    assert_eq!(rig.listener.include_sets()[1], all);
}

#[tokio::test]
async fn a_pending_person_is_never_in_any_include_set_the_listener_received() {
    let rig = Rig::start("call-audio-never-pending", 3).await;
    let (a, b, c) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    rig.join(c).await;
    rig.leave(b).await;
    wait_frames(&rig, "include", 1).await;
    for set in rig.listener.include_sets() {
        assert!(
            !set.contains(&c.id.to_string()),
            "c never said yes: {set:?}"
        );
    }
}

#[tokio::test]
async fn a_joiner_who_says_no_stops_it_for_everyone() {
    let rig = Rig::start("call-audio-joiner-no", 3).await;
    let (a, b, c) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    wait_frames(&rig, "start", 1).await;
    rig.join(c).await;
    rig.answer(c, false).await;
    rig.wait_session(None).await;
    wait_frames(&rig, "stop", 1).await;
}

#[tokio::test]
async fn a_joiner_who_stays_silent_stays_out_and_the_session_goes_on() {
    let rig = Rig::start("call-audio-joiner-silent", 3).await;
    let (a, b, c) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    rig.join(c).await;
    for outcome in rig.state.call_audio.tick(now_ms() + 10 * 60_000) {
        runtime::apply(&rig.state, outcome).await;
    }
    let view = rig.wait_session(Some("on")).await;
    assert_eq!(view["pending"], json!([c.id.to_string()]));
}

#[tokio::test]
async fn the_last_person_leaving_ends_it() {
    let rig = Rig::start("call-audio-last-leaves", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    wait_frames(&rig, "start", 1).await;
    rig.leave(a).await;
    wait_frames(&rig, "include", 1).await;
    rig.leave(b).await;
    rig.wait_session(None).await;
    wait_frames(&rig, "stop", 1).await;
    assert_eq!(rig.ask(a).await.0, StatusCode::FORBIDDEN, "a left the call");
}

#[tokio::test]
async fn anyone_in_the_call_can_stop_it_and_a_stranger_cannot() {
    let rig = Rig::start("call-audio-stop", 3).await;
    let (a, b, outsider) = (&rig.people[0], &rig.people[1], &rig.people[2]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    wait_frames(&rig, "start", 1).await;

    assert_eq!(rig.stop(outsider).await, StatusCode::FORBIDDEN);
    assert_eq!(rig.stop(b).await, StatusCode::NO_CONTENT);
    rig.wait_session(None).await;
    wait_frames(&rig, "stop", 1).await;
    assert_eq!(rig.ask(a).await.0, StatusCode::TOO_MANY_REQUESTS);
}

#[tokio::test]
async fn a_request_needs_the_call_the_arming_and_the_module() {
    let rig = Rig::start("call-audio-guards", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    assert_eq!(rig.ask(a).await.0, StatusCode::FORBIDDEN, "not in the call");
    rig.join(a).await;

    rig.arm(&[]).await;
    assert_eq!(
        rig.ask(a).await.0,
        StatusCode::CONFLICT,
        "not armed for this channel"
    );
    rig.arm(&[rig.channel]).await;

    rig.store.set_module_enabled(MODULE, false).await.unwrap();
    assert_eq!(rig.ask(a).await.0, StatusCode::CONFLICT, "module off");
    rig.store.set_module_enabled(MODULE, true).await.unwrap();

    assert_eq!(rig.ask(a).await.0, StatusCode::OK);
    assert_eq!(
        rig.ask(b).await.0,
        StatusCode::FORBIDDEN,
        "b is not in the call"
    );
}

#[tokio::test]
async fn someone_on_the_call_since_before_a_restart_can_still_ask() {
    let sfu = RoomService::spawn().await;
    let rig = Rig::start_with_sfu("call-audio-restart", 2, &sfu.url).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    sfu.seat(&[a.id, b.id]);
    // The server restarted mid-call: only b's join reached it afterwards.
    rig.join(b).await;

    let (status, body) = rig.ask(a).await;

    assert_eq!(status, StatusCode::OK, "{body}");
}

#[tokio::test]
async fn the_listeners_session_limit_answers_busy() {
    let rig = Rig::start_with("call-audio-busy", 2, 1, true).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    let second = rig
        .store
        .create_channel("second", "voice")
        .await
        .unwrap()
        .id;
    assert_eq!(rig.arm(&[rig.channel, second]).await, StatusCode::OK);
    rig.join(a).await;
    rig.deliver_in(second, "participant_joined", &b.id.to_string())
        .await;
    assert_eq!(rig.ask(a).await.0, StatusCode::OK);

    let uri = format!("/channels/{second}/voice/call-audio");
    let (status, body) = rig
        .call(b, "POST", &uri, Some(json!({ "module_id": MODULE })))
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert!(body.to_string().contains("busy"), "{body}");
}

#[tokio::test]
async fn losing_the_listener_ends_the_session() {
    let rig = Rig::start("call-audio-listener-lost", 1).await;
    let a = &rig.people[0];
    rig.join(a).await;
    rig.ask(a).await;
    rig.wait_session(Some("on")).await;
    rig.listener.hang_up();
    rig.wait_session(None).await;
}

#[tokio::test]
async fn a_listener_identity_is_ignored_by_the_webhook_and_the_roster() {
    let rig = Rig::start("call-audio-listener-identity", 2).await;
    let (a, b) = (&rig.people[0], &rig.people[1]);
    rig.join(a).await;
    rig.join(b).await;
    rig.ask(a).await;
    rig.answer(b, true).await;
    wait_frames(&rig, "start", 1).await;

    let session = rig.session_id();
    rig.join_raw(&format!("listener-{session}")).await;
    let present = rig.state.voice.live_state().present(rig.channel);
    assert_eq!(present.len(), 2, "the listener is nobody's roster entry");
    let view = rig.wait_session(Some("on")).await;
    assert_eq!(view["pending"], json!([]));
    assert_eq!(rig.listener.include_sets().len(), 1);
}

#[tokio::test]
async fn a_bot_in_the_call_is_neither_asked_nor_heard() {
    let rig = Rig::start("call-audio-bot", 1).await;
    let a = &rig.people[0];
    rig.join(a).await;
    rig.join_raw(&rig.bot.to_string()).await;
    let (_, body) = rig.ask(a).await;
    assert_eq!(
        body["session"]["status"], "on",
        "the bot is not asked: {body}"
    );
    wait_frames(&rig, "start", 1).await;
    assert_eq!(rig.listener.include_sets(), vec![vec![a.id.to_string()]]);
}

#[tokio::test]
async fn the_admin_list_takes_voice_channels_only_and_writes_an_audit_row() {
    let rig = Rig::start_with("call-audio-admin", 1, 2, false).await;
    let text = rig
        .store
        .create_channel("general", "text")
        .await
        .unwrap()
        .id;
    assert_eq!(rig.arm(&[text]).await, StatusCode::BAD_REQUEST);
    assert_eq!(rig.arm(&[rig.channel]).await, StatusCode::OK);

    let uri = format!("/space/dock/modules/{MODULE}/call-audio-channels");
    let (status, body) = rig.call(&rig.admin, "GET", &uri, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["channel_ids"], json!([rig.channel.to_string()]));
    let (status, _) = rig.call(&rig.people[0], "GET", &uri, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    let (_, audit) = rig.call(&rig.admin, "GET", "/space/audit-log", None).await;
    assert!(
        audit.to_string().contains("module.call_audio_channels"),
        "{audit}"
    );
}

#[tokio::test]
async fn taking_a_channel_off_the_list_stops_its_session() {
    let rig = Rig::start("call-audio-channel-removed", 1).await;
    let a = &rig.people[0];
    rig.join(a).await;
    rig.ask(a).await;
    rig.wait_session(Some("on")).await;
    rig.arm(&[]).await;
    rig.wait_session(None).await;
    wait_frames(&rig, "stop", 1).await;
}

#[tokio::test]
async fn an_ask_whose_listener_cannot_start_is_not_answered_with_a_session() {
    let rig = Rig::start_without_voice("call-audio-unstartable", 1).await;
    let a = &rig.people[0];
    rig.state
        .voice
        .live_state()
        .mark_joined(rig.channel, a.id, "sid-a");

    let (status, body) = rig.ask(a).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(body.get("session"), None);
    rig.wait_session(None).await;
    assert!(rig.listener.of_type("start").is_empty());
}
