// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The soundboard (decision 0118): clip management, the play permission, the
//! per-caller rate limit, and the fan-out reaching only the people in the call.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::http::{self, AppState};
use slimm_server::ids::ChannelId;
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::soundboard;
use slimm_server::store::{MAX_SOUNDBOARD_CLIPS, Store};
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

use crate::support;
use support::app::{Account, json_body_or_null, register_account, request_bearer};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};
use support::ws::{assert_no_frame_of_type, connect, read_frame_of_type, serve, settle};

/// A PCM wav of `data_len` bytes at 8000 Hz mono 16-bit, so 16000 bytes is one second.
fn wav(data_len: usize) -> Vec<u8> {
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&[1, 0, 1, 0]);
    out.extend_from_slice(&8000u32.to_le_bytes());
    out.extend_from_slice(&16_000u32.to_le_bytes());
    out.extend_from_slice(&[2, 0, 16, 0]);
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    out.extend(std::iter::repeat_n(7u8, data_len));
    out
}

/// A clip body that is unique per `n`, so the 48-clip test does not dedupe into one blob.
fn tone(n: usize) -> Vec<u8> {
    let mut bytes = wav(1600);
    bytes[44..48].copy_from_slice(&(n as u32).to_le_bytes());
    bytes
}

struct Rig {
    store: Store,
    state: AppState,
    router: Router,
    room: RecordingRoomService,
    admin: Account,
    channel: String,
    channel_id: ChannelId,
    _db: support::TestDbGuard,
}

async fn rig() -> Rig {
    let room = RecordingRoomService::default();
    let sfu = spawn_sfu(room.clone()).await;
    let (store, db) = support::new_store("slimm-soundboard").await;
    let admin = register_account(&store, "admin").await;
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let voice = VoiceService::for_test(&sfu, "key", "a-secret-at-least-32-chars-long!");
    let state = support::app::builder(store.clone()).voice(voice).build();
    Rig {
        store,
        router: http::router(state.clone()),
        state,
        room,
        admin,
        channel: channel.id.to_string(),
        channel_id: channel.id,
        _db: db,
    }
}

impl Rig {
    async fn member(&self, name: &str) -> Account {
        register_account(&self.store, name).await
    }

    async fn upload(&self, token: &str, name: &str, bytes: Vec<u8>) -> (StatusCode, Value) {
        let request = Request::builder()
            .method("POST")
            .uri(format!("/soundboard?name={name}"))
            .header("authorization", format!("Bearer {token}"))
            .body(Body::from(bytes))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        (response.status(), json_body_or_null(response).await)
    }

    async fn send(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        support::app::call_as(&self.router, method, uri, token, body).await
    }

    async fn play(&self, token: &str, clip: &str) -> (StatusCode, Value) {
        let uri = format!("/channels/{}/voice/soundboard/{clip}/play", self.channel);
        self.send("POST", &uri, token, None).await
    }

    async fn clip(&self, name: &str) -> String {
        let (status, body) = self.upload(&self.admin.token, name, tone(1)).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }
}

#[tokio::test]
async fn a_manager_adds_renames_and_removes_clips_and_anyone_can_list_and_fetch() {
    let rig = rig().await;
    let member = rig.member("member").await;

    let (status, body) = rig
        .upload(&rig.admin.token, "Air%20Horn", wav(16_000))
        .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(body["name"], "Air Horn");
    assert_eq!(body["duration_ms"], 1000);
    let id = body["id"].as_str().unwrap().to_owned();

    let (_, listed) = rig.send("GET", "/soundboard", &member.token, None).await;
    assert_eq!(listed.as_array().unwrap().len(), 1);
    let audio = rig
        .router
        .clone()
        .oneshot(request_bearer(
            "GET",
            &format!("/soundboard/{id}/audio"),
            &member.token,
        ))
        .await
        .unwrap();
    assert_eq!(audio.status(), StatusCode::OK);
    assert_eq!(audio.headers()["content-type"], "audio/wav");

    let (status, renamed) = rig
        .send(
            "PATCH",
            &format!("/soundboard/{id}"),
            &rig.admin.token,
            Some(json!({"name": "Honk"})),
        )
        .await;
    assert_eq!(
        (status, renamed["name"].as_str()),
        (StatusCode::OK, Some("Honk"))
    );

    let uri = format!("/soundboard/{id}");
    assert_eq!(
        rig.send("DELETE", &uri, &rig.admin.token, None).await.0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        rig.send("DELETE", &uri, &rig.admin.token, None).await.0,
        StatusCode::NO_CONTENT
    );
    let (_, after) = rig.send("GET", "/soundboard", &member.token, None).await;
    assert!(after.as_array().unwrap().is_empty());
}

#[tokio::test]
async fn managing_clips_needs_the_permission_custom_emoji_management_uses() {
    let rig = rig().await;
    let member = rig.member("member").await;
    let id = rig.clip("honk").await;

    let (upload, _) = rig.upload(&member.token, "mine", wav(1600)).await;
    let (rename, _) = rig
        .send(
            "PATCH",
            &format!("/soundboard/{id}"),
            &member.token,
            Some(json!({"name": "x"})),
        )
        .await;
    let (delete, _) = rig
        .send("DELETE", &format!("/soundboard/{id}"), &member.token, None)
        .await;

    assert_eq!(
        (upload, rename, delete),
        (
            StatusCode::FORBIDDEN,
            StatusCode::FORBIDDEN,
            StatusCode::FORBIDDEN
        )
    );
    assert_eq!(rig.store.list_sound_clips().await.unwrap().len(), 1);
}

#[tokio::test]
async fn uploads_are_held_to_the_size_length_type_name_and_count_limits() {
    let rig = rig().await;
    let admin = &rig.admin.token;

    let (too_long, body) = rig.upload(admin, "long", wav(16_000 * 6)).await;
    assert_eq!(too_long, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["error"], "clip must be at most 5 seconds");
    let (at_limit, _) = rig.upload(admin, "five", wav(16_000 * 5)).await;
    assert_eq!(at_limit, StatusCode::CREATED);

    let mut heavy = wav(16_000);
    heavy.resize(513 * 1024, 0);
    let (too_big, _) = rig.upload(admin, "heavy", heavy).await;
    assert_eq!(too_big, StatusCode::PAYLOAD_TOO_LARGE);

    let (not_audio, _) = rig.upload(admin, "text", b"just some text".to_vec()).await;
    assert_eq!(not_audio, StatusCode::BAD_REQUEST);
    let (empty, _) = rig.upload(admin, "empty", Vec::new()).await;
    assert_eq!(empty, StatusCode::BAD_REQUEST);
    let (unnamed, _) = rig.upload(admin, "%20%20", wav(1600)).await;
    assert_eq!(unnamed, StatusCode::BAD_REQUEST);

    let (dup, _) = rig.upload(admin, "FIVE", wav(1600)).await;
    assert_eq!(dup, StatusCode::CONFLICT);
    assert_eq!(rig.store.list_sound_clips().await.unwrap().len(), 1);
}

#[tokio::test]
async fn a_space_holds_at_most_48_clips() {
    let rig = rig().await;
    let (root, _dir) = support::TestDirGuard::new("slimm-soundboard-media");
    let media = Media::new(&root, 10 * 1024 * 1024).unwrap();
    for n in 0..MAX_SOUNDBOARD_CLIPS as usize {
        soundboard::add_clip(
            &rig.store,
            &media,
            &format!("clip{n}"),
            tone(n),
            rig.admin.id,
        )
        .await
        .unwrap_or_else(|err| panic!("clip {n}: {err:?}"));
    }
    let (status, _) = rig
        .upload(&rig.admin.token, "one-too-many", tone(999))
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_new_member_holds_use_soundboard_and_a_channel_deny_takes_it_away() {
    let rig = rig().await;
    let member = rig.member("member").await;
    rig.room.seat(&[member.id]);
    let id = rig.clip("honk").await;

    let held = rig
        .store
        .permissions_in_channel(member.id, rig.channel_id)
        .await
        .unwrap();
    assert!(held.contains(Permissions::USE_SOUNDBOARD));

    rig.store
        .set_member_overwrite(
            rig.channel_id,
            member.id,
            Permissions::NONE,
            Permissions::USE_SOUNDBOARD,
        )
        .await
        .unwrap();
    let (status, _) = rig.play(&member.token, &id).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn someone_who_may_not_speak_in_the_call_cannot_play() {
    let rig = rig().await;
    let member = rig.member("member").await;
    rig.room.seat(&[member.id]);
    let id = rig.clip("honk").await;
    rig.store
        .set_member_overwrite(
            rig.channel_id,
            member.id,
            Permissions::NONE,
            Permissions::SPEAK,
        )
        .await
        .unwrap();
    let (status, _) = rig.play(&member.token, &id).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn one_play_per_person_every_three_seconds() {
    let rig = rig().await;
    let member = rig.member("member").await;
    let other = rig.member("other").await;
    rig.room.seat(&[member.id, other.id]);
    let id = rig.clip("honk").await;

    let (first, _) = rig.play(&member.token, &id).await;
    let (second, body) = rig.play(&member.token, &id).await;
    let (someone_else, _) = rig.play(&other.token, &id).await;

    assert_eq!(first, StatusCode::NO_CONTENT);
    assert_eq!(second, StatusCode::TOO_MANY_REQUESTS);
    assert!(body["retry_after_seconds"].as_i64().unwrap() <= 3);
    assert_eq!(
        someone_else,
        StatusCode::NO_CONTENT,
        "the limit is per person"
    );
}

#[tokio::test]
async fn only_someone_in_the_call_can_play_and_only_the_call_hears_it() {
    let rig = rig().await;
    let (alice, bob, carol) = (
        rig.member("alice").await,
        rig.member("bob").await,
        rig.member("carol").await,
    );
    let id = rig.clip("honk").await;
    rig.room.seat(&[alice.id, bob.id]);

    let (outside, _) = rig.play(&carol.token, &id).await;
    assert_eq!(
        outside,
        StatusCode::FORBIDDEN,
        "a watcher outside the call cannot play"
    );

    let addr = serve(rig.state.clone()).await;
    let mut sockets = Vec::new();
    for account in [&alice, &bob, &carol] {
        let ctx = rig
            .store
            .authenticate(&account.token)
            .await
            .unwrap()
            .unwrap();
        let (ticket, _) = rig.store.mint_ws_ticket(&ctx).await.unwrap();
        sockets.push(connect(addr, &ticket).await);
    }
    assert_eq!(rig.play(&alice.token, &id).await.0, StatusCode::NO_CONTENT);

    let mut sockets = sockets.into_iter();
    let (mut a, mut b, mut c) = (
        sockets.next().unwrap(),
        sockets.next().unwrap(),
        sockets.next().unwrap(),
    );
    for socket in [&mut a, &mut b] {
        let frame = read_frame_of_type(socket, "soundboard.played").await;
        assert_eq!(frame["clip_id"], id);
        assert_eq!(frame["player_id"], alice.id.to_string());
        assert_eq!(frame["channel_id"], rig.channel);
        settle(socket).await;
        assert_no_frame_of_type(socket, "soundboard.played").await;
    }
    settle(&mut c).await;
    assert_no_frame_of_type(&mut c, "soundboard.played").await;
}

#[tokio::test]
async fn playing_a_clip_that_does_not_exist_is_a_404() {
    let rig = rig().await;
    let member = rig.member("member").await;
    rig.room.seat(&[member.id]);
    let (status, _) = rig
        .play(&member.token, &uuid::Uuid::now_v7().to_string())
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
