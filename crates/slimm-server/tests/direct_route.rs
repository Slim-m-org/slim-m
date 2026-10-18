// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The LAN direct addresses are private network details: the unauthenticated `/version` must
//! not carry them, and `GET /direct-route` gives them only to a signed-in member.
//!
//! One test, because it sets a process-wide environment variable.
#![allow(dead_code)]

use axum::http::StatusCode;
use tower::ServiceExt;

mod support;
mod totp_support;

use totp_support::{app, json_body, member, new_store, request};

#[tokio::test]
async fn direct_addresses_leave_version_and_need_a_session() {
    unsafe { std::env::set_var("SLIMM_DIRECT_ADDRESSES", "10.0.0.100:443, junk") };
    let (store, auth, _guard) = new_store("slimm-direct-route").await;
    let router = app(store.clone(), auth.clone());
    let (token, _) = member(&store, &auth, "alice").await;

    let version = router
        .clone()
        .oneshot(request("GET", "/version", None, None))
        .await
        .unwrap();
    assert_eq!(version.status(), StatusCode::OK);
    let body = json_body(version).await;
    assert!(
        body.get("direct_addresses").is_none(),
        "/version leaked the LAN address: {body}"
    );

    let anonymous = router
        .clone()
        .oneshot(request("GET", "/direct-route", None, None))
        .await
        .unwrap();
    assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);

    let signed_in = router
        .clone()
        .oneshot(request("GET", "/direct-route", Some(&token), None))
        .await
        .unwrap();
    assert_eq!(signed_in.status(), StatusCode::OK);
    assert_eq!(
        json_body(signed_in).await["addresses"],
        serde_json::json!(["10.0.0.100:443"])
    );
    unsafe { std::env::remove_var("SLIMM_DIRECT_ADDRESSES") };
}
