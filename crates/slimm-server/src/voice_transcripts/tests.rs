// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use axum::Router;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;

use super::*;

async fn stub(handler: axum::routing::MethodRouter) -> String {
    let app = Router::new().route("/v1/transcribe", handler);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await });
    format!("http://{addr}/v1/transcribe")
}

#[tokio::test]
async fn the_listener_engine_sends_the_bytes_with_the_secret_and_reads_the_text() {
    let url = stub(post(
        |headers: HeaderMap, body: axum::body::Bytes| async move {
            assert_eq!(headers["authorization"], "Bearer s3cret");
            assert_eq!(&body[..], b"clip");
            axum::Json(
                serde_json::json!({"text": " hi there ", "language": "en", "duration_ms": 1}),
            )
        },
    ))
    .await;
    let heard = ListenerEngine::new(url, "s3cret".into())
        .transcribe(b"clip".to_vec())
        .await
        .unwrap();
    assert_eq!(heard.text, "hi there");
    assert_eq!(heard.language.as_deref(), Some("en"));
}

#[tokio::test]
async fn only_a_listener_that_took_the_clip_can_fail_it() {
    let engine = |url: String| ListenerEngine::new(url, "s".into());
    let answer = |status: StatusCode| async move {
        let url = stub(post(move || async move { status })).await;
        engine(url).transcribe(vec![1]).await
    };
    assert_eq!(
        answer(StatusCode::UNPROCESSABLE_ENTITY).await,
        Err(Failure::Permanent)
    );
    assert_eq!(
        answer(StatusCode::INTERNAL_SERVER_ERROR).await,
        Err(Failure::Transient)
    );
    for not_taken in [
        StatusCode::NOT_FOUND,
        StatusCode::METHOD_NOT_ALLOWED,
        StatusCode::UNAUTHORIZED,
        StatusCode::TOO_MANY_REQUESTS,
        StatusCode::BAD_GATEWAY,
        StatusCode::SERVICE_UNAVAILABLE,
        StatusCode::GATEWAY_TIMEOUT,
    ] {
        assert_eq!(
            answer(not_taken).await,
            Err(Failure::Unavailable),
            "{not_taken}"
        );
    }
    let gone = "http://127.0.0.1:1/v1/transcribe".to_owned();
    assert_eq!(
        engine(gone).transcribe(vec![1]).await,
        Err(Failure::Unavailable)
    );
}

#[tokio::test]
async fn the_transcribe_address_sits_beside_the_control_address() {
    let settings = |url: &str| crate::config::ListenerSettings {
        url: url.into(),
        secret: "x".repeat(32),
        livekit_url: None,
    };
    let after_scheme = |url: &str, route: &str| {
        let (_, rest) = url.split_once("://").unwrap();
        rest.strip_suffix(route).unwrap().to_owned()
    };
    for (base, transcribe) in [
        (
            "wss://host.example/listener",
            "https://host.example/listener/v1/transcribe",
        ),
        (
            "ws://127.0.0.1:9400/",
            "http://127.0.0.1:9400/v1/transcribe",
        ),
        ("ws://listener:9400", "http://listener:9400/v1/transcribe"),
    ] {
        let endpoint = CallAudio::new(Some(settings(base)))
            .transcribe_endpoint()
            .unwrap()
            .0;
        assert_eq!(endpoint, transcribe, "{base}");
        let control = crate::call_audio::link::control_url(base);
        assert_eq!(
            after_scheme(&endpoint, "/v1/transcribe"),
            after_scheme(&control, "/v1/control"),
            "{base}"
        );
    }
    assert!(CallAudio::disabled().transcribe_endpoint().is_none());
}
