// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What an attacker-supplied filename can reach. It is the one piece of
//! caller-controlled text that crosses upload, storage and a response
//! header, so it is tested as one round trip rather than at either end.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::*;

/// Storage never uses the filename as a path component at all (files are keyed
/// by content hash), so the traversal has nowhere to escape to even before
/// sanitizing; this asserts the whole round trip still behaves, not just the
/// sanitizer in isolation.
#[tokio::test]
async fn a_hostile_filename_cannot_escape_into_the_header_or_the_storage_path() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;

    // A newline (header injection), a quote (breaking out of the quoted
    // Content-Disposition value) and a path traversal sequence, in one name.
    let hostile = "evil\r\nX-Injected: yes\"../../../etc/passwd.png";
    let encoded = urlencoding_minimal(hostile);
    let bytes = png(4);
    let uploaded = upload(&app, &token, &encoded, bytes.clone()).await;
    let filename = uploaded["filename"].as_str().unwrap();
    assert!(!filename.contains('\r'));
    assert!(!filename.contains('\n'));
    assert!(!filename.contains('"'));
    assert!(!filename.contains('/'));
    assert!(!filename.contains('\\'));

    let attachment_id = uploaded["id"].as_str().unwrap().to_owned();
    let sent = app
        .clone()
        .oneshot(request_json(
            "POST",
            &format!("/channels/{}/messages", channel.id),
            &token,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "x",
                "attachment_ids": [attachment_id.clone()],
            }),
        ))
        .await
        .unwrap();
    assert_eq!(sent.status(), StatusCode::OK);

    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{attachment_id}"),
            &token,
        ))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    // The raw header value, not just the JSON field: a `HeaderValue` cannot
    // even hold a literal CR or LF, so it can never have held the raw name.
    let disposition = response
        .headers()
        .get("content-disposition")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(!disposition.contains('\r'));
    assert!(!disposition.contains('\n'));
    // Exactly two quotes: the pair the filename is wrapped in, and none from
    // the hostile input itself.
    assert_eq!(disposition.matches('"').count(), 2);

    // Storage never used the filename as a path, so the bytes read back are
    // exactly what was uploaded regardless of what the name claimed.
    let body = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    assert_eq!(body.as_ref(), bytes.as_slice());
}

/// Percent-encodes just enough (CR, LF, the quote, and the space a real
/// client would also need to escape) to make the hostile filename a legal
/// query-string value; a real client's URL encoder would do the same.
fn urlencoding_minimal(raw: &str) -> String {
    raw.chars()
        .map(|c| match c {
            '\r' => "%0D".to_owned(),
            '\n' => "%0A".to_owned(),
            '"' => "%22".to_owned(),
            ' ' => "%20".to_owned(),
            other => other.to_string(),
        })
        .collect()
}

/// A non-ASCII name survives the upload as typed and reaches the download as
/// an RFC 5987 `filename*`, with an ASCII fallback beside it (issue 2075).
#[tokio::test]
async fn a_unicode_filename_round_trips_as_typed() {
    let (store, _guard) = new_store().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let app = app(store.clone());
    let (token, _id) = register(&store, "alice").await;
    let name = "résumé 日本.png";
    let encoded: String = name
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b == b'.' {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect();

    let uploaded = upload(&app, &token, &encoded, png(4)).await;
    assert_eq!(uploaded["filename"], name);

    let attachment_id = uploaded["id"].as_str().unwrap();
    let response = app
        .clone()
        .oneshot(request_plain(
            "GET",
            &format!("/attachments/{attachment_id}"),
            &token,
        ))
        .await
        .unwrap();
    let disposition = response
        .headers()
        .get("content-disposition")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(
        disposition.ends_with("filename*=UTF-8''r%C3%A9sum%C3%A9%20%E6%97%A5%E6%9C%AC.png"),
        "{disposition}"
    );
    assert!(
        disposition.contains("filename=\"r_sum_ __.png\""),
        "{disposition}"
    );
}
