// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! When the visibility read fails, voice frames and call-audio rosters stay silent about the member
//! instead of naming them, the same way typing does; and the voice INFO log lines carry no user id.

use std::time::Duration;

use serde_json::json;
use slimm_server::call_audio::CallAudioView;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::hub::Hub;
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::presence::Visibility;
use slimm_server::store::Store;
use slimm_server::voice::{VoiceService, room_for_channel};
use tower::ServiceExt;

use crate::support;
use support::livekit_webhook::webhook_request;
use support::ws::{connect, serve, ticket_only, wait_for_frame};

const API_KEY: &str = "APItestkey";
const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

async fn store_with_pool(prefix: &str) -> (Store, sqlx::SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new(prefix);
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

async fn break_visibility_reads(pool: &sqlx::SqlitePool) {
    sqlx::query(
        "ALTER TABLE users RENAME COLUMN presence_visibility TO presence_visibility_broken",
    )
    .execute(pool)
    .await
    .expect("break the column the store queries by name");
}

fn view_naming(users: &[UserId], asked_by: UserId) -> CallAudioView {
    let ids: Vec<String> = users.iter().map(ToString::to_string).collect();
    CallAudioView {
        module_id: "m".into(),
        module_name: "M".into(),
        purpose: String::new(),
        keeps: String::new(),
        status: "asking",
        asked_by: Some(asked_by.to_string()),
        included: ids.clone(),
        pending: ids,
        expires_at_ms: 0,
        full: false,
        mode: None,
        transcript_id: None,
        transcript: false,
        automatic: false,
    }
}

#[tokio::test]
async fn a_failed_visibility_read_leaves_everyone_out_of_the_call_audio_view() {
    let (store, pool, _guard) = store_with_pool("slimm-call-audio-read-error").await;
    let viewer = store.create_user("viewer", "viewer").await.unwrap().id;
    let other = store.create_user("other", "other").await.unwrap().id;
    break_visibility_reads(&pool).await;

    let mut view = view_naming(&[viewer, other], other);
    view.hide_hidden(&store, &Hub::new(), viewer).await;

    assert_eq!(view.included, vec![viewer.to_string()]);
    assert_eq!(view.pending, vec![viewer.to_string()]);
    assert_eq!(view.asked_by.as_deref(), Some(""));
}

#[tokio::test]
async fn a_failed_visibility_read_withholds_the_voice_join_frame() {
    let (store, pool, _guard) = store_with_pool("slimm-voice-read-error").await;
    store
        .create_role("everyone", Permissions::VIEW_CHANNEL, true)
        .await
        .unwrap();
    let channel = store.create_channel("lounge", "voice").await.unwrap().id;
    let state = support::app::builder(store.clone())
        .voice(VoiceService::for_test(
            "http://127.0.0.1:1",
            API_KEY,
            API_SECRET,
        ))
        .build();
    let joiner = store.create_user("joiner", "joiner").await.unwrap().id;
    store
        .set_presence_visibility(joiner, Visibility::Hidden)
        .await
        .unwrap();
    let ticket = ticket_only(&store, "watcher").await;
    break_visibility_reads(&pool).await;
    let addr = serve(state.clone()).await;
    let mut watcher = connect(addr, &ticket).await;

    let body = json!({
        "event": "participant_joined",
        "room": { "name": room_for_channel(channel) },
        "participant": { "identity": joiner.to_string(), "sid": "PA_1" },
    });
    let response = slimm_server::http::router(state)
        .oneshot(webhook_request(body, API_KEY, API_SECRET))
        .await
        .unwrap();
    assert_eq!(response.status(), 204);

    let frame = wait_for_frame(
        &mut watcher,
        "voice.participant_joined",
        Duration::from_millis(500),
    )
    .await;
    assert!(
        frame.is_none(),
        "a failed read must not name the member: {frame:?}"
    );
}

/// The text of the macro call from its opening `(` to the matching `)`.
fn macro_call(from: &str) -> &str {
    let mut depth = 0usize;
    for (at, byte) in from.bytes().enumerate() {
        match byte {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth == 0 {
                    return &from[..=at];
                }
            }
            _ => {}
        }
    }
    from
}

/// A downloadable default-mode log must not tie a member to a call, so no INFO line there names one.
#[test]
fn voice_info_log_lines_carry_no_user_id() {
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = support::rust_files_under(&src.join("http/voice"));
    files.extend(support::rust_files_under(&src.join("voice")));
    files.push(src.join("sweeps/voice.rs"));
    let mut offenders = Vec::new();
    for file in files {
        let code = support::code_only(&std::fs::read_to_string(&file).unwrap());
        for (at, _) in code.match_indices("tracing::info!(") {
            let call = macro_call(&code[at..]);
            if call.contains("user_id") || call.contains("caller_id") {
                offenders.push(format!("{}: {}", file.display(), call.replace('\n', " ")));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "INFO lines naming a user: {offenders:#?}"
    );
}
