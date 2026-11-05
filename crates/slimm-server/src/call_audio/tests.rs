// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The service around the state machine: capacity, the cooldown, and what is
//! accepted from the listener. Everything runs without a listener process: a
//! `CallAudio` is enabled by pointing it at an address nothing listens on and
//! then marked ready by hand.

use super::protocol::FromListener;
use super::session::{Effect, EndReason, Subject};
use super::*;

fn service(max_sessions: u32) -> CallAudio {
    let settings = ListenerSettings {
        url: "ws://127.0.0.1:1".into(),
        secret: "x".repeat(32),
        livekit_url: None,
    };
    let call_audio = CallAudio::new(Some(settings));
    call_audio.listener_ready(max_sessions);
    call_audio
}

fn subject() -> Subject {
    Subject {
        module_id: "transcript".into(),
        module_name: "Transcript".into(),
        purpose: "p".into(),
        keeps: "k".into(),
    }
}

fn people(n: usize) -> Vec<UserId> {
    (0..n).map(|_| UserId::generate()).collect()
}

fn start(call_audio: &CallAudio, channel: ChannelId, who: &[UserId], now: i64) -> Outcome {
    let outcome = call_audio
        .begin((channel, subject()), who[0], who, now)
        .expect("begins");
    for user in &who[1..] {
        call_audio
            .consent(channel, *user, true, now)
            .unwrap()
            .unwrap();
    }
    outcome
}

fn segment(session: Uuid, identity: UserId, text: &str) -> FromListener {
    FromListener::Segment {
        session: session.to_string(),
        identity: identity.to_string(),
        start_ms: 100,
        end_ms: 900,
        text: text.into(),
        language: Some("en".into()),
    }
}

#[tokio::test]
async fn a_disabled_service_refuses_everything() {
    let off = CallAudio::disabled();
    let who = people(1);
    let got = off.begin((ChannelId::generate(), subject()), who[0], &who, 0);
    assert_eq!(got.unwrap_err(), RequestError::Unavailable);
    assert!(!off.is_ready());
}

#[tokio::test]
async fn nothing_starts_before_the_listener_says_ready() {
    let call_audio = CallAudio::new(Some(ListenerSettings {
        url: "ws://127.0.0.1:1".into(),
        secret: "x".repeat(32),
        livekit_url: None,
    }));
    let who = people(1);
    let got = call_audio.begin((ChannelId::generate(), subject()), who[0], &who, 0);
    assert_eq!(got.unwrap_err(), RequestError::Unavailable);
}

#[tokio::test]
async fn the_listeners_session_limit_answers_busy() {
    let call_audio = service(1);
    let one = people(1);
    call_audio
        .begin((ChannelId::generate(), subject()), one[0], &one, 0)
        .unwrap();
    let two = people(1);
    let got = call_audio.begin((ChannelId::generate(), subject()), two[0], &two, 0);
    assert_eq!(got.unwrap_err(), RequestError::Busy);
}

#[tokio::test]
async fn one_session_per_call() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);
    call_audio
        .begin((channel, subject()), who[0], &who, 0)
        .unwrap();
    let got = call_audio.begin((channel, subject()), who[1], &who, 0);
    assert_eq!(got.unwrap_err(), RequestError::AlreadyOn);
}

#[tokio::test]
async fn a_decline_a_lapse_and_a_stop_each_start_a_sixty_second_wait() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);

    call_audio
        .begin((channel, subject()), who[0], &who, 1_000)
        .unwrap();
    call_audio
        .consent(channel, who[1], false, 2_000)
        .unwrap()
        .unwrap();
    let got = call_audio.begin((channel, subject()), who[0], &who, 3_000);
    assert_eq!(got.unwrap_err(), RequestError::Cooldown(59_000));
    assert!(
        call_audio
            .begin((channel, subject()), who[0], &who, 62_000)
            .is_ok()
    );

    let lapse_at = 62_000 + session::ASK_WINDOW_MS;
    let ended = call_audio.tick(lapse_at);
    assert_eq!(ended.len(), 1);
    let got = call_audio.begin((channel, subject()), who[0], &who, lapse_at + 1);
    assert!(matches!(got, Err(RequestError::Cooldown(_))));

    let later = lapse_at + COOLDOWN_MS + 1;
    call_audio
        .begin((channel, subject()), who[0], &who, later)
        .unwrap();
    call_audio
        .stop(channel, who[1], later + 1)
        .unwrap()
        .unwrap();
    let got = call_audio.begin((channel, subject()), who[0], &who, later + 2);
    assert!(matches!(got, Err(RequestError::Cooldown(_))));
}

#[tokio::test]
async fn the_call_ending_or_the_listener_failing_starts_no_wait() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(1);
    call_audio
        .begin((channel, subject()), who[0], &who, 0)
        .unwrap();
    call_audio.left(channel, who[0], 1).unwrap();
    assert!(
        call_audio
            .begin((channel, subject()), who[0], &who, 2)
            .is_ok()
    );
    call_audio.end(channel, EndReason::Overload, 3).unwrap();
    assert!(
        call_audio
            .begin((channel, subject()), who[0], &who, 4)
            .is_ok()
    );
}

#[tokio::test]
async fn losing_the_listener_ends_every_session() {
    let call_audio = service(2);
    let (a, b) = (ChannelId::generate(), ChannelId::generate());
    let (pa, pb) = (people(1), people(1));
    call_audio.begin((a, subject()), pa[0], &pa, 0).unwrap();
    call_audio.begin((b, subject()), pb[0], &pb, 0).unwrap();
    let ended = call_audio.listener_lost(5);
    assert_eq!(ended.len(), 2);
    for outcome in ended {
        assert!(outcome.effects.contains(&Effect::Ended {
            reason: EndReason::ListenerUnavailable,
            was_on: true
        }));
    }
    assert!(!call_audio.is_ready());
    assert!(call_audio.channels(None).is_empty());
}

#[tokio::test]
async fn a_segment_from_anyone_outside_the_last_include_set_is_dropped() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);
    let outcome = start(&call_audio, channel, &who, 1_000);
    let joiner = UserId::generate();
    call_audio.joined(channel, joiner, 1_001);
    call_audio.send_include(channel);

    let yes = call_audio.accept_segment(&segment(outcome.session_id, who[1], "hello"), 2_000);
    let yes = yes.expect("an included speaker is heard");
    assert_eq!(
        yes.start_ms, 1_100,
        "offsets are made wall-clock from the start"
    );
    assert_eq!(yes.text, "hello");
    assert!(
        call_audio
            .accept_segment(&segment(outcome.session_id, joiner, "sneaky"), 2_001)
            .is_none(),
        "a pending joiner is never heard"
    );
    assert!(
        call_audio
            .accept_segment(
                &segment(outcome.session_id, UserId::generate(), "who"),
                2_002
            )
            .is_none()
    );
    assert_eq!(call_audio.dropped(channel), 2);
}

#[tokio::test]
async fn the_set_last_sent_decides_so_a_leaver_is_dropped_after_the_resend() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);
    let outcome = start(&call_audio, channel, &who, 0);
    call_audio.send_include(channel);
    assert!(
        call_audio
            .accept_segment(&segment(outcome.session_id, who[1], "a"), 1)
            .is_some()
    );
    call_audio.left(channel, who[1], 2).unwrap();
    call_audio.send_include(channel);
    assert!(
        call_audio
            .accept_segment(&segment(outcome.session_id, who[1], "b"), 3)
            .is_none()
    );
}

#[tokio::test]
async fn long_text_is_cut_and_a_flood_is_capped_and_counted() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(1);
    let outcome = start(&call_audio, channel, &who, 0);
    call_audio.send_include(channel);

    let long = "word ".repeat(400);
    let cut = call_audio.accept_segment(&segment(outcome.session_id, who[0], &long), 1);
    assert!(cut.unwrap().text.chars().count() <= 1_000);

    for i in 0..(filter::MAX_PER_MINUTE as i64 + 10) {
        call_audio.accept_segment(&segment(outcome.session_id, who[0], "x"), 2 + i);
    }
    assert_eq!(call_audio.dropped(channel), 11);
}

#[tokio::test]
async fn event_ids_are_minted_once_in_order_and_count_delivered_segments() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(1);
    let outcome = start(&call_audio, channel, &who, 0);
    call_audio.send_include(channel);
    let first = call_audio
        .accept_segment(&segment(outcome.session_id, who[0], "one"), 1)
        .unwrap();
    let second = call_audio
        .accept_segment(&segment(outcome.session_id, who[0], "two"), 2)
        .unwrap();
    let prefix = format!("call-audio:{}:", outcome.session_id);
    assert_eq!(first.segment_id, format!("{prefix}1"));
    assert_eq!(second.segment_id, format!("{prefix}2"));
    assert_eq!(second.ids.segments_sent(), 2);
    assert_eq!(outcome.ids.mint(), format!("{prefix}3"));
}

#[tokio::test]
async fn a_segment_for_a_session_that_is_not_on_is_ignored() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);
    let asking = call_audio
        .begin((channel, subject()), who[0], &who, 0)
        .unwrap();
    assert!(
        call_audio
            .accept_segment(&segment(asking.session_id, who[0], "early"), 1)
            .is_none()
    );
    assert!(
        call_audio
            .accept_segment(&segment(Uuid::now_v7(), who[0], "unknown"), 1)
            .is_none()
    );
}

#[tokio::test]
async fn the_requester_leaving_during_the_ask_starts_no_wait() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);
    call_audio
        .begin((channel, subject()), who[0], &who, 1_000)
        .unwrap();

    let left = call_audio.left(channel, who[0], 2_000).expect("a session");
    assert!(matches!(
        left.effects[..],
        [Effect::Ended {
            reason: EndReason::RequesterLeft,
            ..
        }]
    ));
    assert!(
        call_audio
            .begin((channel, subject()), who[1], &who, 3_000)
            .is_ok(),
        "somebody leaving is not somebody refusing"
    );
}

#[tokio::test]
async fn a_cooldown_is_forgotten_once_it_has_run_out() {
    let call_audio = service(2);
    let channel = ChannelId::generate();
    let who = people(2);
    call_audio
        .begin((channel, subject()), who[0], &who, 1_000)
        .unwrap();
    call_audio
        .consent(channel, who[1], false, 2_000)
        .unwrap()
        .unwrap();
    assert_eq!(call_audio.cooldown_count(), 1);

    call_audio.tick(2_000 + COOLDOWN_MS - 1);
    assert_eq!(call_audio.cooldown_count(), 1, "still waiting");
    call_audio.tick(2_000 + COOLDOWN_MS);
    assert_eq!(call_audio.cooldown_count(), 0);
}
