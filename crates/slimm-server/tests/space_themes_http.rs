// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Space theme store over HTTP (decision 0106): who may publish, remove
//! and set the default, what the server refuses, and what a listing carries.
//!
//! The first `register` claims the deployment and becomes the administrator; a
//! second is an ordinary member.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, json_body_or_null, register_token as register, request_json};

fn theme(name: &str) -> Value {
    json!({
        "format": "slimm-theme", "version": 1, "name": name, "author": "me",
        "base": "dark", "brightness": "dark",
        "tokens": {
            "surfaceSunken": "#0B0D10", "surfaceBase": "#12151A", "surfaceRaised": "#1C2027",
            "borderSubtle": "#2A2F38", "borderStrong": "#7C8696",
            "textPrimary": "#EEF1F5", "textSecondary": "#A9B2BF", "textDisabled": "#5E6672",
            "accent": "#7FB2FF", "accentFill": "#7FB2FF", "accentOn": "#06101F",
            "accentSoft": "#1B2A44", "accentRing": "#407FB2FF", "focusRing": "#7FB2FF",
            "dangerText": "#F0958A", "dangerBorder": "#D0675B",
            "warnText": "#E0B050", "warnSoft": "#1AE0B050", "stripe": "#12A9B2BF"
        }
    })
}

async fn send(
    app: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"));
    let body = match body {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            Body::from(value.to_string())
        }
        None => Body::empty(),
    };
    let response = app
        .clone()
        .oneshot(builder.body(body).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let value = if status == StatusCode::NO_CONTENT || status.is_client_error() {
        Value::Null
    } else {
        json_body(response).await
    };
    (status, value)
}

#[tokio::test]
async fn a_member_publishes_and_everyone_lists_it_with_the_author() {
    let (store, _guard) = support::new_store("slimm-themes-publish").await;
    let app = app(store.clone());
    let _admin = register(&store, "admin").await;
    let member = register(&store, "member").await;

    let (status, created) = send(&app, "POST", "/space/themes", &member, Some(theme("Dusk"))).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["name"], "Dusk");
    assert_eq!(created["has_picture"], false);

    let (_, listed) = send(&app, "GET", "/space/themes", &member, None).await;
    assert_eq!(listed["themes"].as_array().unwrap().len(), 1);
    assert_eq!(listed["themes"][0]["theme"]["base"], "dark");
    assert!(listed["default_theme_id"].is_null());
}

#[tokio::test]
async fn an_invalid_file_is_refused_naming_the_problem() {
    let (store, _guard) = support::new_store("slimm-themes-invalid").await;
    let app = app(store.clone());
    let member = register(&store, "admin").await;
    let mut bad = theme("Low");
    bad["tokens"]["textPrimary"] = json!("#1C2027");
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/space/themes")
                .header("authorization", format!("Bearer {member}"))
                .header("content-type", "application/json")
                .body(Body::from(bad.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let text = String::from_utf8(
        axum::body::to_bytes(response.into_body(), 1 << 20)
            .await
            .unwrap()
            .to_vec(),
    )
    .unwrap();
    assert!(text.contains("textPrimary on surfaceBase"), "{text}");
}

#[tokio::test]
async fn removal_is_for_the_author_or_an_administrator() {
    let (store, _guard) = support::new_store("slimm-themes-delete").await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;
    let author = register(&store, "author").await;
    let other = register(&store, "other").await;

    let (_, mine) = send(&app, "POST", "/space/themes", &author, Some(theme("Mine"))).await;
    let mine = mine["id"].as_str().unwrap().to_owned();
    let (_, second) = send(
        &app,
        "POST",
        "/space/themes",
        &author,
        Some(theme("Second")),
    )
    .await;
    let second = second["id"].as_str().unwrap().to_owned();

    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/space/themes/{mine}"),
        &other,
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "another member cannot remove it"
    );
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/space/themes/{mine}"),
        &author,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "the author can");
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/space/themes/{second}"),
        &admin,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "an administrator can");
    let (status, _) = send(
        &app,
        "DELETE",
        &format!("/space/themes/{second}"),
        &admin,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn only_an_administrator_sets_the_default_and_removing_it_clears_it() {
    let (store, _guard) = support::new_store("slimm-themes-default").await;
    let app = app(store.clone());
    let admin = register(&store, "admin").await;
    let member = register(&store, "member").await;
    let (_, created) = send(&app, "POST", "/space/themes", &member, Some(theme("Dusk"))).await;
    let id = created["id"].as_str().unwrap().to_owned();

    let (status, _) = send(
        &app,
        "PUT",
        "/space/default-theme",
        &member,
        Some(json!({"theme_id": id})),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = send(
        &app,
        "PUT",
        "/space/default-theme",
        &admin,
        Some(json!({"theme_id": id})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (_, listed) = send(&app, "GET", "/space/themes", &member, None).await;
    assert_eq!(listed["default_theme_id"], id);

    let (status, _) = send(
        &app,
        "PUT",
        "/space/default-theme",
        &admin,
        Some(json!({"theme_id": uuid::Uuid::now_v7().to_string()})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    send(&app, "DELETE", &format!("/space/themes/{id}"), &admin, None).await;
    let (_, listed) = send(&app, "GET", "/space/themes", &member, None).await;
    assert!(
        listed["default_theme_id"].is_null(),
        "the default went with its theme"
    );

    let (status, _) = send(
        &app,
        "PUT",
        "/space/default-theme",
        &admin,
        Some(json!({"theme_id": null})),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_picture_is_served_back_and_a_non_image_is_refused() {
    let (store, _guard) = support::new_store("slimm-themes-picture").await;
    let app = app(store.clone());
    let member = register(&store, "admin").await;
    let png = support::images::small_png();
    let mut file = theme("Pic");
    file["backdrop"] = json!({"picture": {"data": BASE64.encode(&png), "dim": 0.5, "vignette": true, "blur": 0.0}});
    let (status, created) = send(&app, "POST", "/space/themes", &member, Some(file)).await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(created["has_picture"], true);
    assert!(
        created["theme"]["backdrop"]["picture"]
            .get("data")
            .is_none()
    );
    let id = created["id"].as_str().unwrap();

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/space/themes/{id}/picture"))
                .header("authorization", format!("Bearer {member}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "image/png");
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    assert_eq!(bytes.as_ref(), png.as_slice());

    let mut junk = theme("Junk");
    junk["backdrop"] = json!({"picture": {"data": BASE64.encode(b"nope"), "dim": 0.5, "vignette": true, "blur": 0.0}});
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/space/themes")
                .header("authorization", format!("Bearer {member}"))
                .header("content-type", "application/json")
                .body(Body::from(junk.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn the_store_is_capped() {
    let (store, _guard) = support::new_store("slimm-themes-cap").await;
    let app = app(store.clone());
    // Ten accounts, so none passes its own cap of five on the way to the Space's.
    let mut tokens = Vec::new();
    for i in 0..10 {
        tokens.push(register(&store, &format!("member{i}")).await);
    }
    for i in 0..50 {
        let (status, _) = send(
            &app,
            "POST",
            "/space/themes",
            &tokens[i % 10],
            Some(theme(&format!("T{i}"))),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "theme {i}");
    }
    let (status, _) = send(
        &app,
        "POST",
        "/space/themes",
        &tokens[0],
        Some(theme("One too many")),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn one_member_cannot_fill_the_store() {
    let (store, _guard) = support::new_store("slimm-themes-author-cap").await;
    let app = app(store.clone());
    let _admin = register(&store, "admin").await;
    let hog = register(&store, "hog").await;
    let other = register(&store, "other").await;
    let mut first = None;
    for i in 0..5 {
        let (status, created) = send(
            &app,
            "POST",
            "/space/themes",
            &hog,
            Some(theme(&format!("T{i}"))),
        )
        .await;
        assert_eq!(status, StatusCode::CREATED, "theme {i}");
        first.get_or_insert(created["id"].as_str().unwrap().to_owned());
    }
    let response = app
        .clone()
        .oneshot(request_json("POST", "/space/themes", &hog, theme("Sixth")))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let body = json_body_or_null(response).await.to_string();
    assert!(body.contains("5 themes"), "message names the limit: {body}");

    let (status, _) = send(&app, "POST", "/space/themes", &other, Some(theme("Mine"))).await;
    assert_eq!(status, StatusCode::CREATED, "another member is unaffected");

    let uri = format!("/space/themes/{}", first.unwrap());
    let (status, _) = send(&app, "DELETE", &uri, &hog, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let (status, _) = send(&app, "POST", "/space/themes", &hog, Some(theme("Again"))).await;
    assert_eq!(status, StatusCode::CREATED, "removing one frees a slot");
}
