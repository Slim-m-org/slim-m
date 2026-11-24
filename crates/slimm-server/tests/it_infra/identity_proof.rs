// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /identity/proof` signs a client's fresh challenge with the key
//! `/version` reports, so a copied public key alone cannot pass for it.

use axum::http::StatusCode;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use ed25519_dalek::{Signature, Verifier as _, VerifyingKey};
use serde_json::{Value, json};
use slimm_server::identity::PROOF_CONTEXT;

use crate::support;
use support::app::call;

fn bytes(value: &Value, field: &str) -> Vec<u8> {
    BASE64
        .decode(value[field].as_str().expect("a base64 string"))
        .expect("valid base64")
}

fn verifies(public_key: &[u8], challenge: &[u8], signature: &[u8]) -> bool {
    let key = VerifyingKey::from_bytes(public_key.try_into().unwrap()).unwrap();
    let signature = Signature::from_slice(signature).unwrap();
    key.verify(&[PROOF_CONTEXT, challenge].concat(), &signature)
        .is_ok()
}

#[tokio::test]
async fn the_proof_verifies_against_the_version_key_and_only_for_its_challenge() {
    let (store, _guard) = support::new_store("slimm-identity-proof").await;
    let router = support::app::router(store);
    let (_, version) = call(&router, "GET", "/version", None, None).await;
    let pinned = bytes(&version["identity"], "public_key");

    let challenge = [7u8; 32];
    let (status, proof) = call(
        &router,
        "POST",
        "/identity/proof",
        None,
        Some(json!({ "challenge": BASE64.encode(challenge) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(bytes(&proof, "public_key"), pinned);
    let signature = bytes(&proof, "signature");
    assert!(verifies(&pinned, &challenge, &signature));
    assert!(
        !verifies(&pinned, &[8u8; 32], &signature),
        "a proof replayed for another challenge must not verify"
    );
}

#[tokio::test]
async fn a_challenge_outside_the_accepted_length_is_refused() {
    let (store, _guard) = support::new_store("slimm-identity-proof-bounds").await;
    let router = support::app::router(store);
    for challenge in [
        BASE64.encode([1u8; 8]),
        BASE64.encode([1u8; 65]),
        "not base64!".to_owned(),
    ] {
        let (status, _) = call(
            &router,
            "POST",
            "/identity/proof",
            None,
            Some(json!({ "challenge": challenge })),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{challenge}");
    }
}
