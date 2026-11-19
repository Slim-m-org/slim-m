// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Sealing one plaintext to one device, shared by every push kind.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use crypto_box::PublicKey;
use crypto_box::aead::OsRng;

use super::envelope::{PUBLIC_KEY_BYTES, PushKind, SealedMessage};
use crate::store::PushTarget;

/// Which of a device's two tokens a push went to, so a dead one is cleared without the other.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TokenSlot {
    Push,
    Voip,
}

/// The token `slot` names on `target`, if the device registered one.
pub(super) fn token_in(target: &PushTarget, slot: TokenSlot) -> Option<&str> {
    match slot {
        TokenSlot::Push => Some(target.push_token.as_str()),
        TokenSlot::Voip => target.voip_push_token.as_deref(),
    }
}

/// Seals `plaintext` to `target`'s key for delivery to its `slot` token, or `None` (logged)
/// when the device has no such token, a malformed key, or the seal fails.
pub(super) fn seal_to(
    target: &PushTarget,
    slot: TokenSlot,
    kind: PushKind,
    plaintext: &[u8],
) -> Option<SealedMessage> {
    let token = token_in(target, slot)?;
    let Ok(key_bytes) = <[u8; PUBLIC_KEY_BYTES]>::try_from(target.push_public_key.as_slice())
    else {
        tracing::warn!(
            device_id = %target.device_id,
            "push: stored public key is the wrong size, skipping this device"
        );
        return None;
    };
    let Ok(ciphertext) = PublicKey::from_bytes(key_bytes).seal(&mut OsRng, plaintext) else {
        tracing::warn!(device_id = %target.device_id, "push: sealing failed, skipping this device");
        return None;
    };
    Some(SealedMessage {
        user_id: target.user_id,
        device_id: target.device_id,
        platform: target.platform.clone(),
        token: token.to_owned(),
        slot,
        kind: kind.wire_str(),
        payload: BASE64.encode(ciphertext),
    })
}
