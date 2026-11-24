// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Listing who is connected to a channel's voice room right now.
//!
//! This is the read-only half of [`super::VoiceService`]: unlike minting a
//! token, which is pure local signing, listing participants is a real round
//! trip to the SFU's room service, so it costs exactly what [`super::mint`]
//! does not. The caller decides how often that is worth paying for and who
//! among the result a given viewer may actually be told about; this only
//! reports who the SFU says is connected.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::ids::{ChannelId, UserId};

use super::webhook::is_screen_share_source;
use super::{VoiceError, VoiceService, room_for_channel};

/// One participant the SFU reports as currently connected to a room.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomParticipant {
    /// The token's `sub`, the identity LiveKit trusts because we signed it.
    pub user_id: UserId,
    /// LiveKit's id for this connection, which tells one session of a member from the next.
    pub sid: String,
    /// The token's `name`, as it was when this participant joined.
    pub display_name: String,
    /// Whether any of this participant's published tracks is screen-share
    /// sourced. Read straight off this same `ListParticipants` response, so
    /// it stays correct even on a deployment with no LiveKit webhook
    /// configured; see `docs/decisions/0032-voice-participant-webhooks.md`.
    pub is_sharing_screen: bool,
    /// Whether any of this participant's published tracks is video, camera
    /// or screen share alike - free from the same response as
    /// `is_sharing_screen`.
    pub has_video: bool,
    /// When this participant joined the room, in unix milliseconds, as the
    /// SFU reports it. `None` when the SFU predates the field.
    pub joined_at_ms: Option<i64>,
    /// The device tag the token was minted for, the raw device id on older tokens, `None` on older still.
    pub device_id: Option<String>,
    /// The token's [`super::HOLDER_ATTRIBUTE`]; `None` on a token minted before it existed.
    pub holder: Option<String>,
    /// Whether the SFU reports this connection `ACTIVE`: signalling and media both up.
    pub is_active: bool,
    /// No unmuted audio track, the rule a joined client applies to the same participant.
    pub is_muted: bool,
    /// Whether the server published this participant's deafened attribute.
    pub is_deafened: bool,
}

/// How long a roster read is reused. Webhook events drop it sooner, so this only bounds a missed webhook.
const ROSTER_TTL: Duration = Duration::from_secs(2);

struct CachedRoster {
    fetched: Instant,
    participants: Vec<RoomParticipant>,
}

type Slot = Arc<tokio::sync::Mutex<Option<CachedRoster>>>;

/// Roster reads shared per channel: concurrent and repeated polls make one SFU call.
#[derive(Clone, Default)]
pub struct RosterCache {
    entries: Arc<Mutex<HashMap<ChannelId, Slot>>>,
    epoch: Arc<AtomicU64>,
}

impl RosterCache {
    fn slot(&self, channel_id: ChannelId) -> Slot {
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.entry(channel_id).or_default().clone()
    }

    /// Forgets what is known about the room, for a webhook that says it changed.
    pub fn invalidate(&self, channel_id: ChannelId) {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        let mut entries = self
            .entries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.remove(&channel_id);
    }
}

/// LiveKit's JSON carries int64 fields as strings; accept either form.
pub(super) fn lenient_i64<'de, D>(d: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize as _;
    Ok(match Option::<serde_json::Value>::deserialize(d)? {
        Some(serde_json::Value::Number(n)) => n.as_i64(),
        Some(serde_json::Value::String(t)) => t.parse().ok(),
        _ => None,
    })
}

/// When a participant joined in unix milliseconds, from LiveKit's millisecond field or else its seconds one.
pub(super) fn joined_at_from(millis: Option<i64>, secs: Option<i64>) -> Option<i64> {
    millis
        .filter(|&ms| ms > 0)
        .or(secs.filter(|&s| s > 0).map(|s| s * 1000))
}

/// The shape of a LiveKit `ListParticipants` twirp response; only the fields
/// this crate reads.
#[derive(serde::Deserialize)]
struct ListParticipantsResponse {
    #[serde(default)]
    participants: Vec<ParticipantInfo>,
}

#[derive(serde::Deserialize)]
struct ParticipantInfo {
    identity: String,
    #[serde(default)]
    sid: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    tracks: Vec<TrackInfo>,
    #[serde(default, alias = "joinedAtMs", deserialize_with = "lenient_i64")]
    joined_at_ms: Option<i64>,
    #[serde(default, alias = "joinedAt", deserialize_with = "lenient_i64")]
    joined_at: Option<i64>,
    #[serde(default)]
    attributes: std::collections::HashMap<String, String>,
    #[serde(default)]
    state: serde_json::Value,
}

#[derive(serde::Deserialize)]
struct TrackInfo {
    #[serde(default)]
    source: String,
    #[serde(rename = "type", default)]
    track_type: String,
    #[serde(default)]
    muted: bool,
}

/// LiveKit's `ParticipantInfo.State.ACTIVE`, by name or by number.
fn is_active_state(state: &serde_json::Value) -> bool {
    match state {
        serde_json::Value::String(name) => name == "ACTIVE",
        serde_json::Value::Number(n) => n.as_u64() == Some(2),
        _ => false,
    }
}

fn has_no_live_audio(tracks: &[TrackInfo]) -> bool {
    tracks
        .iter()
        .filter(|t| t.track_type == "AUDIO")
        .all(|t| t.muted)
}

impl VoiceService {
    pub fn roster_cache(&self) -> RosterCache {
        self.roster_cache.clone()
    }

    /// [`Self::list_participants`] reused for [`ROSTER_TTL`], for callers that only show or address
    /// who is present, such as the polled roster route and live transcript lines.
    ///
    /// Callers that act on who is present (cleanup, call rings) keep asking the SFU directly.
    pub async fn list_participants_shared(
        &self,
        channel_id: ChannelId,
    ) -> Result<Vec<RoomParticipant>, VoiceError> {
        let slot = self.roster_cache.slot(channel_id);
        let mut held = slot.lock().await;
        if let Some(cached) = held.as_ref().filter(|c| c.fetched.elapsed() < ROSTER_TTL) {
            return Ok(cached.participants.clone());
        }
        let epoch = self.roster_cache.epoch.load(Ordering::Acquire);
        let participants = self.list_participants(channel_id).await?;
        if self.roster_cache.epoch.load(Ordering::Acquire) == epoch {
            *held = Some(CachedRoster {
                fetched: Instant::now(),
                participants: participants.clone(),
            });
        }
        Ok(participants)
    }

    /// Lists who is currently connected to a channel's voice room.
    ///
    /// A room nobody has ever joined does not exist yet as far as the SFU is
    /// concerned, and that answers identically to a room that emptied back
    /// out: nobody is there, not an error.
    pub async fn list_participants(
        &self,
        channel_id: ChannelId,
    ) -> Result<Vec<RoomParticipant>, VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        // An empty room and a room that was never created answer the same way.
        let Some(response) = self
            .room_service_call(
                enabled,
                "ListParticipants",
                &room,
                serde_json::json!({ "room": room }),
            )
            .await?
        else {
            return Ok(Vec::new());
        };

        let body: ListParticipantsResponse = response
            .json()
            .await
            .map_err(|e| VoiceError::Internal(e.into()))?;

        Ok(body
            .participants
            .into_iter()
            .filter_map(|p| {
                // Parsed back rather than trusted: mint() set it to this user's id.
                let user_id = UserId(p.identity.parse().ok()?);
                let is_sharing_screen = p.tracks.iter().any(|t| is_screen_share_source(&t.source));
                let has_video = p.tracks.iter().any(|t| t.track_type == "VIDEO");
                Some(RoomParticipant {
                    user_id,
                    sid: p.sid,
                    display_name: p.name.unwrap_or_default(),
                    is_sharing_screen,
                    has_video,
                    joined_at_ms: joined_at_from(p.joined_at_ms, p.joined_at),
                    device_id: p.attributes.get(super::DEVICE_ATTRIBUTE).cloned(),
                    holder: p.attributes.get(super::HOLDER_ATTRIBUTE).cloned(),
                    is_active: is_active_state(&p.state),
                    is_muted: has_no_live_audio(&p.tracks),
                    is_deafened: p
                        .attributes
                        .get(super::DEAFENED_ATTRIBUTE)
                        .map(String::as_str)
                        == Some(super::DEAFENED_ATTRIBUTE_ON),
                })
            })
            .collect())
    }
}

#[cfg(test)]
mod tests;
