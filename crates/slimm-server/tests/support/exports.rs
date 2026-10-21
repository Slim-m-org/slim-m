// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Starting, finishing and unpacking data exports for the export tests.

use std::collections::BTreeMap;
use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::http::AppState;
use slimm_server::media::Media;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

use super::app::{builder, json_body, request, request_authed};

/// A build over a handful of rows takes milliseconds; this is the loaded-runner margin.
const BUILD_TIMEOUT: Duration = Duration::from_secs(20);

pub const PASSWORD: &str = "correct-horse-battery";

pub struct World {
    pub store: Store,
    pub media: Media,
    pub router: Router,
}

pub fn world(store: Store) -> World {
    world_with_media(store, Media::for_tests())
}

pub fn world_with_media(store: Store, media: Media) -> World {
    let state: AppState = builder(store.clone()).media(media.clone()).build();
    World {
        store,
        media,
        router: slimm_server::http::router(state),
    }
}

/// An account whose password is [`PASSWORD`]; the first one claims the deployment.
pub async fn account(store: &Store, username: &str) -> (String, String) {
    let hash = Auth::new(2)
        .unwrap()
        .hash_password(PASSWORD.to_owned())
        .await
        .unwrap();
    let created = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(created.id).await.unwrap();
    let tokens = store.open_session(created.id, "cli").await.unwrap();
    (tokens.access_token, created.id.to_string())
}

impl World {
    pub async fn send(&self, token: &str, channel: &str, content: &str) -> Value {
        let response = self
            .router
            .clone()
            .oneshot(request_authed(
                "POST",
                &format!("/channels/{channel}/messages"),
                token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "content": content })),
            ))
            .await
            .unwrap();
        assert!(response.status().is_success());
        json_body(response).await
    }

    pub async fn start(&self, token: &str, kind: &str) -> (StatusCode, Value) {
        self.start_with(token, kind, Some(json!({ "password": PASSWORD })))
            .await
    }

    pub async fn start_with(
        &self,
        token: &str,
        kind: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        self.call("POST", &format!("/exports/{kind}"), token, body)
            .await
    }

    /// Starts an export and reports the status with any `Retry-After` seconds.
    pub async fn start_retry_after(&self, token: &str, kind: &str) -> (StatusCode, Option<u64>) {
        let response = self
            .router
            .clone()
            .oneshot(request(
                "POST",
                &format!("/exports/{kind}"),
                Some(token),
                Some(json!({ "password": PASSWORD })),
            ))
            .await
            .unwrap();
        let wait = response
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse().ok());
        (response.status(), wait)
    }

    pub async fn call(
        &self,
        method: &str,
        uri: &str,
        token: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let response = self
            .router
            .clone()
            .oneshot(request(method, uri, Some(token), body))
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    /// Starts an export and waits for it to finish, returning the finished job.
    pub async fn export(&self, token: &str, kind: &str) -> Value {
        let (status, job) = self.start(token, kind).await;
        assert_eq!(status, StatusCode::ACCEPTED, "{job}");
        self.finished(token, job["id"].as_str().unwrap()).await
    }

    pub async fn finished(&self, token: &str, id: &str) -> Value {
        let probe = || async {
            let (_, job) = self
                .call("GET", &format!("/exports/{id}"), token, None)
                .await;
            (!matches!(job["status"].as_str(), Some("queued" | "running"))).then_some(job)
        };
        match super::wait::poll(BUILD_TIMEOUT, probe).await {
            Some(job) => job,
            None => panic!("export {id} never finished"),
        }
    }

    pub async fn download(&self, token: &str, id: &str) -> (StatusCode, Vec<u8>) {
        let response = self
            .router
            .clone()
            .oneshot(request(
                "GET",
                &format!("/exports/{id}/download"),
                Some(token),
                None,
            ))
            .await
            .unwrap();
        let status = response.status();
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        (status, bytes.to_vec())
    }

    /// Downloads with a `Range` header and returns the status.
    pub async fn download_range(&self, token: &str, id: &str, range: &str) -> StatusCode {
        let request = axum::http::Request::builder()
            .uri(format!("/exports/{id}/download"))
            .header("authorization", format!("Bearer {token}"))
            .header("range", range)
            .body(axum::body::Body::empty())
            .unwrap();
        self.router.clone().oneshot(request).await.unwrap().status()
    }

    /// A finished export, unpacked.
    pub async fn archive(&self, token: &str, kind: &str) -> Archive {
        let job = self.export(token, kind).await;
        assert_eq!(job["status"], "ready", "{job}");
        let (status, bytes) = self.download(token, job["id"].as_str().unwrap()).await;
        assert_eq!(status, StatusCode::OK);
        Archive::parse(&bytes)
    }
}

pub struct Archive {
    pub entries: BTreeMap<String, Vec<u8>>,
}

impl Archive {
    /// Reads a ustar archive, failing the test on a malformed one.
    pub fn parse(bytes: &[u8]) -> Self {
        let mut entries = BTreeMap::new();
        let mut at = 0;
        while at + 512 <= bytes.len() {
            let header = &bytes[at..at + 512];
            if header.iter().all(|b| *b == 0) {
                break;
            }
            let name_end = header[..100].iter().position(|b| *b == 0).unwrap_or(100);
            let name = String::from_utf8(header[..name_end].to_vec()).unwrap();
            let size = parse_size(&header[124..136]);
            let stored: u32 = header[..148]
                .iter()
                .chain(&[b' '; 8])
                .chain(&header[156..])
                .map(|b| u32::from(*b))
                .sum();
            let recorded =
                u32::from_str_radix(std::str::from_utf8(&header[148..154]).unwrap().trim(), 8)
                    .unwrap();
            assert_eq!(stored, recorded, "bad checksum for {name}");
            at += 512;
            entries.insert(name, bytes[at..at + size].to_vec());
            at += size.div_ceil(512) * 512;
        }
        Self { entries }
    }

    pub fn text(&self, name: &str) -> String {
        String::from_utf8(self.entries[name].clone()).unwrap()
    }

    pub fn json(&self, name: &str) -> Value {
        serde_json::from_slice(&self.entries[name]).unwrap()
    }

    pub fn lines(&self, name: &str) -> Vec<Value> {
        self.text(name)
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    /// Whether `needle` appears anywhere in any entry's bytes.
    pub fn contains(&self, needle: &str) -> bool {
        let needle = needle.as_bytes();
        self.entries
            .values()
            .any(|data| data.windows(needle.len()).any(|w| w == needle))
    }
}

fn parse_size(field: &[u8]) -> usize {
    let text = std::str::from_utf8(field)
        .unwrap()
        .trim_matches(|c| c == '\0' || c == ' ');
    usize::from_str_radix(text, 8).unwrap()
}

/// Uploads a small PNG and returns its attachment id.
pub async fn upload_png(w: &World, token: &str) -> String {
    let response = w
        .router
        .clone()
        .oneshot(
            axum::http::Request::builder()
                .method("POST")
                .uri("/attachments?filename=pixel.png")
                .header("authorization", format!("Bearer {token}"))
                .body(axum::body::Body::from(super::images::small_png()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::CREATED);
    json_body(response).await["id"].as_str().unwrap().to_owned()
}
