// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A soundboard clip's emoji: the encoding reactions accept, a `:shortcode:`
//! stored as the custom emoji's id, set and cleared on the update route, and
//! cleared when its custom emoji is deleted.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::store::Store;
use tower::ServiceExt;

use super::soundboard::tone;
use crate::support;
use support::app::{Account, app, call_as, json_body_or_null, register_account};

const POSTAL_HORN: &str = "\u{1F4EF}";
const TRUMPET: &str = "\u{1F3BA}";

struct Rig {
    store: Store,
    router: Router,
    admin: Account,
    _db: support::TestDbGuard,
}

async fn rig() -> Rig {
    let (store, db) = support::new_store("slimm-soundboard-emoji").await;
    let admin = register_account(&store, "admin").await;
    Rig {
        router: app(store.clone()),
        store,
        admin,
        _db: db,
    }
}

fn encoded(text: &str) -> String {
    url::form_urlencoded::byte_serialize(text.as_bytes()).collect()
}

impl Rig {
    async fn raw(&self, uri: &str, bytes: Vec<u8>) -> (StatusCode, Value) {
        let request = Request::builder()
            .method("POST")
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.admin.token))
            .body(Body::from(bytes))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        (response.status(), json_body_or_null(response).await)
    }

    async fn upload(&self, name: &str, emoji: Option<&str>, n: usize) -> (StatusCode, Value) {
        let mut uri = format!("/soundboard?name={name}");
        if let Some(emoji) = emoji {
            uri.push_str(&format!("&emoji={}", encoded(emoji)));
        }
        self.raw(&uri, tone(n)).await
    }

    async fn custom_emoji(&self, name: &str) -> String {
        let (status, body) = self
            .raw(&format!("/emoji?name={name}"), support::images::small_png())
            .await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["id"].as_str().unwrap().to_owned()
    }

    /// Sent with a content-length, as a real client sends it, so the audit log reads the fields.
    async fn patch(&self, id: &str, body: Value) -> (StatusCode, Value) {
        let body = body.to_string();
        let request = Request::builder()
            .method("PATCH")
            .uri(format!("/soundboard/{id}"))
            .header("authorization", format!("Bearer {}", self.admin.token))
            .header("content-type", "application/json")
            .header("content-length", body.len())
            .body(Body::from(body))
            .unwrap();
        let response = self.router.clone().oneshot(request).await.unwrap();
        (response.status(), json_body_or_null(response).await)
    }

    async fn listed_emoji(&self) -> Vec<Value> {
        let (status, body) =
            call_as(&self.router, "GET", "/soundboard", &self.admin.token, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body.as_array()
            .unwrap()
            .iter()
            .map(|clip| clip["emoji"].clone())
            .collect()
    }
}

#[tokio::test]
async fn a_clip_is_created_with_a_standard_emoji_a_custom_id_or_a_shortcode() {
    let rig = rig().await;
    let honk = rig.custom_emoji("honk").await;

    let (status, standard) = rig.upload("horn", Some(POSTAL_HORN), 1).await;
    assert_eq!(status, StatusCode::CREATED, "{standard}");
    let (status, by_id) = rig.upload("by_id", Some(&honk), 2).await;
    assert_eq!(status, StatusCode::CREATED, "{by_id}");
    let (status, by_name) = rig.upload("by_name", Some(":honk:"), 3).await;
    assert_eq!(status, StatusCode::CREATED, "{by_name}");
    let (status, none) = rig.upload("plain", None, 4).await;
    assert_eq!(status, StatusCode::CREATED, "{none}");

    assert_eq!(standard["emoji"], POSTAL_HORN);
    assert_eq!(by_id["emoji"], honk.as_str());
    assert_eq!(
        by_name["emoji"],
        honk.as_str(),
        "a shortcode is stored as the id"
    );
    assert!(none["emoji"].is_null());
    assert_eq!(
        rig.listed_emoji().await,
        [json!(POSTAL_HORN), json!(honk), json!(honk), Value::Null]
    );
}

#[tokio::test]
async fn an_emoji_reactions_would_refuse_or_an_unknown_custom_one_is_a_400() {
    let rig = rig().await;
    let unknown_id = uuid::Uuid::now_v7().to_string();
    let two = format!("{POSTAL_HORN}{TRUMPET}");
    for (n, bad) in ["honk", two.as_str(), ":nobody:", unknown_id.as_str(), ""]
        .into_iter()
        .enumerate()
    {
        let (status, body) = rig.upload(&format!("clip{n}"), Some(bad), n).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad:?}: {body}");
    }
    assert!(rig.store.list_sound_clips().await.unwrap().is_empty());
    assert_eq!(
        rig.store.total_attachment_bytes().await.unwrap(),
        0,
        "a refused emoji stores no bytes"
    );
}

#[tokio::test]
async fn the_update_route_sets_clears_and_leaves_the_emoji() {
    let rig = rig().await;
    let honk = rig.custom_emoji("honk").await;
    let (_, clip) = rig.upload("horn", Some(POSTAL_HORN), 1).await;
    let id = clip["id"].as_str().unwrap();

    let (status, renamed) = rig.patch(id, json!({ "name": "Horn" })).await;
    assert_eq!(status, StatusCode::OK, "{renamed}");
    assert_eq!(
        (&renamed["name"], &renamed["emoji"]),
        (&json!("Horn"), &json!(POSTAL_HORN)),
        "absent leaves the emoji"
    );

    let (status, set) = rig.patch(id, json!({ "emoji": TRUMPET })).await;
    assert_eq!(status, StatusCode::OK, "{set}");
    assert_eq!(
        (&set["name"], &set["emoji"]),
        (&json!("Horn"), &json!(TRUMPET))
    );

    let (_, custom) = rig.patch(id, json!({ "emoji": ":Honk:" })).await;
    assert_eq!(
        custom["emoji"],
        honk.as_str(),
        "a shortcode matches the way the client resolves one, ignoring case"
    );

    let (status, cleared) = rig.patch(id, json!({ "emoji": null })).await;
    assert_eq!(status, StatusCode::OK, "{cleared}");
    assert!(cleared["emoji"].is_null(), "{cleared}");
    assert_eq!(rig.listed_emoji().await, [Value::Null]);

    let (bad, _) = rig.patch(id, json!({ "emoji": "honk" })).await;
    let (nothing, _) = rig.patch(id, json!({})).await;
    assert_eq!(
        (bad, nothing),
        (StatusCode::BAD_REQUEST, StatusCode::BAD_REQUEST)
    );
}

#[tokio::test]
async fn deleting_a_custom_emoji_clears_it_from_the_clips_showing_it() {
    let rig = rig().await;
    let honk = rig.custom_emoji("honk").await;
    let kept = rig.custom_emoji("kept").await;
    rig.upload("one", Some(&honk), 1).await;
    rig.upload("two", Some(":honk:"), 2).await;
    rig.upload("three", Some(&kept), 3).await;
    rig.upload("four", Some(POSTAL_HORN), 4).await;

    let uri = format!("/emoji/{honk}");
    let (status, _) = call_as(&rig.router, "DELETE", &uri, &rig.admin.token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    assert_eq!(
        rig.listed_emoji().await,
        [Value::Null, Value::Null, json!(kept), json!(POSTAL_HORN)]
    );
}

#[tokio::test]
async fn an_emoji_change_is_audited_on_the_rename_entry_with_its_field() {
    let rig = rig().await;
    let (_, clip) = rig.upload("horn", None, 1).await;
    let id = clip["id"].as_str().unwrap();
    rig.patch(id, json!({ "emoji": TRUMPET })).await;

    let (status, log) = call_as(
        &rig.router,
        "GET",
        "/space/audit-log",
        &rig.admin.token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{log}");
    let latest = &log[0];
    assert_eq!(latest["action"], "soundboard.rename");
    assert_eq!(latest["target_id"], id);
    assert_eq!(latest["detail"]["fields"], json!(["emoji"]));
}
