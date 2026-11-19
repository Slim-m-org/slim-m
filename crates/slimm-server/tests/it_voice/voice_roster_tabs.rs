// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every browser tab of one profile shares one session, so the roster tells a
//! call apart by the tab that joined it: a second tab is warned before its join
//! takes the call from the first, and a reloaded tab still owns its leftover.

use axum::http::StatusCode;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::voice::{DEVICE_ATTRIBUTE, VoiceService};
use tower::ServiceExt;

use crate::support;
use support::app::{json_body, request_bare as request};
use support::fake_sfu::{RecordingRoomService, spawn_sfu};

async fn call(app: &axum::Router, method: &str, uri: &str, token: &str) -> Value {
    let response = app
        .clone()
        .oneshot(request(method, uri, Some(token)))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{method} {uri}");
    json_body(response).await
}

fn device_shown(token: &str) -> String {
    let payload = token.split('.').nth(1).expect("a jwt has three parts");
    let claims: Value = serde_json::from_slice(&BASE64URL.decode(payload).unwrap()).unwrap();
    claims["attributes"][DEVICE_ATTRIBUTE]
        .as_str()
        .unwrap()
        .to_owned()
}

/// One signed-in browser session beside a voice channel, over a fake SFU.
struct Browser {
    app: axum::Router,
    token: String,
    channel: String,
    account: String,
    room: RecordingRoomService,
    _guard: support::TestDbGuard,
}

async fn browser(prefix: &str) -> Browser {
    let (store, guard) = support::new_store(prefix).await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL.union(Permissions::CONNECT),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "voice").await.unwrap();
    let account = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    let session = store.open_session(account.id, "browser").await.unwrap();
    let room = RecordingRoomService::default();
    let voice = VoiceService::for_test(
        &spawn_sfu(room.clone()).await,
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    );
    Browser {
        app: support::app::builder(store.clone()).voice(voice).router(),
        token: session.access_token,
        channel: channel.id.to_string(),
        account: account.id.to_string(),
        room,
        _guard: guard,
    }
}

#[tokio::test]
async fn a_second_tab_of_one_session_sees_the_first_tabs_call_as_elsewhere() {
    let Browser {
        app,
        token,
        channel,
        account,
        room,
        _guard,
    } = browser("slimm-voice-roster-tabs").await;

    let joined = call(
        &app,
        "POST",
        &format!("/channels/{channel}/voice/token?tab=f1"),
        &token,
    )
    .await;
    room.seat_listing(vec![json!({
        "identity": account,
        "name": "alice",
        "attributes": { (DEVICE_ATTRIBUTE): device_shown(joined["token"].as_str().unwrap()) },
    })]);

    let this_device = |tab: &'static str| {
        let app = app.clone();
        let token = token.clone();
        let uri = format!("/channels/{channel}/voice/roster?tab={tab}");
        async move { call(&app, "GET", &uri, &token).await["participants"][0]["this_device"].clone() }
    };
    assert_eq!(
        (this_device("5e").await, this_device("f1").await),
        (json!(false), json!(true)),
        "the second tab is told of the first tab's call, and the first tab, reloaded, still owns it"
    );
}

#[tokio::test]
async fn a_tab_id_is_lowercase_hex_up_to_64_characters_as_the_schema_says() {
    let Browser {
        app,
        token,
        channel,
        _guard,
        ..
    } = browser("slimm-voice-tab-shape").await;
    let status = |tab: String| {
        let app = app.clone();
        let uri = format!("/channels/{channel}/voice/roster?tab={tab}");
        let token = token.clone();
        async move {
            app.oneshot(request("GET", &uri, Some(&token)))
                .await
                .unwrap()
                .status()
        }
    };
    let accented = "%C3%A9".repeat(30);
    assert_eq!(
        (
            status("0f".repeat(32)).await,
            status("0f".repeat(32) + "0").await,
            status("ABCDEF".to_owned()).await,
            status(accented).await,
        ),
        (
            StatusCode::OK,
            StatusCode::BAD_REQUEST,
            StatusCode::BAD_REQUEST,
            StatusCode::BAD_REQUEST,
        ),
        "64 hex characters, one too many, uppercase, and 30 accented characters"
    );
}
