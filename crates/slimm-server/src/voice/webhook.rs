// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Verifying and parsing a LiveKit webhook delivery.
//!
//! See `docs/decisions/0032-voice-participant-webhooks.md` for why this
//! exists. LiveKit signs each delivery with an HS256 JWT in the
//! `Authorization` header, carrying a base64 digest of the raw body rather
//! than the body itself, the same scheme its own server SDKs verify against.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64STD;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::ids::ChannelId;

use super::VoiceService;
use super::token::unix_secs;

/// Why a webhook delivery was refused.
#[derive(Debug, PartialEq, Eq)]
pub enum WebhookError {
    /// This deployment has no SFU configured, so there is no secret to
    /// verify against.
    Unavailable,
    /// No `Authorization` header, or not shaped like a JWT.
    Malformed,
    /// The signature does not verify against the configured secret, the
    /// issuer does not match our configured key, or the signed body digest
    /// does not match what was actually posted.
    BadSignature,
    /// The token's own `exp` claim has passed.
    Expired,
}

#[derive(Deserialize)]
struct Claims {
    iss: String,
    #[serde(default)]
    exp: Option<u64>,
    #[serde(default)]
    sha256: Option<String>,
}

/// A LiveKit `WebhookEvent`, trimmed to the fields this crate reads.
///
/// `track_published`/`track_unpublished` deliver `room` and `participant`
/// trimmed to sid/name/identity; every field read here is present on both.
#[derive(Debug, Deserialize)]
pub struct WebhookEvent {
    pub event: String,
    #[serde(default)]
    pub room: Option<RoomInfo>,
    #[serde(default)]
    pub participant: Option<ParticipantInfo>,
    #[serde(default)]
    pub track: Option<TrackInfo>,
}

#[derive(Debug, Deserialize)]
pub struct RoomInfo {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct ParticipantInfo {
    pub identity: String,
}

#[derive(Debug, Deserialize)]
pub struct TrackInfo {
    #[serde(default)]
    pub sid: String,
    #[serde(default)]
    pub source: String,
}

/// The inverse of [`super::room_for_channel`], for reading a webhook's room
/// name back into the channel it names. `None` for anything not shaped like
/// one of ours, including a room from some other application sharing the
/// same LiveKit deployment.
pub fn channel_for_room(room: &str) -> Option<ChannelId> {
    room.strip_prefix("channel-")?.parse().ok().map(ChannelId)
}

impl VoiceService {
    /// Verifies and decodes a LiveKit webhook delivery against this
    /// deployment's configured key and secret.
    pub fn verify_webhook(
        &self,
        body: &[u8],
        authorization: Option<&str>,
    ) -> Result<WebhookEvent, WebhookError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(WebhookError::Unavailable);
        };
        verify_and_parse(body, authorization, &enabled.api_key, &enabled.api_secret)
    }
}

/// Whether a `TrackInfo.source` names a screen share (video or its
/// accompanying audio track).
///
/// Matched permissively (any source containing `SCREEN`) rather than against
/// one exact literal: LiveKit's proto names these `SCREEN_SHARE` and
/// `SCREEN_SHARE_AUDIO`, but documentation on the exact JSON string the
/// pinned server version emits disagreed across sources. See the decision
/// record's "Track source matching" section.
pub fn is_screen_share_source(source: &str) -> bool {
    source.to_ascii_uppercase().contains("SCREEN")
}

/// Verifies a webhook delivery's signature and decodes its payload.
///
/// `authorization` is the raw header value, with or without a `Bearer `
/// prefix - LiveKit's own examples send the bare JWT, but accepting both
/// costs nothing and a proxy in front could plausibly add one.
pub fn verify_and_parse(
    body: &[u8],
    authorization: Option<&str>,
    api_key: &str,
    api_secret: &str,
) -> Result<WebhookEvent, WebhookError> {
    let token = authorization.ok_or(WebhookError::Malformed)?;
    let token = token.strip_prefix("Bearer ").unwrap_or(token);

    let mut segments = token.split('.');
    let header_b64 = segments.next().ok_or(WebhookError::Malformed)?;
    let payload_b64 = segments.next().ok_or(WebhookError::Malformed)?;
    let signature_b64 = segments.next().ok_or(WebhookError::Malformed)?;
    if segments.next().is_some() {
        return Err(WebhookError::Malformed);
    }

    let signature = BASE64URL
        .decode(signature_b64)
        .map_err(|_| WebhookError::Malformed)?;
    let signing_input = format!("{header_b64}.{payload_b64}");

    let mut mac = <Hmac<Sha256>>::new_from_slice(api_secret.as_bytes())
        .map_err(|_| WebhookError::Malformed)?;
    mac.update(signing_input.as_bytes());
    mac.verify_slice(&signature)
        .map_err(|_| WebhookError::BadSignature)?;

    let payload = BASE64URL
        .decode(payload_b64)
        .map_err(|_| WebhookError::Malformed)?;
    let claims: Claims = serde_json::from_slice(&payload).map_err(|_| WebhookError::Malformed)?;

    if claims.iss != api_key {
        return Err(WebhookError::BadSignature);
    }
    // No exp is not "never expires": LiveKit's signer always sets one.
    let Some(exp) = claims.exp else {
        return Err(WebhookError::Malformed);
    };
    if exp < unix_secs() {
        return Err(WebhookError::Expired);
    }

    // Binds the signature to THIS body, not just some sha256 the secret holder signed.
    let digest = BASE64STD.encode(Sha256::digest(body));
    if claims.sha256.as_deref() != Some(digest.as_str()) {
        return Err(WebhookError::BadSignature);
    }

    serde_json::from_slice(body).map_err(|_| WebhookError::Malformed)
}

#[cfg(test)]
mod tests {
    use super::*;

    const API_KEY: &str = "APItestkey";
    const API_SECRET: &str = "a-test-secret-of-at-least-32-characters";

    /// Signs a body the same way LiveKit's own server SDKs do, so tests
    /// exercise the real verification path rather than a stand-in for it.
    fn sign(body: &[u8], api_key: &str, api_secret: &str, exp_delta_secs: i64) -> String {
        let header = BASE64URL.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
        let sha256 = BASE64STD.encode(Sha256::digest(body));
        let exp = (unix_secs() as i64 + exp_delta_secs).max(0) as u64;
        let claims = serde_json::json!({ "iss": api_key, "exp": exp, "sha256": sha256 });
        let payload = BASE64URL.encode(serde_json::to_vec(&claims).unwrap());
        let signing_input = format!("{header}.{payload}");
        let mut mac = <Hmac<Sha256>>::new_from_slice(api_secret.as_bytes()).unwrap();
        mac.update(signing_input.as_bytes());
        let signature = BASE64URL.encode(mac.finalize().into_bytes());
        format!("{signing_input}.{signature}")
    }

    #[test]
    fn a_correctly_signed_delivery_verifies_and_decodes() {
        let body = br#"{"event":"participant_joined","room":{"name":"channel-x"},"participant":{"identity":"u1"}}"#;
        let token = sign(body, API_KEY, API_SECRET, 300);
        let event = verify_and_parse(body, Some(&token), API_KEY, API_SECRET).unwrap();
        assert_eq!(event.event, "participant_joined");
        assert_eq!(event.room.unwrap().name, "channel-x");
        assert_eq!(event.participant.unwrap().identity, "u1");
    }

    #[test]
    fn a_bearer_prefixed_header_is_accepted_too() {
        let body = br#"{"event":"participant_left"}"#;
        let token = sign(body, API_KEY, API_SECRET, 300);
        let header = format!("Bearer {token}");
        assert!(verify_and_parse(body, Some(&header), API_KEY, API_SECRET).is_ok());
    }

    #[test]
    fn a_body_edited_after_signing_is_refused() {
        let signed_body = br#"{"event":"participant_left","room":{"name":"a"}}"#;
        let token = sign(signed_body, API_KEY, API_SECRET, 300);
        let tampered = br#"{"event":"participant_left","room":{"name":"b"}}"#;
        assert!(matches!(
            verify_and_parse(tampered, Some(&token), API_KEY, API_SECRET),
            Err(WebhookError::BadSignature)
        ));
    }

    #[test]
    fn a_signature_from_the_wrong_secret_is_refused() {
        let body = br#"{"event":"participant_left"}"#;
        let token = sign(body, API_KEY, "a-different-secret-of-32-characters!!", 300);
        assert!(matches!(
            verify_and_parse(body, Some(&token), API_KEY, API_SECRET),
            Err(WebhookError::BadSignature)
        ));
    }

    #[test]
    fn an_expired_token_is_refused() {
        let body = br#"{"event":"participant_left"}"#;
        let token = sign(body, API_KEY, API_SECRET, -10);
        assert!(matches!(
            verify_and_parse(body, Some(&token), API_KEY, API_SECRET),
            Err(WebhookError::Expired)
        ));
    }

    /// A correctly signed token that simply omits `exp` altogether, the one
    /// shape `sign` above cannot produce. LiveKit's own signer always sets
    /// it; a token missing it must not be treated as never expiring.
    fn sign_without_exp(body: &[u8], api_key: &str, api_secret: &str) -> String {
        let header = BASE64URL.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
        let sha256 = BASE64STD.encode(Sha256::digest(body));
        let claims = serde_json::json!({ "iss": api_key, "sha256": sha256 });
        let payload = BASE64URL.encode(serde_json::to_vec(&claims).unwrap());
        let signing_input = format!("{header}.{payload}");
        let mut mac = <Hmac<Sha256>>::new_from_slice(api_secret.as_bytes()).unwrap();
        mac.update(signing_input.as_bytes());
        let signature = BASE64URL.encode(mac.finalize().into_bytes());
        format!("{signing_input}.{signature}")
    }

    #[test]
    fn a_validly_signed_token_with_no_exp_at_all_is_refused() {
        let body = br#"{"event":"participant_left"}"#;
        let token = sign_without_exp(body, API_KEY, API_SECRET);
        assert!(matches!(
            verify_and_parse(body, Some(&token), API_KEY, API_SECRET),
            Err(WebhookError::Malformed)
        ));
    }

    #[test]
    fn a_mismatched_issuer_is_refused() {
        let body = br#"{"event":"participant_left"}"#;
        let token = sign(body, "someone-elses-key", API_SECRET, 300);
        assert!(matches!(
            verify_and_parse(body, Some(&token), API_KEY, API_SECRET),
            Err(WebhookError::BadSignature)
        ));
    }

    #[test]
    fn a_missing_authorization_header_is_malformed_not_a_panic() {
        assert!(matches!(
            verify_and_parse(b"{}", None, API_KEY, API_SECRET),
            Err(WebhookError::Malformed)
        ));
    }

    #[test]
    fn screen_share_sources_match_permissively() {
        assert!(is_screen_share_source("SCREEN_SHARE"));
        assert!(is_screen_share_source("SCREEN_SHARE_AUDIO"));
        assert!(is_screen_share_source("SCREEN"));
        assert!(!is_screen_share_source("CAMERA"));
        assert!(!is_screen_share_source("MICROPHONE"));
    }
}
