// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The guarded fetch against a loopback upstream: every hop re-validated, the
//! redirect, size and content-type caps, and the image proxy's sniffing
//! (issue 2110).

use axum::Router;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Html;
use axum::routing::get;
use tokio::net::TcpListener;

use super::fetch::{FetchError, MAX_HTML_BYTES, build_client, fetch_image, fetch_preview, follow};

async fn upstream() -> String {
    let router = Router::new()
        .route("/to-ftp", get(|| async { redirect("ftp://example.com/") }))
        .route(
            "/loop/{n}",
            get(
                |axum::extract::Path(n): axum::extract::Path<u32>| async move {
                    redirect(&format!("/loop/{}", n + 1))
                },
            ),
        )
        .route("/missing", get(|| async { StatusCode::NOT_FOUND }))
        .route(
            "/json",
            get(|| async { ([(header::CONTENT_TYPE, "application/json")], "{}") }),
        )
        .route(
            "/huge",
            get(|| async {
                Html(format!(
                    "<title>x</title>{}",
                    "a".repeat(MAX_HTML_BYTES + 1)
                ))
            }),
        )
        .route(
            "/huge.png",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "image/png")],
                    vec![0u8; 5 * 1024 * 1024 + 1],
                )
            }),
        )
        .route("/fake.png", get(|| async { Html("<p>not an image</p>") }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

fn redirect(to: &str) -> (StatusCode, HeaderMap) {
    let mut headers = HeaderMap::new();
    headers.insert(header::LOCATION, to.parse().unwrap());
    (StatusCode::FOUND, headers)
}

#[tokio::test]
async fn a_loopback_url_is_refused_with_the_guard_on() {
    let base = upstream().await;
    let refused = follow(&build_client(false), &format!("{base}/json"), false).await;
    assert_eq!(refused.err(), Some(FetchError::Refused));
}

#[tokio::test]
async fn every_redirect_hop_is_validated_again() {
    let base = upstream().await;
    let hop = follow(&build_client(true), &format!("{base}/to-ftp"), true).await;
    assert_eq!(hop.err(), Some(FetchError::Refused));
}

#[tokio::test]
async fn a_long_redirect_chain_gives_up() {
    let base = upstream().await;
    let chain = follow(&build_client(true), &format!("{base}/loop/0"), true).await;
    assert_eq!(chain.err(), Some(FetchError::Unavailable));
}

#[tokio::test]
async fn caps_and_content_types_end_a_preview_cleanly() {
    let base = upstream().await;
    let client = build_client(true);
    let missing = fetch_preview(&client, &format!("{base}/missing"), true).await;
    assert_eq!(missing.err(), Some(FetchError::Unavailable));
    let json = fetch_preview(&client, &format!("{base}/json"), true).await;
    assert!(matches!(json, Ok(None)));
    let huge = fetch_preview(&client, &format!("{base}/huge"), true).await;
    assert_eq!(huge.err(), Some(FetchError::Unavailable));
}

#[tokio::test]
async fn the_image_proxy_refuses_oversized_or_mislabelled_images() {
    let base = upstream().await;
    let client = build_client(true);
    let huge = fetch_image(&client, &format!("{base}/huge.png"), true).await;
    assert_eq!(huge.err(), Some(FetchError::Unavailable));
    let html = fetch_image(&client, &format!("{base}/fake.png"), true).await;
    assert_eq!(html.err(), Some(FetchError::Unavailable));
}

#[test]
fn served_images_are_sniffed_and_marked_nosniff() {
    assert!(super::serve_image(b"<html>hi</html>".to_vec().into()).is_err());
    let png = [
        0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, b'I', b'H', b'D', b'R',
    ];
    let Ok(response) = super::serve_image(png.to_vec().into()) else {
        panic!("a real png must be served");
    };
    assert_eq!(
        response.headers()[header::X_CONTENT_TYPE_OPTIONS],
        "nosniff"
    );
    assert_eq!(response.headers()[header::CONTENT_TYPE], "image/png");
}
