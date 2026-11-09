// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A failed provider request must not carry the API key or the search words
//! out of this module, because the caller logs the error.

use super::*;

const KEY: &str = "sekrit-api-key-7731";
const WORDS: &str = "private-search-words";

async fn refusing_server() -> String {
    let router =
        axum::Router::new().fallback(|| async { axum::http::StatusCode::TOO_MANY_REQUESTS });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    format!("http://{addr}")
}

async fn closed_port() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    drop(listener);
    format!("http://{addr}")
}

fn assert_scrubbed(err: &anyhow::Error) {
    for text in [err.to_string(), format!("{err:#}"), format!("{err:?}")] {
        assert!(!text.contains(KEY), "the key leaked: {text}");
        assert!(!text.contains(WORDS), "the search words leaked: {text}");
    }
}

#[tokio::test]
async fn a_search_that_cannot_connect_leaks_neither_the_key_nor_the_words() {
    let base = closed_port().await;
    let http = reqwest::Client::new();
    for provider in [Provider::Tenor, Provider::Klipy] {
        let err = search(&http, provider, Some(&base), KEY, WORDS, 5)
            .await
            .expect_err("nothing is listening");
        assert_scrubbed(&err);
    }
}

#[tokio::test]
async fn trending_that_cannot_connect_leaks_no_key() {
    let base = closed_port().await;
    let http = reqwest::Client::new();
    for provider in [Provider::Tenor, Provider::Klipy] {
        let err = trending(&http, provider, Some(&base), KEY, 5)
            .await
            .expect_err("nothing is listening");
        assert_scrubbed(&err);
    }
}

#[tokio::test]
async fn a_quota_refusal_leaks_neither_the_key_nor_the_words() {
    let base = refusing_server().await;
    let http = reqwest::Client::new();
    let err = search(&http, Provider::Tenor, Some(&base), KEY, WORDS, 5)
        .await
        .expect_err("a 429 is an error");
    assert!(err.to_string().contains("429"), "{err}");
    assert_scrubbed(&err);
}

#[tokio::test]
async fn a_provider_sentence_that_is_not_a_transport_error_passes_through() {
    let base = refusing_server().await;
    let http = reqwest::Client::new();
    let err = search(&http, Provider::Klipy, Some(&base), KEY, WORDS, 5)
        .await
        .expect_err("a 429 is an error");
    assert!(err.to_string().contains("klipy answered 429"), "{err}");
    assert_scrubbed(&err);
}
