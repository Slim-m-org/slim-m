// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Opt-in voice notices (decision 0107): who hears that a call started, grew or went live,
//! driven through the real LiveKit webhook route and read off a recipient's socket.

use std::time::Duration;

use futures_util::StreamExt;
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use slimm_server::presence::Visibility;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use slimm_server::voice_notify::{JoinMode, VoiceNotifyChoice};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tower::ServiceExt;

mod support;

use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::livekit_webhook::webhook_request;
use support::ws::{Client, connect, serve, user_ticket};

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

const EVERY: VoiceNotifyChoice = VoiceNotifyChoice {
    joins: JoinMode::Every,
    streams: false,
};
const FIRST: VoiceNotifyChoice = VoiceNotifyChoice {
    joins: JoinMode::First,
    streams: false,
};
const STREAMS: VoiceNotifyChoice = VoiceNotifyChoice {
    joins: JoinMode::Off,
    streams: true,
};

struct World {
    store: Store,
    state: AppState,
    addr: std::net::SocketAddr,
    channel: ChannelId,
    _guard: support::TestDbGuard,
}

struct Member {
    id: UserId,
    ws: Client,
}

impl World {
    async fn new() -> Self {
        Self::on("http://127.0.0.1:1").await
    }

    /// A deployment whose LiveKit room service answers at `sfu_url`.
    async fn on(sfu_url: &str) -> Self {
        let (store, guard) = support::new_store("slimm-voice-notify-test").await;
        store
            .create_role("everyone", Permissions::VIEW_CHANNEL, true)
            .await
            .unwrap();
        let channel = store.create_channel("lounge", "voice").await.unwrap().id;
        let state = support::app::builder(store.clone())
            .voice(VoiceService::for_test(sfu_url, API_KEY, API_SECRET))
            .build();
        let addr = serve(state.clone()).await;
        Self {
            store,
            state,
            addr,
            channel,
            _guard: guard,
        }
    }

    /// A member with a live socket and, when given, a choice for the lounge.
    async fn member(&self, name: &str, choice: Option<VoiceNotifyChoice>) -> Member {
        let (_, ticket, id) = user_ticket(&self.store, name).await;
        if let Some(choice) = choice {
            self.store
                .set_voice_notify_choice(id, self.channel, choice)
                .await
                .unwrap();
        }
        let ws = connect(self.addr, &ticket).await;
        Member { id, ws }
    }

    async fn deliver(&self, body: Value) {
        let response = http::router(self.state.clone())
            .oneshot(webhook_request(body, API_KEY, API_SECRET))
            .await
            .unwrap();
        assert_eq!(response.status(), 204);
    }

    async fn join(&self, who: UserId) {
        let room = slimm_server::voice::room_for_channel(self.channel);
        self.deliver(json!({
            "event": "participant_joined",
            "room": { "name": room },
            "participant": { "identity": who.to_string(), "sid": format!("PA_{who}") },
        }))
        .await;
    }

    async fn go_live(&self, who: UserId) {
        let room = slimm_server::voice::room_for_channel(self.channel);
        self.deliver(json!({
            "event": "track_published",
            "room": { "name": room },
            "participant": { "identity": who.to_string(), "sid": format!("PA_{who}") },
            "track": { "sid": "TR_screen", "source": "SCREEN_SHARE" },
        }))
        .await;
    }
}

/// The next `voice.notice` frame, or `None` once `wait` passes without one.
async fn notice(ws: &mut Client, wait: Duration) -> Option<Value> {
    tokio::time::timeout(wait, async {
        loop {
            if let Some(Ok(WsMessage::Text(text))) = ws.next().await {
                let frame: Value = serde_json::from_str(text.as_str()).unwrap();
                if frame["type"] == "voice.notice" {
                    return frame;
                }
            }
        }
    })
    .await
    .ok()
}

const HEARS: Duration = Duration::from_secs(2);
const SILENT: Duration = Duration::from_millis(400);

#[tokio::test]
async fn the_first_join_tells_an_every_join_member_that_the_call_started() {
    let world = World::new().await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let alice = world.member("alice", None).await;

    world.join(alice.id).await;

    let frame = notice(&mut bob.ws, HEARS).await.expect("bob is told");
    assert_eq!(frame["channel_id"], world.channel.to_string());
    assert_eq!(frame["actor_id"], alice.id.to_string());
    assert_eq!(frame["activity"], "call_started");
}

#[tokio::test]
async fn a_later_join_tells_only_every_join_not_first_join() {
    let world = World::new().await;
    let mut first = world.member("first", Some(FIRST)).await;
    let mut every = world.member("every", Some(EVERY)).await;
    let carol = world.member("carol", None).await;
    let alice = world.member("alice", None).await;

    world.join(carol.id).await;
    // The ten minute limit holds the next notice back, so fresh members show the difference.
    assert!(notice(&mut first.ws, HEARS).await.is_some());
    assert!(notice(&mut every.ws, HEARS).await.is_some());
    let mut late_first = world.member("late-first", Some(FIRST)).await;
    let mut late_every = world.member("late-every", Some(EVERY)).await;

    world.join(alice.id).await;

    let frame = notice(&mut late_every.ws, HEARS).await.expect("told");
    assert_eq!(frame["activity"], "joined");
    assert!(notice(&mut late_first.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn a_burst_of_joins_is_one_notice_per_ten_minutes() {
    let world = World::new().await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let people = [
        world.member("a", None).await,
        world.member("b", None).await,
        world.member("c", None).await,
    ];

    for person in &people {
        world.join(person.id).await;
    }

    assert!(notice(&mut bob.ws, HEARS).await.is_some());
    assert!(
        notice(&mut bob.ws, SILENT).await.is_none(),
        "collapsed into the first"
    );
}

#[tokio::test]
async fn going_live_is_its_own_switch() {
    let world = World::new().await;
    let mut streams = world.member("streams", Some(STREAMS)).await;
    let mut joins = world.member("joins", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    // Someone already on the call, so the join below is not a call start.
    let carol = world.member("carol", None).await;
    world.join(carol.id).await;
    assert!(notice(&mut joins.ws, HEARS).await.is_some());

    world.go_live(alice.id).await;

    let frame = notice(&mut streams.ws, HEARS).await.expect("told");
    assert_eq!(frame["activity"], "streaming");
    assert!(
        notice(&mut joins.ws, SILENT).await.is_none(),
        "joins hears no stream"
    );
    assert!(
        notice(&mut streams.ws, SILENT).await.is_none(),
        "streams hears no join"
    );
}

#[tokio::test]
async fn your_own_join_never_tells_you() {
    let world = World::new().await;
    let mut alice = world.member("alice", Some(EVERY)).await;

    world.join(alice.id).await;

    assert!(notice(&mut alice.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn someone_already_on_the_call_is_not_told_about_the_next_join() {
    let world = World::new().await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    let carol = world.member("carol", None).await;
    world.join(bob.id).await;

    world.join(alice.id).await;
    world.join(carol.id).await;

    assert!(notice(&mut bob.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn a_hidden_members_join_announces_nobody() {
    let world = World::new().await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    world
        .store
        .set_presence_visibility(alice.id, Visibility::Hidden)
        .await
        .unwrap();

    world.join(alice.id).await;

    assert!(notice(&mut bob.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn a_member_who_blocked_the_actor_is_not_told() {
    let world = World::new().await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    world.store.block_user(bob.id, alice.id).await.unwrap();

    world.join(alice.id).await;

    assert!(notice(&mut bob.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn do_not_disturb_and_a_muted_channel_both_stay_quiet() {
    let world = World::new().await;
    let mut dnd = world.member("dnd", Some(EVERY)).await;
    let mut muted = world.member("muted", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    world
        .store
        .set_presence_visibility(dnd.id, Visibility::Dnd)
        .await
        .unwrap();
    world
        .store
        .set_channel_notification_preference(
            muted.id,
            world.channel,
            slimm_server::notifications::NotificationPreference::Nothing,
        )
        .await
        .unwrap();

    world.join(alice.id).await;

    assert!(notice(&mut dnd.ws, SILENT).await.is_none());
    assert!(notice(&mut muted.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn a_member_off_hours_is_not_told_but_a_channel_exception_is() {
    let world = World::new().await;
    let mut snoozed = world.member("snoozed", Some(EVERY)).await;
    let mut allowed = world.member("allowed", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    let until = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
        + 60 * 60 * 1000;
    for member in [&snoozed, &allowed] {
        world
            .store
            .set_notification_snooze(member.id, Some(until))
            .await
            .unwrap();
    }
    world
        .store
        .add_notification_schedule_allowed_channel(allowed.id, world.channel)
        .await
        .unwrap();

    world.join(alice.id).await;

    assert!(notice(&mut allowed.ws, HEARS).await.is_some());
    assert!(notice(&mut snoozed.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn a_member_who_cannot_see_the_channel_is_not_told() {
    let world = World::new().await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    world
        .store
        .set_member_overwrite(
            world.channel,
            bob.id,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();

    world.join(alice.id).await;

    assert!(notice(&mut bob.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn without_a_choice_nobody_is_told() {
    let world = World::new().await;
    let mut bob = world.member("bob", None).await;
    let alice = world.member("alice", None).await;

    world.join(alice.id).await;
    world.go_live(alice.id).await;

    assert!(notice(&mut bob.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn a_join_after_a_restart_is_a_join_into_a_call_under_way() {
    let sfu = RecordingRoomService::default();
    let sfu_url = spawn_sfu(sfu.clone()).await;
    let world = World::on(&sfu_url).await;
    let mut alice = world.member("alice", Some(EVERY)).await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let mut dave = world.member("dave", Some(EVERY)).await;
    let carol = world.member("carol", None).await;
    // Alice and bob joined before the restart, so no webhook of theirs ever reached this process.
    sfu.seat(&[alice.id, bob.id, carol.id]);

    world.join(carol.id).await;

    let frame = notice(&mut dave.ws, HEARS).await.expect("dave is told");
    assert_eq!(frame["activity"], "joined");
    assert!(notice(&mut alice.ws, SILENT).await.is_none());
    assert!(notice(&mut bob.ws, SILENT).await.is_none());
}

#[tokio::test]
async fn the_first_join_after_a_restart_into_an_empty_room_still_starts_the_call() {
    let sfu = RecordingRoomService::default();
    let sfu_url = spawn_sfu(sfu.clone()).await;
    let world = World::on(&sfu_url).await;
    let mut bob = world.member("bob", Some(EVERY)).await;
    let alice = world.member("alice", None).await;
    sfu.seat(&[alice.id]);

    world.join(alice.id).await;

    let frame = notice(&mut bob.ws, HEARS).await.expect("bob is told");
    assert_eq!(frame["activity"], "call_started");
}
