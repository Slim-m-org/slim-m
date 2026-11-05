// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The push envelope: the only thing the relay, and the APNs and FCM
//! infrastructure it forwards through, ever sees.
//!
//! It is sealed with a libsodium-style anonymous sealed box (X25519 plus
//! XSalsa20Poly1305): encrypted to the device's registered public key, with no
//! sender identity of its own, which is the right shape here since the server
//! is not a party the device needs to authenticate, only a courier. Everything
//! outside the sealed box - platform, token, and the coarse `kind` - is
//! routing, and is all the relay is ever handed.
//!
//! **The relay cannot read an envelope, with or without content.** A device
//! that asked for it (see [`crate::store::PushTarget::include_content`]) gets
//! a preview of the message *inside* the sealed box, where it is exactly as
//! opaque to the relay as the channel id already was; every other device gets
//! the same content-free envelope as before, naming nothing but where to
//! catch up from. Sealing is per device, so one device opting in never widens
//! what another device's envelope carries, and no plaintext of either shape
//! ever leaves this function. `tests/push_content_envelope.rs` asserts that
//! structurally against the serialized relay-bound body rather than trusting
//! this paragraph.
//!
//! The preview is bounded twice over, because an envelope too large to send
//! is a notification silently lost rather than a visible error:
//! [`MessagePreview::new`] truncates each field on the way in, and
//! [`seal_for_message`] then measures the real serialized plaintext against
//! [`MAX_ENVELOPE_PLAINTEXT_BYTES`] and falls back to the content-free
//! envelope for that message if it still would not fit. Measuring the encoded
//! bytes rather than trusting the character caps is what makes that safe for
//! any display name or body, however many bytes its characters happen to
//! encode to once JSON-escaped.
//!
//! Every envelope, content-free ones included, also carries `sent_at`: the
//! millisecond this server sealed it. The relay is trusted to forward a
//! payload once, not to forget it, so a payload it retained and replayed
//! later would otherwise let a real preview resurface on a lock screen at an
//! arbitrary later time. The NSE
//! (`ios/NotificationService/PushEnvelope.swift`) is what actually refuses a
//! stale preview - this field only stamps the envelope so it can. `sent_at`
//! is additive: an older client reading a new envelope ignores a field it
//! does not know, and an NSE reading an envelope sealed before this field
//! existed treats absence as "not stale", never as a reason to refuse.

use std::collections::HashSet;

use serde::Serialize;

use crate::ids::{ChannelId, DeviceId, MessageId, Seq, UserId};
use crate::store::PushTarget;

use super::sealing::{TokenSlot, seal_to};

/// Domain-separates this plaintext from anything else that might ever be
/// sealed to the same device key, so a payload from a different context can
/// never be reinterpreted as a push envelope.
pub(super) const DOMAIN: &str = "slim-m.push.v1";
pub(super) const ENVELOPE_VERSION: u8 = 1;

/// X25519 public keys are exactly 32 bytes.
pub(super) const PUBLIC_KEY_BYTES: usize = 32;

/// How much base64 payload one relay-bound message may carry. The relay's own
/// ceiling is 4096 (`slim-m-relay`'s `maxPayloadBytes`, itself APNs' whole
/// remote-notification limit), and the `aps` dictionary and the `kind` field
/// ride in that same 4096 alongside the payload, so this leaves them room
/// rather than spending the entire budget here and having APNs refuse the
/// notification outright.
const MAX_PAYLOAD_BASE64_BYTES: usize = 3_600;

/// A sealed box is the 32-byte ephemeral public key plus a 16-byte
/// authentication tag on top of the plaintext.
const SEALED_BOX_OVERHEAD_BYTES: usize = 48;

/// The largest plaintext that can still base64-encode, once sealed, inside
/// [`MAX_PAYLOAD_BASE64_BYTES`]. Derived rather than written down, so
/// adjusting the payload ceiling cannot leave a stale plaintext limit behind
/// it.
pub(super) const MAX_ENVELOPE_PLAINTEXT_BYTES: usize =
    (MAX_PAYLOAD_BASE64_BYTES / 4) * 3 - SEALED_BOX_OVERHEAD_BYTES;

/// How much of a message body a preview carries. A lock screen shows far less
/// than this before eliding it anyway, and every byte here is a byte of the
/// envelope budget above.
const MAX_PREVIEW_BODY_CHARS: usize = 160;

/// How much of a display name or channel name a preview carries.
pub(super) const MAX_PREVIEW_NAME_CHARS: usize = 48;

/// Marks a body that was cut short, so a preview ending mid-word reads as
/// elided rather than as a truncation bug.
const ELISION: char = '\u{2026}';

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum PushKind {
    Message,
    /// A message that mentions its recipient; the relay alerts it as a mention.
    Mention,
    /// A DM call ring; see `call_ring::CallRingEnvelope`.
    Call,
    /// A ring that ended, so a device still showing it can stop; see `call_end`.
    #[serde(rename = "call_end")]
    CallEnd,
    /// A voice channel call started, grew or went live; see `voice_notice`.
    Voice,
    /// An account security alert; see `security`.
    Security,
}

impl PushKind {
    /// The relay's own `kind` field, a separate string from this envelope's
    /// serialized form (which lives inside the sealed, opaque payload).
    pub(super) fn wire_str(self) -> &'static str {
        match self {
            PushKind::Message => "message",
            PushKind::Mention => "mention",
            PushKind::Call => "call",
            PushKind::CallEnd => "call_end",
            PushKind::Voice => "voice",
            PushKind::Security => "security",
        }
    }
}

/// What a device that asked for content is told about the message, once
/// truncated. Built only by [`MessagePreview::new`], so nothing can construct
/// one carrying an unbounded body.
///
/// `channel` is absent for a DM and for a thread, both of which carry a
/// deliberately empty channel name: there is no name worth showing, and the
/// sender's own name already says where it came from.
pub(super) struct MessagePreview {
    sender: String,
    channel: Option<String>,
    body: String,
}

impl MessagePreview {
    /// Truncates each field to its cap. `channel` collapses to `None` when it
    /// is empty or whitespace-only, which is what a DM's and a thread's own
    /// channel row actually holds.
    pub(super) fn new(sender: &str, channel: &str, body: &str) -> Self {
        Self {
            sender: truncate(sender, MAX_PREVIEW_NAME_CHARS, false),
            channel: match channel.trim() {
                "" => None,
                name => Some(truncate(name, MAX_PREVIEW_NAME_CHARS, false)),
            },
            body: truncate(body.trim(), MAX_PREVIEW_BODY_CHARS, true),
        }
    }
}

/// Truncates to `max_chars` on a character boundary, appending [`ELISION`]
/// when `elide` and something was actually cut. Counted in characters rather
/// than bytes so a name in a non-Latin script is not cut to a fraction of the
/// length a Latin one keeps; the byte ceiling that actually matters is
/// enforced separately, against the encoded plaintext, in
/// [`seal_for_message`].
pub(super) fn truncate(value: &str, max_chars: usize, elide: bool) -> String {
    let mut kept: String = value.chars().take(max_chars).collect();
    if elide && value.chars().nth(max_chars).is_some() {
        kept.push(ELISION);
    }
    kept
}

/// The sealed plaintext. `sender`, `channel` and `body` are present only for a
/// device that asked for content; `skip_serializing_if` keeps them off the
/// wire entirely otherwise, rather than sending three nulls every device would
/// have to know to ignore.
///
/// New optional fields are additive for a reader that does not know them
/// (JSON), so growing this does not need [`ENVELOPE_VERSION`] bumped; a
/// change to what an existing field *means* would.
#[derive(Serialize)]
struct PushEnvelope<'a> {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    channel_id: String,
    message_id: String,
    seq: i64,
    /// Epoch milliseconds this server sealed the box, present unconditionally.
    /// See this module's own doc for why replay is not limited to the
    /// preview-carrying case.
    sent_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    sender: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    channel: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    body: Option<&'a str>,
}

impl<'a> PushEnvelope<'a> {
    fn for_message(
        channel_id: ChannelId,
        message_id: MessageId,
        seq: Seq,
        sent_at: i64,
        preview: Option<&'a MessagePreview>,
    ) -> Self {
        Self {
            domain: DOMAIN,
            version: ENVELOPE_VERSION,
            kind: PushKind::Message,
            channel_id: channel_id.to_string(),
            message_id: message_id.to_string(),
            seq: seq.0,
            sent_at,
            sender: preview.map(|p| p.sender.as_str()),
            channel: preview.and_then(|p| p.channel.as_deref()),
            body: preview.map(|p| p.body.as_str()),
        }
    }
}

/// One relay-bound message: a target's platform and token, the relay's own
/// `kind`, and the sealed, base64-encoded envelope. Deliberately not `Debug`:
/// `token` and `payload` are exactly what must never be logged.
///
/// `user_id` and `device_id` never leave this process (the relay is never
/// told them); they let the caller map a relay result and its bare `token`
/// back to the exact device it was actually sent to, for per-recipient
/// debounce bookkeeping and for scoping a dead-token clear to that device
/// rather than trusting the token string alone.
#[derive(Clone)]
pub(super) struct SealedMessage {
    pub(super) user_id: UserId,
    pub(super) device_id: DeviceId,
    pub(super) platform: String,
    pub(super) token: String,
    pub(super) slot: TokenSlot,
    pub(super) kind: &'static str,
    pub(super) payload: String,
}

/// Seals a new-message notification to every target's public key.
///
/// `sent_at` is the epoch millisecond this call is sealing at, stamped into
/// every resulting plaintext; see [`PushEnvelope`]'s own field doc for what
/// it is for.
///
/// `preview` is what a device that asked for content is told; a target whose
/// [`PushTarget::include_content`] is false is sealed the content-free
/// envelope regardless, so one device's choice can never reach another's. A
/// `None` preview means no device gets content, whatever any of them asked
/// for - the caller passes `None` when nothing opted in, or when the names it
/// needed could not be resolved.
///
/// A target is skipped, not sent plaintext, if its stored key cannot be
/// parsed as an X25519 public key: a corrupt key means that one device cannot
/// receive push until it re-registers, not that the batch should fail or fall
/// back to something unencrypted.
///
/// A target in `mentioned` goes to the relay as a mention; the sealed envelope is the same.
pub(super) fn seal_for_message(
    channel_id: ChannelId,
    message_id: MessageId,
    seq: Seq,
    sent_at: i64,
    preview: Option<&MessagePreview>,
    targets: &[PushTarget],
    mentioned: &HashSet<UserId>,
) -> Vec<SealedMessage> {
    let Some(bare) = encode(channel_id, message_id, seq, sent_at, None) else {
        return Vec::new();
    };
    // Past the ceiling falls back to content-free; see the module docs.
    let with_content = preview
        .and_then(|preview| encode(channel_id, message_id, seq, sent_at, Some(preview)))
        .filter(|plaintext| plaintext.len() <= MAX_ENVELOPE_PLAINTEXT_BYTES);

    targets
        .iter()
        .filter_map(|target| {
            let plaintext = match (target.include_content, &with_content) {
                (true, Some(with_content)) => with_content,
                _ => &bare,
            };
            let kind = if mentioned.contains(&target.user_id) {
                PushKind::Mention
            } else {
                PushKind::Message
            };
            seal_to(target, TokenSlot::Push, kind, plaintext)
        })
        .collect()
}

/// Serializes one envelope shape, or `None` if it somehow will not encode -
/// which would be a bug rather than a runtime condition, so it is logged and
/// treated as "send nothing" rather than falling back to anything unsealed.
fn encode(
    channel_id: ChannelId,
    message_id: MessageId,
    seq: Seq,
    sent_at: i64,
    preview: Option<&MessagePreview>,
) -> Option<Vec<u8>> {
    let envelope = PushEnvelope::for_message(channel_id, message_id, seq, sent_at, preview);
    match serde_json::to_vec(&envelope) {
        Ok(bytes) => Some(bytes),
        Err(err) => {
            tracing::error!(error = %err, "push: envelope failed to serialize");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_body_past_the_cap_is_cut_on_a_character_boundary_and_elided() {
        let body = "e".repeat(MAX_PREVIEW_BODY_CHARS + 40);
        let preview = MessagePreview::new("Ada", "general", &body);
        assert_eq!(preview.body.chars().count(), MAX_PREVIEW_BODY_CHARS + 1);
        assert!(preview.body.ends_with(ELISION));
    }

    /// A cap counted in bytes would slice a multi-byte character in half and
    /// panic, or silently produce invalid UTF-8; counting characters is what
    /// makes a non-Latin body safe to truncate at all.
    #[test]
    fn a_multibyte_body_truncates_without_splitting_a_character() {
        let body = "\u{3053}".repeat(MAX_PREVIEW_BODY_CHARS + 10);
        let preview = MessagePreview::new("Ada", "general", &body);
        assert_eq!(preview.body.chars().count(), MAX_PREVIEW_BODY_CHARS + 1);
    }

    #[test]
    fn a_body_at_or_under_the_cap_is_untouched_and_unelided() {
        let body = "e".repeat(MAX_PREVIEW_BODY_CHARS);
        let preview = MessagePreview::new("Ada", "general", &body);
        assert_eq!(preview.body, body);
        assert!(!preview.body.ends_with(ELISION));
    }

    /// A DM and a thread both carry a deliberately empty channel name, and an
    /// empty string is not a name worth putting on a lock screen.
    #[test]
    fn an_empty_channel_name_is_absent_rather_than_blank() {
        assert!(MessagePreview::new("Ada", "", "hi").channel.is_none());
        assert!(MessagePreview::new("Ada", "   ", "hi").channel.is_none());
        assert_eq!(
            MessagePreview::new("Ada", "general", "hi")
                .channel
                .as_deref(),
            Some("general")
        );
    }

    /// The fallback [`seal_for_message`] degrades to has to fit
    /// unconditionally, or a preview over the ceiling would degrade to
    /// something equally unsendable and the push would be lost either way.
    /// Nothing in it is variable-length except two uuids, a seq and a
    /// `sent_at`, so this is really a guard against a future field being
    /// added outside a preview.
    #[test]
    fn the_content_free_envelope_always_fits_the_budget() {
        let bare = encode(
            ChannelId::generate(),
            MessageId::generate(),
            Seq(1),
            i64::MAX,
            None,
        )
        .expect("the content-free envelope always encodes");
        assert!(
            bare.len() <= MAX_ENVELOPE_PLAINTEXT_BYTES,
            "the content-free envelope must always fit, or nothing could ever be sent"
        );
    }

    /// The character caps and the byte budget are two separate numbers, and
    /// nothing but arithmetic ties them together - so this does the
    /// arithmetic, against the worst input the caps actually allow rather
    /// than a comfortable ASCII one.
    ///
    /// A control character is serde_json's most expensive: it escapes to six
    /// bytes, where even a 4-byte emoji is emitted as its own 4 UTF-8 bytes
    /// (serde_json does not escape non-ASCII at all). If a preview built
    /// entirely from those still fits, no real one can miss.
    ///
    /// This is what makes [`seal_for_message`]'s own runtime ceiling a
    /// backstop rather than a live code path: at today's caps it can never
    /// fire, and raising [`MAX_PREVIEW_BODY_CHARS`] or
    /// [`MAX_PREVIEW_NAME_CHARS`] past what the budget can hold fails here,
    /// pointing at this arithmetic, instead of silently turning every long
    /// message's push back into a content-free one at runtime.
    #[test]
    fn the_worst_preview_the_caps_allow_still_fits_the_byte_budget() {
        let worst = |n: usize| "\u{1f}".repeat(n);
        let preview = MessagePreview {
            sender: worst(MAX_PREVIEW_NAME_CHARS),
            channel: Some(worst(MAX_PREVIEW_NAME_CHARS)),
            // One over the cap: the elision is appended past it.
            body: format!("{}{ELISION}", worst(MAX_PREVIEW_BODY_CHARS)),
        };
        let encoded = encode(
            ChannelId::generate(),
            MessageId::generate(),
            Seq(i64::MAX),
            i64::MAX,
            Some(&preview),
        )
        .expect("a full-size preview encodes");
        assert!(
            encoded.len() <= MAX_ENVELOPE_PLAINTEXT_BYTES,
            "the worst preview the caps allow must still fit: {} bytes against a \
             {MAX_ENVELOPE_PLAINTEXT_BYTES}-byte budget. Lower a preview cap, or raise \
             MAX_PAYLOAD_BASE64_BYTES - but it cannot go past the relay's own 4096, which \
             is APNs' whole-notification ceiling and has to hold the aps dictionary too.",
            encoded.len()
        );
    }

    /// `sent_at` rides on a content-free envelope too, not only a preview -
    /// replay is a property of the envelope, not of what it happens to carry.
    #[test]
    fn sent_at_is_present_on_a_content_free_envelope() {
        let encoded = encode(
            ChannelId::generate(),
            MessageId::generate(),
            Seq(1),
            1_700_000_000_000,
            None,
        )
        .expect("encodes");
        let value: serde_json::Value = serde_json::from_slice(&encoded).expect("valid json");
        assert_eq!(value["sent_at"], 1_700_000_000_000_i64);
    }

    /// And it rides alongside a preview, at the same value passed in - this is
    /// the plaintext-level half of the replay defense; the sealed-round-trip
    /// half lives in `tests/push_content_envelope.rs`, which actually unseals
    /// real ciphertext rather than inspecting the plaintext before sealing.
    #[test]
    fn sent_at_is_present_alongside_a_preview_at_the_value_passed_in() {
        let preview = MessagePreview::new("Ada", "general", "hi");
        let encoded = encode(
            ChannelId::generate(),
            MessageId::generate(),
            Seq(1),
            1_700_000_000_000,
            Some(&preview),
        )
        .expect("encodes");
        let value: serde_json::Value = serde_json::from_slice(&encoded).expect("valid json");
        assert_eq!(value["sent_at"], 1_700_000_000_000_i64);
        assert_eq!(value["body"], "hi");
    }
}
