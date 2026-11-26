// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Text to speech into a call (decision 0142): who may speak a line, the limits,
//! the per-call queue, and the token the speaking participant joins with.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use base64::Engine as _;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::ChannelId;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::tts::{Dispatch, SpeakError, SpeakFuture, Speaker, TtsService};
use slimm_server::voice::VoiceService;
use tokio::sync::Semaphore;

use crate::support;
use support::app::{Account, register_account};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};

/// Records every line and holds each one until released, so a test sees the queue.
struct Fake {
    spoken: Mutex<Vec<Dispatch>>,
    available: AtomicBool,
    /// Makes every line fail once the speaker is asked to say it.
    fail: AtomicBool,
    release: Semaphore,
    active: AtomicUsize,
    most_at_once: AtomicUsize,
}

impl Fake {
    fn new(released: usize) -> Arc<Self> {
        Arc::new(Self {
            spoken: Mutex::default(),
            available: AtomicBool::new(true),
            fail: AtomicBool::new(false),
            release: Semaphore::new(released),
            active: AtomicUsize::new(0),
            most_at_once: AtomicUsize::new(0),
        })
    }

    fn texts(&self) -> Vec<String> {
        self.spoken
            .lock()
            .unwrap()
            .iter()
            .map(|d| d.text.clone())
            .collect()
    }
}

/// What the service holds, sharing the fake with the test.
struct Handle(Arc<Fake>);

impl Speaker for Handle {
    fn available(&self) -> SpeakFuture<'_, bool> {
        Box::pin(async move { self.0.available.load(Ordering::SeqCst) })
    }

    fn speak(&self, dispatch: Dispatch) -> SpeakFuture<'_, Result<(), SpeakError>> {
        Box::pin(async move {
            let fake = &self.0;
            let now = fake.active.fetch_add(1, Ordering::SeqCst) + 1;
            fake.most_at_once.fetch_max(now, Ordering::SeqCst);
            fake.spoken.lock().unwrap().push(dispatch);
            fake.release.acquire().await.unwrap().forget();
            fake.active.fetch_sub(1, Ordering::SeqCst);
            match fake.fail.load(Ordering::SeqCst) {
                true => Err(SpeakError::Failed),
                false => Ok(()),
            }
        })
    }
}

struct Rig {
    store: Store,
    router: Router,
    state: AppState,
    room: RecordingRoomService,
    fake: Arc<Fake>,
    channel: String,
    channel_id: ChannelId,
    seated: Mutex<Vec<slimm_server::ids::UserId>>,
    _db: support::TestDbGuard,
}

async fn rig_with(fake: Arc<Fake>, configured: bool) -> Rig {
    let room = RecordingRoomService::default();
    let sfu = spawn_sfu(room.clone()).await;
    let (store, db) = support::new_store("slimm-tts").await;
    // The first account owns the Space and ignores every overwrite, so it is not a caller.
    register_account(&store, "owner").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let voice = VoiceService::for_test(&sfu, "key", "a-secret-at-least-32-chars-long!");
    let mut state: AppState = support::app::builder(store.clone())
        .voice(voice.clone())
        .build();
    if configured {
        state.tts = TtsService::new(
            Arc::new(Handle(Arc::clone(&fake))),
            voice,
            state.hub.clone(),
            None,
        );
    }
    Rig {
        store,
        router: http::router(state.clone()),
        state,
        room,
        fake,
        channel: channel.id.to_string(),
        channel_id: channel.id,
        seated: Mutex::default(),
        _db: db,
    }
}

async fn rig() -> Rig {
    rig_with(Fake::new(1_000), true).await
}

impl Rig {
    async fn caller(&self, name: &str, in_call: bool) -> Account {
        let account = register_account(&self.store, name).await;
        if in_call {
            let mut seated = self.seated.lock().unwrap();
            seated.push(account.id);
            self.room.seat(&seated);
        }
        account
    }

    async fn say(&self, who: &Account, text: &str) -> (StatusCode, Value) {
        let uri = format!("/channels/{}/voice/tts", self.channel);
        support::app::call_as(
            &self.router,
            "POST",
            &uri,
            &who.token,
            Some(json!({ "text": text })),
        )
        .await
    }

    async fn spoken(&self, count: usize) -> Vec<String> {
        for _ in 0..200 {
            if self.fake.spoken.lock().unwrap().len() >= count {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        self.fake.texts()
    }
}

fn claims(token: &str) -> Value {
    let payload = token.split('.').nth(1).unwrap();
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test]
async fn a_line_from_someone_in_the_call_is_spoken_by_a_labelled_participant() {
    let rig = rig().await;
    let alice = rig.caller("alice", true).await;
    let (status, body) = rig.say(&alice, "  hello \n there  ").await;
    assert_eq!(status, StatusCode::ACCEPTED, "{body}");
    assert_eq!(body["ahead"], 0);
    assert_eq!(rig.spoken(1).await, vec!["hello there"]);

    let dispatch = rig.fake.spoken.lock().unwrap()[0].clone();
    let claims = claims(&dispatch.token);
    assert_eq!(claims["sub"], format!("tts-{}", alice.id));
    assert_eq!(claims["name"], "alice (TTS)");
    assert_eq!(
        claims["video"]["room"],
        format!("channel-{}", rig.channel_id)
    );
    assert_eq!(claims["video"]["canPublish"], true);
    assert_eq!(claims["video"]["canSubscribe"], false);
    assert_ne!(
        claims["video"]["hidden"], true,
        "everyone in the call can see who is speaking"
    );
}

#[tokio::test]
async fn someone_outside_the_call_cannot_speak_into_it() {
    let rig = rig().await;
    let watcher = rig.caller("watcher", false).await;
    let (status, _) = rig.say(&watcher, "hello").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(rig.fake.texts().is_empty());
}

#[tokio::test]
async fn someone_server_muted_in_the_call_is_refused() {
    let rig = rig().await;
    let muted = rig.caller("muted", true).await;
    rig.store
        .set_member_overwrite(
            rig.channel_id,
            muted.id,
            Permissions::NONE,
            Permissions::SPEAK,
        )
        .await
        .unwrap();
    let (status, _) = rig.say(&muted, "hello").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(rig.fake.texts().is_empty());
}

#[tokio::test]
async fn someone_who_may_not_send_messages_is_refused() {
    let rig = rig().await;
    let quiet = rig.caller("quiet", true).await;
    rig.store
        .set_member_overwrite(
            rig.channel_id,
            quiet.id,
            Permissions::NONE,
            Permissions::SEND_MESSAGES,
        )
        .await
        .unwrap();
    let (status, _) = rig.say(&quiet, "hello").await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(rig.fake.texts().is_empty());
}

#[tokio::test]
async fn empty_and_overlong_lines_are_refused() {
    let rig = rig().await;
    let alice = rig.caller("alice", true).await;
    assert_eq!(rig.say(&alice, " \n ").await.0, StatusCode::BAD_REQUEST);
    let long = "a".repeat(301);
    assert_eq!(rig.say(&alice, &long).await.0, StatusCode::BAD_REQUEST);
    let bob = rig.caller("bob", true).await;
    let longest = "a".repeat(300);
    assert_eq!(rig.say(&bob, &longest).await.0, StatusCode::ACCEPTED);
}

#[tokio::test]
async fn without_a_voice_the_server_says_it_is_not_set_up() {
    let off = rig_with(Fake::new(1_000), false).await;
    let alice = off.caller("alice", true).await;
    assert_eq!(
        off.say(&alice, "hello").await.0,
        StatusCode::NOT_IMPLEMENTED
    );

    let fake = Fake::new(1_000);
    fake.available.store(false, Ordering::SeqCst);
    let away = rig_with(fake, true).await;
    let bob = away.caller("bob", true).await;
    assert_eq!(away.say(&bob, "hello").await.0, StatusCode::NOT_IMPLEMENTED);
}

#[tokio::test]
async fn a_person_gets_two_lines_at_once_then_one_every_five_seconds() {
    let rig = rig().await;
    let alice = rig.caller("alice", true).await;
    let bob = rig.caller("bob", true).await;
    assert_eq!(rig.say(&alice, "one").await.0, StatusCode::ACCEPTED);
    assert_eq!(rig.say(&alice, "two").await.0, StatusCode::ACCEPTED);
    assert_eq!(
        rig.say(&alice, "three").await.0,
        StatusCode::TOO_MANY_REQUESTS
    );
    assert_eq!(
        rig.say(&bob, "mine").await.0,
        StatusCode::ACCEPTED,
        "another person has their own budget"
    );
}

#[tokio::test]
async fn a_call_speaks_one_line_at_a_time_in_order_and_its_queue_is_bounded() {
    let rig = rig_with(Fake::new(0), true).await;
    let people = [
        rig.caller("a", true).await,
        rig.caller("b", true).await,
        rig.caller("c", true).await,
    ];
    let mut accepted = Vec::new();
    for (n, person) in people.iter().enumerate() {
        for k in 0..2 {
            let text = format!("line {n}{k}");
            let (status, body) = rig.say(person, &text).await;
            if status == StatusCode::ACCEPTED {
                accepted.push((text, body["ahead"].as_u64().unwrap()));
            } else {
                assert_eq!(
                    (n, k, status),
                    (2, 1, StatusCode::TOO_MANY_REQUESTS),
                    "only the sixth is over the call's five"
                );
            }
        }
    }
    assert_eq!(accepted.len(), 5);
    assert_eq!(
        accepted.iter().map(|(_, ahead)| *ahead).collect::<Vec<_>>(),
        vec![0, 1, 2, 3, 4]
    );

    assert_eq!(
        rig.spoken(1).await,
        vec!["line 00"],
        "the first is being spoken and nothing else yet"
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(rig.fake.texts(), vec!["line 00"]);
    rig.fake.release.add_permits(10);
    assert_eq!(
        rig.spoken(5).await,
        accepted.iter().map(|(t, _)| t.clone()).collect::<Vec<_>>()
    );
    assert_eq!(rig.fake.most_at_once.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_speaker_who_left_the_call_before_their_turn_is_skipped() {
    let rig = rig_with(Fake::new(0), true).await;
    let alice = rig.caller("alice", true).await;
    let bob = rig.caller("bob", true).await;
    assert_eq!(rig.say(&alice, "first").await.0, StatusCode::ACCEPTED);
    assert_eq!(rig.spoken(1).await, vec!["first"]);
    assert_eq!(rig.say(&bob, "second").await.0, StatusCode::ACCEPTED);
    rig.room.seat(&[alice.id]);
    rig.fake.release.add_permits(10);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        rig.fake.texts(),
        vec!["first"],
        "bob left, so his line is dropped"
    );
}

#[tokio::test]
async fn a_line_that_fails_after_it_was_accepted_tells_only_who_typed_it() {
    let rig = rig().await;
    rig.fake.fail.store(true, Ordering::SeqCst);
    let alice = rig.caller("alice", true).await;
    let bob = rig.caller("bob", true).await;
    let addr = support::ws::serve(rig.state.clone()).await;
    let mut sockets = Vec::new();
    for account in [&alice, &bob] {
        let ctx = rig
            .store
            .authenticate(&account.token)
            .await
            .unwrap()
            .unwrap();
        let (ticket, _) = rig.store.mint_ws_ticket(&ctx).await.unwrap();
        sockets.push(support::ws::connect(addr, &ticket).await);
    }
    let mut bob_socket = sockets.pop().unwrap();
    let mut alice_socket = sockets.pop().unwrap();
    assert_eq!(rig.say(&alice, "hello").await.0, StatusCode::ACCEPTED);
    let frame = support::ws::read_frame_of_type(&mut alice_socket, "tts.failed").await;
    assert_eq!(frame["channel_id"], rig.channel);
    support::ws::settle(&mut bob_socket).await;
    support::ws::assert_no_frame_of_type(&mut bob_socket, "tts.failed").await;
}

#[tokio::test]
async fn a_line_that_is_spoken_sends_no_failure() {
    let rig = rig().await;
    let alice = rig.caller("alice", true).await;
    let addr = support::ws::serve(rig.state.clone()).await;
    let ctx = rig.store.authenticate(&alice.token).await.unwrap().unwrap();
    let (ticket, _) = rig.store.mint_ws_ticket(&ctx).await.unwrap();
    let mut socket = support::ws::connect(addr, &ticket).await;
    assert_eq!(rig.say(&alice, "hello").await.0, StatusCode::ACCEPTED);
    assert_eq!(rig.spoken(1).await, vec!["hello"]);
    support::ws::settle(&mut socket).await;
    support::ws::assert_no_frame_of_type(&mut socket, "tts.failed").await;
}
