// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unit tests for how the service talks to the LiveKit room service: its address,
//! the reachability probe, redirects and the not-found answers.

use super::*;

#[test]
fn the_room_service_address_is_derived_from_the_client_url() {
    assert_eq!(
        http_url_for("wss://livekit.example.com").unwrap(),
        "https://livekit.example.com"
    );
    assert_eq!(
        http_url_for("ws://10.0.0.100:7880/").unwrap(),
        "http://10.0.0.100:7880"
    );
    assert!(http_url_for("livekit.example.com").is_err());
}

#[tokio::test]
async fn an_unconfigured_deployment_has_nothing_to_probe() {
    assert_eq!(VoiceService::disabled().probe_reachable().await, None);
}

#[tokio::test]
async fn any_http_answer_reads_as_reachable_even_a_404() {
    // No route registered: every request still answers axum's own 404, which is what "reachable" asks about.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, axum::Router::new()).await.unwrap();
    });

    let service = VoiceService::for_test(&format!("http://{addr}"), "k", "s");
    assert_eq!(service.probe_reachable().await, Some(true));
}

#[tokio::test]
async fn a_closed_port_reads_as_unreachable() {
    // Grabbed then dropped, so nothing answers on it: connection refused, not a slow timeout.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);

    let service = VoiceService::for_test(&format!("http://{addr}"), "k", "s");
    assert_eq!(service.probe_reachable().await, Some(false));
}

/// A redirect from the room service must not take the admin token with it.
#[tokio::test]
async fn the_room_service_client_does_not_follow_a_redirect() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    let reached = Arc::new(AtomicBool::new(false));
    let seen = reached.clone();
    let elsewhere = axum::Router::new().fallback(move || {
        seen.store(true, Ordering::SeqCst);
        async { "leaked" }
    });
    let other = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target = format!("http://{}/steal", other.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(other, elsewhere).await.unwrap() });
    let redirecting = axum::Router::new().route(
        "/twirp",
        axum::routing::post(move || async move {
            (
                axum::http::StatusCode::TEMPORARY_REDIRECT,
                [(axum::http::header::LOCATION, target)],
            )
        }),
    );
    let first = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/twirp", first.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(first, redirecting).await.unwrap() });

    let response = room_service_client()
        .post(url)
        .bearer_auth("admin-token")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), reqwest::StatusCode::TEMPORARY_REDIRECT);
    assert!(
        !reached.load(Ordering::SeqCst),
        "the token never left for the redirect target"
    );
}

async fn service_answering(status: u16, body: &'static str) -> VoiceService {
    let router = axum::Router::new()
        .fallback(move || async move { (axum::http::StatusCode::from_u16(status).unwrap(), body) });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    VoiceService::for_test(
        &format!("http://{addr}"),
        "k",
        "a-secret-at-least-32-chars-long!",
    )
}

#[tokio::test]
async fn a_plain_404_from_the_room_service_is_an_error_not_a_gone_participant() {
    let service = service_answering(404, "").await;
    let removed = service
        .remove_participant(ChannelId::generate(), UserId::generate())
        .await;
    assert!(
        matches!(removed, Err(VoiceError::Internal(_))),
        "{removed:?}"
    );
    let listed = service.list_participants(ChannelId::generate()).await;
    assert!(matches!(listed, Err(VoiceError::Internal(_))), "{listed:?}");
}

#[tokio::test]
async fn a_twirp_not_found_from_the_room_service_reads_as_already_gone() {
    let service =
        service_answering(404, r#"{"code":"not_found","msg":"room does not exist"}"#).await;
    service
        .remove_participant(ChannelId::generate(), UserId::generate())
        .await
        .expect("a participant that is gone is removed");
    assert!(
        service
            .list_participants(ChannelId::generate())
            .await
            .expect("an absent room has no one in it")
            .is_empty()
    );
}
