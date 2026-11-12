// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The include filter and the limits, through a fake room and a fake transcriber.

use std::sync::Mutex;

use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};

use super::*;
use crate::stt::{Transcriber, Transcript};

/// Feeds scripted events and records every subscription change.
struct FakeRoom {
    events: tokio::sync::mpsc::UnboundedReceiver<RoomEvent>,
    calls: Arc<Mutex<Vec<(TrackRef, bool)>>>,
    left: Arc<Mutex<bool>>,
}

impl RoomSource for FakeRoom {
    async fn next_event(&mut self) -> Option<RoomEvent> {
        self.events.recv().await
    }

    fn subscribe(&mut self, track: &TrackRef, on: bool) {
        self.calls.lock().unwrap().push((track.clone(), on));
    }

    async fn leave(&mut self) {
        *self.left.lock().unwrap() = true;
    }
}

/// Says how many milliseconds it heard.
struct Counting;

impl Transcriber for Counting {
    fn transcribe(&self, pcm: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
        Ok(Transcript {
            text: format!("heard {} ms", pcm.len() / 16),
            language: Some("en".into()),
        })
    }

    fn model(&self) -> String {
        "counting".into()
    }
}

struct Rig {
    events: UnboundedSender<RoomEvent>,
    commands: UnboundedSender<SessionCommand>,
    reports: tokio::sync::mpsc::UnboundedReceiver<Report>,
    calls: Arc<Mutex<Vec<(TrackRef, bool)>>>,
    left: Arc<Mutex<bool>>,
    task: tokio::task::JoinHandle<Ending>,
}

fn rig(include: &[&str]) -> Rig {
    let (events, feed) = unbounded_channel();
    let (commands, command_feed) = unbounded_channel();
    let (reports_tx, reports) = unbounded_channel();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let left = Arc::new(Mutex::new(false));
    let room = FakeRoom {
        events: feed,
        calls: calls.clone(),
        left: left.clone(),
    };
    let params = Params {
        id: "s1".into(),
        include: include.iter().map(|s| (*s).to_owned()).collect(),
        language: None,
    };
    let pool = Arc::new(Pool::new(Arc::new(Counting), 2));
    let task = tokio::spawn(run(params, room, command_feed, pool, reports_tx));
    Rig {
        events,
        commands,
        reports,
        calls,
        left,
        task,
    }
}

fn track(who: &str, sid: &str) -> TrackRef {
    TrackRef {
        identity: who.into(),
        sid: sid.into(),
    }
}

fn publish(rig: &Rig, who: &str, sid: &str, microphone: bool) {
    rig.events
        .send(RoomEvent::Published {
            track: track(who, sid),
            microphone,
        })
        .unwrap();
}

fn tone(ms: usize) -> Vec<i16> {
    (0..ms * 16)
        .map(|n| ((n as f32 * 440.0 * std::f32::consts::TAU / 16_000.0).sin() * 8_000.0) as i16)
        .collect()
}

fn hush(ms: usize) -> Vec<i16> {
    vec![0; ms * 16]
}

/// Sends a short phrase from `who`, with silence around it.
fn say(rig: &Rig, who: &str) {
    for part in [hush(500), tone(900), hush(900)] {
        rig.events
            .send(RoomEvent::Audio {
                identity: who.into(),
                samples: part,
            })
            .unwrap();
    }
}

async fn next_report(rig: &mut Rig) -> Report {
    tokio::time::timeout(Duration::from_secs(5), rig.reports.recv())
        .await
        .expect("a report in time")
        .expect("the session is alive")
}

async fn settle() {
    for _ in 0..20 {
        tokio::task::yield_now().await;
    }
}

#[tokio::test]
async fn it_reports_started_and_then_only_hears_the_include_set() {
    let mut rig = rig(&["alice"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    publish(&rig, "alice", "TR_a", true);
    publish(&rig, "bob", "TR_b", true);
    settle().await;
    assert_eq!(
        *rig.calls.lock().unwrap(),
        vec![(track("alice", "TR_a"), true)],
        "bob said nothing and is not subscribed"
    );
}

#[tokio::test]
async fn only_microphones_are_ever_subscribed() {
    let rig = rig(&["alice"]);
    publish(&rig, "alice", "TR_screen_audio", false);
    publish(&rig, "alice", "TR_camera", false);
    publish(&rig, "alice", "TR_mic", true);
    settle().await;
    assert_eq!(
        *rig.calls.lock().unwrap(),
        vec![(track("alice", "TR_mic"), true)]
    );
}

#[tokio::test]
async fn a_person_who_says_yes_later_is_subscribed_and_one_removed_is_dropped() {
    let rig = rig(&["alice"]);
    publish(&rig, "alice", "TR_a", true);
    publish(&rig, "bob", "TR_b", true);
    settle().await;
    rig.commands
        .send(SessionCommand::Include(
            ["alice", "bob"].map(String::from).into(),
        ))
        .unwrap();
    settle().await;
    rig.commands
        .send(SessionCommand::Include(["bob"].map(String::from).into()))
        .unwrap();
    settle().await;
    assert_eq!(
        *rig.calls.lock().unwrap(),
        vec![
            (track("alice", "TR_a"), true),
            (track("bob", "TR_b"), true),
            (track("alice", "TR_a"), false),
        ]
    );
}

#[tokio::test]
async fn speech_from_an_included_person_becomes_a_segment_and_others_are_ignored() {
    let mut rig = rig(&["alice"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    say(&rig, "bob");
    say(&rig, "alice");
    let Report::Segment {
        identity,
        text,
        session,
        ..
    } = next_report(&mut rig).await
    else {
        panic!("expected a segment");
    };
    assert_eq!((identity.as_str(), session.as_str()), ("alice", "s1"));
    assert!(text.starts_with("heard "), "{text}");
    settle().await;
    assert!(rig.reports.try_recv().is_err(), "nothing for bob");
}

#[tokio::test]
async fn speech_in_flight_for_someone_removed_is_never_reported() {
    let mut rig = rig(&["alice", "bob"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    say(&rig, "bob");
    rig.commands
        .send(SessionCommand::Include(["alice"].map(String::from).into()))
        .unwrap();
    say(&rig, "alice");
    let Report::Segment { identity, .. } = next_report(&mut rig).await else {
        panic!("expected a segment");
    };
    assert_eq!(identity, "alice");
    settle().await;
    assert!(rig.reports.try_recv().is_err());
}

#[tokio::test(start_paused = true)]
async fn four_hours_ends_it_with_time_limit_and_leaves_the_room() {
    let mut rig = rig(&["alice"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    tokio::time::advance(Duration::from_millis(TIME_LIMIT_MS as u64 + 2_000)).await;
    let Report::Ended { reason, .. } = next_report(&mut rig).await else {
        panic!("expected ended");
    };
    assert_eq!(reason, "time_limit");
    assert_eq!(rig.task.await.unwrap(), Ending::TimeLimit);
    assert!(*rig.left.lock().unwrap());
}

#[tokio::test]
async fn a_stop_leaves_the_room_and_reports_nothing() {
    let mut rig = rig(&["alice"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    rig.commands.send(SessionCommand::Stop).unwrap();
    assert_eq!(rig.task.await.unwrap(), Ending::Stopped);
    assert!(*rig.left.lock().unwrap());
    assert!(rig.reports.try_recv().is_err());
}

#[tokio::test]
async fn the_room_closing_ends_the_session_with_room_error() {
    let mut rig = rig(&["alice"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    rig.events.send(RoomEvent::Closed).unwrap();
    let Report::Ended { reason, .. } = next_report(&mut rig).await else {
        panic!("expected ended");
    };
    assert_eq!(reason, "room_error");
}

#[tokio::test(start_paused = true)]
async fn a_backlog_that_stays_full_ends_the_session_with_overload() {
    /// Never finishes, so the backlog only grows.
    struct Stuck;
    impl Transcriber for Stuck {
        fn transcribe(&self, _: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
            std::thread::sleep(Duration::from_secs(3_600));
            unreachable!()
        }
        fn model(&self) -> String {
            "stuck".into()
        }
    }
    let (events, feed) = unbounded_channel();
    let (_commands, command_feed) = unbounded_channel();
    let (reports_tx, mut reports) = unbounded_channel();
    let room = FakeRoom {
        events: feed,
        calls: Arc::default(),
        left: Arc::default(),
    };
    let params = Params {
        id: "s1".into(),
        include: ["alice".to_owned()].into(),
        language: None,
    };
    let pool = Arc::new(Pool::new(Arc::new(Stuck), 1));
    let task = tokio::spawn(run(params, room, command_feed, pool, reports_tx));
    assert!(matches!(reports.recv().await, Some(Report::Started { .. })));
    for _ in 0..8 {
        for part in [hush(500), tone(14_000), hush(900)] {
            events
                .send(RoomEvent::Audio {
                    identity: "alice".into(),
                    samples: part,
                })
                .unwrap();
        }
    }
    settle().await;
    for _ in 0..13 {
        tokio::time::advance(Duration::from_secs(10)).await;
        settle().await;
    }
    let ended = tokio::time::timeout(Duration::from_secs(5), reports.recv())
        .await
        .unwrap();
    assert!(
        matches!(ended, Some(Report::Ended { ref reason, .. }) if reason == "overload"),
        "{ended:?}"
    );
    assert_eq!(task.await.unwrap(), Ending::Overload);
}

#[tokio::test]
async fn a_stop_mid_sentence_still_reports_what_was_said() {
    let mut rig = rig(&["alice"]);
    assert!(matches!(
        next_report(&mut rig).await,
        Report::Started { .. }
    ));
    for part in [hush(500), tone(900)] {
        rig.events
            .send(RoomEvent::Audio {
                identity: "alice".into(),
                samples: part,
            })
            .unwrap();
    }
    settle().await;
    rig.commands.send(SessionCommand::Stop).unwrap();
    let Report::Segment { identity, .. } = next_report(&mut rig).await else {
        panic!("the sentence in progress is transcribed before the session ends");
    };
    assert_eq!(identity, "alice");
    assert_eq!(rig.task.await.unwrap(), Ending::Stopped);
}
