// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Linking Steam through OpenID 2.0 against a local fake of Steam: only a
//! response Steam vouches for, for our own return address, becomes a link.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::{Extension, Router};
use slimm_server::http::steam_api::SteamApi;
use slimm_server::http::steam_link::SteamLinks;
use slimm_server::http::{self};
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::{json_body, request_authed};
use support::discord_link::text_body;
use support::steam::{self, STEAM_ID};

const REDIRECT: &str = "https://slim.example/links/steam/callback";

async fn app_with_steam(store: Store) -> Router {
    let fake = steam::spawn().await;
    let api = SteamApi::with_bases("key", &fake.base, &fake.base).unwrap();
    let links =
        SteamLinks::with_endpoints(REDIRECT, &format!("{}/openid/login", fake.base), api).unwrap();
    http::router(support::app::state(store)).layer(Extension(links))
}

async fn ada(name: &str) -> (Store, String, impl Drop) {
    let (store, guard) = support::new_store(name).await;
    let user = store.create_user("ada", "Ada").await.unwrap();
    let token = store
        .open_session(user.id, "laptop")
        .await
        .unwrap()
        .access_token;
    (store, token, guard)
}

async fn start(app: &Router, token: &str) -> (String, String) {
    let response = app
        .clone()
        .oneshot(request_authed("POST", "/me/links/steam/start", token, None))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let url = url::Url::parse(json_body(response).await["url"].as_str().unwrap()).unwrap();
    let pairs: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
    assert_eq!(url.host_str(), Some("steamcommunity.com"));
    assert_eq!(pairs["openid.mode"], "checkid_setup");
    assert_eq!(pairs["openid.realm"], "https://slim.example");
    assert!(pairs["openid.identity"].ends_with("identifier_select"));
    let return_to = pairs["openid.return_to"].clone();
    let state = return_to.split("state=").nth(1).unwrap().to_owned();
    (state, return_to)
}

async fn callback(
    app: &Router,
    state: &str,
    params: Vec<(String, String)>,
) -> axum::response::Response {
    let mut url = url::Url::parse("http://x/links/steam/callback").unwrap();
    url.query_pairs_mut().append_pair("state", state);
    for (k, v) in params {
        url.query_pairs_mut().append_pair(&k, &v);
    }
    let uri = format!("{}?{}", url.path(), url.query().unwrap());
    app.clone()
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap()
}

fn claimed(id: &str) -> String {
    format!("https://steamcommunity.com/openid/id/{id}")
}

async fn links_of(app: &Router, token: &str) -> serde_json::Value {
    let response = app
        .clone()
        .oneshot(request_authed("GET", "/me/links", token, None))
        .await
        .unwrap();
    json_body(response).await
}

#[tokio::test]
async fn a_vouched_sign_in_links_steam_through_the_handoff() {
    let (store, token, _guard) = ada("slimm-steam-link").await;
    let app = app_with_steam(store).await;
    let (state, return_to) = start(&app, &token).await;

    let params = steam::sign_in_params(&return_to, &claimed(STEAM_ID), "goodsig");
    let response = callback(&app, &state, params).await;
    assert_eq!(response.status(), StatusCode::OK);
    let html = text_body(response).await;
    let marker = "slimm://steam-link?code=";
    let from = html.find(marker).unwrap() + marker.len();
    let code: String = html[from..]
        .chars()
        .take_while(char::is_ascii_alphanumeric)
        .collect();
    assert_eq!(links_of(&app, &token).await, serde_json::json!([]));

    let done = app
        .clone()
        .oneshot(request_authed(
            "POST",
            "/me/links/steam/complete",
            &token,
            Some(serde_json::json!({ "code": code })),
        ))
        .await
        .unwrap();
    assert_eq!(done.status(), StatusCode::OK);
    let mine = links_of(&app, &token).await;
    assert_eq!(mine[0]["provider"], "steam");
    assert_eq!(mine[0]["username"], "Ada on Steam");
    assert_eq!(mine[0]["share_activity"], false);
}

#[tokio::test]
async fn a_forged_identity_is_refused_even_when_the_signature_checks_out() {
    let (store, token, _guard) = ada("slimm-steam-forged").await;
    let app = app_with_steam(store).await;
    for forged in [
        "https://evil.example/openid/id/76561198000000001",
        "https://steamcommunity.com/openid/id/123",
        "https://steamcommunity.com.evil.example/openid/id/76561198000000001",
    ] {
        let (state, return_to) = start(&app, &token).await;
        let params = steam::sign_in_params(&return_to, forged, "goodsig");
        let response = callback(&app, &state, params).await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{forged}");
        assert!(!text_body(response).await.contains("slimm://steam-link"));
    }
}

#[tokio::test]
async fn a_foreign_return_to_is_refused() {
    let (store, token, _guard) = ada("slimm-steam-return-to").await;
    let app = app_with_steam(store).await;
    let (state, _) = start(&app, &token).await;
    let params = steam::sign_in_params(
        "https://evil.example/links/steam/callback?state=x",
        &claimed(STEAM_ID),
        "goodsig",
    );
    let response = callback(&app, &state, params).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn steam_not_vouching_is_refused() {
    let (store, token, _guard) = ada("slimm-steam-unverified").await;
    let app = app_with_steam(store).await;
    let (state, return_to) = start(&app, &token).await;
    let params = steam::sign_in_params(&return_to, &claimed(STEAM_ID), "badsig");
    let response = callback(&app, &state, params).await;
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn a_state_works_once() {
    let (store, token, _guard) = ada("slimm-steam-state").await;
    let app = app_with_steam(store).await;
    let (state, return_to) = start(&app, &token).await;
    let params = steam::sign_in_params(&return_to, &claimed(STEAM_ID), "goodsig");
    assert_eq!(
        callback(&app, &state, params.clone()).await.status(),
        StatusCode::OK
    );
    assert_eq!(
        callback(&app, &state, params).await.status(),
        StatusCode::BAD_REQUEST
    );
    let forged = "a".repeat(43);
    assert_eq!(
        callback(&app, &forged, vec![]).await.status(),
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn without_a_key_the_feature_is_off() {
    let (store, token, _guard) = ada("slimm-steam-off").await;
    let app = http::router(support::app::state(store));
    let response = app
        .clone()
        .oneshot(request_authed(
            "POST",
            "/me/links/steam/start",
            &token,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NOT_IMPLEMENTED);
    let version = app
        .oneshot(
            Request::builder()
                .uri("/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(json_body(version).await["steam_link_enabled"], false);
}

#[tokio::test]
async fn the_version_advertises_steam_when_configured() {
    let (store, _token, _guard) = ada("slimm-steam-on").await;
    let app = app_with_steam(store).await;
    let version = app
        .oneshot(
            Request::builder()
                .uri("/version")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(json_body(version).await["steam_link_enabled"], true);
}

#[tokio::test]
async fn sharing_needs_a_link_and_unlinking_forgets_it() {
    let (store, token, _guard) = ada("slimm-steam-sharing").await;
    let app = app_with_steam(store).await;
    let share = |enabled: bool| {
        request_authed(
            "PUT",
            "/me/links/steam/sharing",
            &token,
            Some(serde_json::json!({ "enabled": enabled })),
        )
    };
    assert_eq!(
        app.clone().oneshot(share(true)).await.unwrap().status(),
        StatusCode::NOT_FOUND
    );
    let (state, return_to) = start(&app, &token).await;
    let params = steam::sign_in_params(&return_to, &claimed(STEAM_ID), "goodsig");
    let html = text_body(callback(&app, &state, params).await).await;
    let marker = "slimm://steam-link?code=";
    let from = html.find(marker).unwrap() + marker.len();
    let code: String = html[from..]
        .chars()
        .take_while(char::is_ascii_alphanumeric)
        .collect();
    let body = serde_json::json!({ "code": code });
    app.clone()
        .oneshot(request_authed(
            "POST",
            "/me/links/steam/complete",
            &token,
            Some(body),
        ))
        .await
        .unwrap();

    assert_eq!(
        app.clone().oneshot(share(true)).await.unwrap().status(),
        StatusCode::NO_CONTENT
    );
    assert_eq!(links_of(&app, &token).await[0]["share_activity"], true);
    let gone = app
        .clone()
        .oneshot(request_authed("DELETE", "/me/links/steam", &token, None))
        .await
        .unwrap();
    assert_eq!(gone.status(), StatusCode::NO_CONTENT);
    assert_eq!(links_of(&app, &token).await, serde_json::json!([]));
}
