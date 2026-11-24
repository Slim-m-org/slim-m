// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `POST /identity/proof`: the server signs a client's fresh challenge with its
//! identity key, so a client can tell this server from one that copied its
//! public key out of `/version`. See [`crate::identity`] for what that proves.

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::routing::post;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Json, READ, RateLimited};

/// Room for the largest challenge as base64 inside its JSON object.
const BODY_LIMIT: usize = 256;

/// Shortest challenge accepted, in bytes: enough that a client never repeats one.
const MIN_CHALLENGE_BYTES: usize = 16;

/// Longest challenge accepted, in bytes.
const MAX_CHALLENGE_BYTES: usize = 64;

pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/identity/proof", post(prove))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct ProofRequest {
    /// Standard base64 of the client's random challenge bytes.
    challenge: String,
}

#[derive(Serialize)]
struct ProofResponse {
    /// The same standard-base64 public key `/version` reports.
    public_key: String,
    /// Standard base64 of the Ed25519 signature over the proof context and the challenge.
    signature: String,
}

async fn prove(
    _limited: RateLimited<READ>,
    State(state): State<AppState>,
    Json(req): Json<ProofRequest>,
) -> Result<Json<ProofResponse>, ApiError> {
    let challenge = BASE64
        .decode(req.challenge.trim())
        .ok()
        .filter(|bytes| (MIN_CHALLENGE_BYTES..=MAX_CHALLENGE_BYTES).contains(&bytes.len()))
        .ok_or(ApiError::BadRequest(
            "challenge must be 16 to 64 bytes of standard base64",
        ))?;
    let (identity, signature) = state.store.sign_identity_proof(&challenge).await?;
    Ok(Json(ProofResponse {
        public_key: BASE64.encode(identity.public_key()),
        signature: BASE64.encode(signature),
    }))
}
