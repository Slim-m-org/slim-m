// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A LiveKit webhook delivery signed the way its own server SDKs sign one.

use axum::body::Body;
use axum::http::Request;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64STD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

/// HS256 over `header.payload`, with a base64-standard sha256 digest of the
/// body as a claim rather than the body itself.
pub fn sign_webhook(body: &[u8], api_key: &str, api_secret: &str) -> String {
    let header = BASE64URL.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let sha256 = BASE64STD.encode(Sha256::digest(body));
    let exp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 300;
    let claims = json!({ "iss": api_key, "exp": exp, "sha256": sha256 });
    let payload = BASE64URL.encode(serde_json::to_vec(&claims).unwrap());
    let signing_input = format!("{header}.{payload}");
    let mut mac = <Hmac<Sha256>>::new_from_slice(api_secret.as_bytes()).unwrap();
    mac.update(signing_input.as_bytes());
    let signature = BASE64URL.encode(mac.finalize().into_bytes());
    format!("{signing_input}.{signature}")
}

/// A signed `POST /voice/webhook` carrying `body`.
pub fn webhook_request(body: Value, api_key: &str, api_secret: &str) -> Request<Body> {
    let bytes = serde_json::to_vec(&body).unwrap();
    let token = sign_webhook(&bytes, api_key, api_secret);
    Request::builder()
        .method("POST")
        .uri("/voice/webhook")
        .header("authorization", token)
        .header("content-type", "application/webhook+json")
        .body(Body::from(bytes))
        .unwrap()
}
