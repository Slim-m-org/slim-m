// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Channel routes: list, create, rename, and soft-delete.
//!
//! Listing is filtered per caller, so a channel you cannot view is simply not
//! in your list. Every mutation - create, rename, delete - checks
//! MANAGE_CHANNELS at the deployment level (like [`Store::base_permissions`],
//! not [`Store::has_permission`]), which on a fresh deployment only the
//! bootstrap admin holds. A per-channel overwrite is deliberately not
//! consulted here: a channel-scoped check would make a delete of an
//! already-deleted channel indistinguishable from "no permission" (a deleted
//! channel evaluates to no permissions at all), breaking the idempotency a
//! retry needs. The base check also still hides which ids are real from
//! anyone without MANAGE_CHANNELS, which is the population that check is
//! actually protecting against; an existing channel manager is not an
//! attacker this needs to hide anything from.

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::{get, patch};
use serde::{Deserialize, Serialize};

use self::channel_slow_mode::validate_slow_mode_seconds;
use self::channel_validation::{
    JOIN_MUTED_VOICE_ONLY, ROOMS_VOICE_ONLY, validate_channel_name, validate_channel_topic,
    validate_default_notification, validate_user_limit,
};
use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelCategoryId, ChannelId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Channel, ChannelDefaults, ChannelPatch, DM_CHANNEL_KIND, DeleteChannelError};
use crate::voice::VoiceError;

pub(super) mod channel_notification_prefs;
pub(super) mod channel_order;
pub(super) mod channel_permissions;
pub(super) mod channel_retention;
pub(super) mod channel_slow_mode;
pub(super) mod channel_validation;

const CHANNEL_BODY_LIMIT: usize = 4 * 1024;

/// The channel routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/channels", get(list).post(create))
        .route("/channels/{channel_id}", patch(update).delete(delete))
        .layer(DefaultBodyLimit::max(CHANNEL_BODY_LIMIT))
}

/// `pub(crate)` so `http::ws` can reuse the exact same wire shape for the
/// live `channel.created`/`channel.updated` frames, the way `MessageDto`
/// already does for messages.
#[derive(Serialize)]
pub(crate) struct ChannelDto {
    id: String,
    name: String,
    kind: String,
    /// `null` for no topic. A client shows this as a one-line description
    /// beside the channel name; absence and an empty topic are treated as
    /// the same thing, so this is never `Some("")` - see
    /// [`validate_channel_topic`].
    topic: Option<String>,
    /// Sort key among the deployment's live, non-DM channels: lower sorts
    /// first. Set via `PUT /channels/order`, deployment-wide rather than
    /// per-device. Meaningless on a DM, which never appears in this list.
    position: i64,
    /// The message this channel is a thread of, or `null` for an ordinary
    /// channel. A thread's own `kind` and permissions are never what govern
    /// it: `VIEW_CHANNEL`/`SEND_MESSAGES` here inherit the parent message's
    /// own channel, resolved live rather than copied - see
    /// docs/decisions/0005-threads.md. A thread never appears in
    /// `listChannels`; reach one through `openThread`.
    parent_message_id: Option<String>,
    /// The rail section this channel is filed under, or `null` for
    /// uncategorised - rendered as an implicit section above every named
    /// category. Decides placement only: see
    /// docs/decisions/0006-channel-categories.md. Absent on servers older
    /// than this field, which a client must treat as unknown rather than
    /// assuming uncategorised.
    category_id: Option<String>,
    created_at: i64,
    /// The caller's own effective permission bitmask in this channel,
    /// already resolved through thread and DM handling with any timeout
    /// subtracted - the batched sibling of `GET
    /// /channels/{channelId}/permissions`. Present only on `listChannels`:
    /// every row there already carries VIEW_CHANNEL by construction, so
    /// unlike the dedicated route this needs no existence-probe mask, and
    /// it costs no extra query since `Store::visible_channels_with_permissions`
    /// already computes it. Absent (not `Some(0)`) from create, update,
    /// reorder, and the live `channel.created`/`channel.updated` frames:
    /// none of those has one single caller whose bitmask would be right to
    /// embed, and a live frame in particular fans out to many receivers
    /// holding different permissions.
    #[serde(skip_serializing_if = "Option::is_none")]
    permissions: Option<i64>,
    /// The minimum interval, in seconds, a non-`MANAGE_CHANNELS` member must
    /// wait between their own messages here. 0 means off - see
    /// `channel_slow_mode::enforce_slow_mode`. Always present, unlike
    /// `permissions`: every channel has one value for this, not one per
    /// caller, so there is no reason to omit it anywhere `ChannelDto`
    /// appears.
    slow_mode_seconds: i64,
    /// Whether joining this voice channel starts with the mic off. A
    /// default members can override, not a lock; always present.
    join_muted: bool,
    /// What members with no choice of their own get here: `everything`,
    /// `mentions` or `nothing`. Always present.
    default_notification: &'static str,
    /// A voice lobby that makes a room per person; see decision 0065.
    creates_rooms: bool,
    /// The most people a voice channel's call takes, 0 for no limit.
    user_limit: i64,
    /// Set only on a temporary room: who owns it.
    #[serde(skip_serializing_if = "Option::is_none")]
    room_owner_id: Option<String>,
    /// Set only on a temporary room: whether nobody new may join.
    #[serde(skip_serializing_if = "Option::is_none")]
    room_locked: Option<bool>,
    /// Whether `@everyone` lacks VIEW_CHANNEL here, so the channel is hidden
    /// from ordinary members rather than visible to anyone in the
    /// deployment. Identical for every caller, unlike `permissions` - see
    /// `Store::channel_permissions_all`. Present only on `listChannels`, for
    /// the same reason `permissions` is: no other response has a channel row
    /// worth annotating this way.
    #[serde(skip_serializing_if = "Option::is_none")]
    restricted: Option<bool>,
}

impl From<Channel> for ChannelDto {
    fn from(channel: Channel) -> Self {
        Self {
            id: channel.id.to_string(),
            name: channel.name,
            kind: channel.kind,
            topic: channel.topic,
            position: channel.position,
            parent_message_id: channel.parent_message_id.map(|id| id.to_string()),
            category_id: channel.category_id.map(|id| id.to_string()),
            created_at: channel.created_at,
            permissions: None,
            slow_mode_seconds: channel.slow_mode_seconds,
            join_muted: channel.join_muted,
            default_notification: channel.default_notification.as_str(),
            creates_rooms: channel.room.creates_rooms,
            user_limit: channel.room.user_limit,
            room_owner_id: channel.room.owner_id.map(|id| id.to_string()),
            room_locked: channel.room.is_room().then_some(channel.room.locked),
            restricted: None,
        }
    }
}

impl ChannelDto {
    /// A channel row with the reader-independent `restricted` fact attached.
    pub(crate) fn with_restricted(channel: Channel, restricted: bool) -> Self {
        Self {
            restricted: Some(restricted),
            ..Self::from(channel)
        }
    }
}

#[derive(Deserialize)]
struct CreateRequest {
    /// Client-generated UUIDv7 that makes the create idempotent on retry.
    /// Absent means the server mints one and this is always a fresh create.
    id: Option<String>,
    name: String,
    /// "text" or "voice"; defaults to text.
    kind: Option<String>,
    /// The rail section to file this channel under, or absent for
    /// uncategorised. Lets a client create straight into the category a
    /// person asked from, rather than creating uncategorised and following
    /// up with a reorder - two calls whose second one can fail on its own
    /// and leave the channel somewhere nobody chose. A category that does
    /// not exist is a 400, never a silent fall back to uncategorised.
    #[serde(default)]
    category_id: Option<String>,
    /// True to deny `@everyone` VIEW_CHANNEL here and grant it only to the
    /// creator, closing the window a create-then-restrict two-step leaves
    /// open where the channel exists and is visible to everyone before a
    /// follow-up edit narrows it. Absent or false creates a channel visible
    /// to `@everyone` as usual. Requires MANAGE_ROLES in addition to the
    /// MANAGE_CHANNELS this route already needs - see `create`'s own doc for
    /// why. No role picker: others are added afterwards through the existing
    /// channel-permissions surface.
    #[serde(default)]
    restricted: Option<bool>,
    /// True creates a voice channel that starts every join with the mic off.
    /// Absent or false leaves the default off.
    #[serde(default)]
    join_muted: Option<bool>,
    /// The notification level members get here until they choose their own.
    /// Absent means `everything`. Needs MANAGE_CHANNELS like the rest of create.
    #[serde(default)]
    default_notification: Option<String>,
}

#[derive(Deserialize)]
struct UpdateChannelRequest {
    /// Absent leaves the name unchanged - both fields on this request are
    /// optional, the same "at least one, absent means untouched" convention
    /// `roles::UpdateRoleRequest` uses for its own two optional fields.
    #[serde(default)]
    name: Option<String>,
    /// Absent leaves the topic unchanged; present (even as an empty or
    /// whitespace-only string) replaces it, clearing it back to `None` if the
    /// trimmed value is blank - see [`validate_channel_topic`].
    #[serde(default)]
    topic: Option<String>,
    /// Absent leaves the slow-mode interval unchanged; present replaces it.
    /// 0 turns slow mode off. Refused, not clamped, outside
    /// `0..=SLOW_MODE_MAX_SECONDS` - see [`validate_slow_mode_seconds`].
    #[serde(default)]
    slow_mode_seconds: Option<i64>,
    /// Absent leaves the join-muted default unchanged; present replaces it.
    #[serde(default)]
    join_muted: Option<bool>,
    /// Absent leaves the default notification level unchanged; members' own
    /// choices are never rewritten.
    #[serde(default)]
    default_notification: Option<String>,
    /// Voice only: makes this channel a lobby for temporary rooms.
    #[serde(default)]
    creates_rooms: Option<bool>,
    /// Voice only: the most people in the call, 0 for no limit.
    #[serde(default)]
    user_limit: Option<i64>,
}

/// Lists the channels the caller can view. One batched store call: the
/// per-channel has_permission loop this replaces cost 1 + 4C queries.
///
/// Answers a plain array, exactly as it always has: the wire is
/// additive-only, and a live deployment auto-updating from `latest` while
/// its phones update on their own TestFlight/Play schedule means reshaping
/// this response would break every client that has not updated yet. Every
/// live category is at `GET /categories` instead - a new route is additive,
/// folding the list into this one's body is not.
///
/// Each row's `permissions` and `restricted` ride along free:
/// `visible_channels_with_permissions` already evaluates the full bitmask to
/// decide VIEW_CHANNEL membership and `@everyone`'s own view of the channel
/// alongside it, so carrying both into the response is a change to what
/// gets kept, not a new query.
async fn list(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<ChannelDto>>, ApiError> {
    let visible = state
        .store
        .visible_channels_with_permissions(ctx.user_id)
        .await?
        .into_iter()
        .map(|(channel, permissions, restricted)| ChannelDto {
            permissions: Some(permissions.bits()),
            restricted: Some(restricted),
            ..ChannelDto::from(channel)
        })
        .collect();
    Ok(Json(visible))
}

/// Creates a channel. Requires MANAGE_CHANNELS at the deployment level, and,
/// only when `restricted` is set, MANAGE_ROLES as well: writing the
/// overwrites a private channel needs is a permissions edit, and a
/// MANAGE_CHANNELS holder without MANAGE_ROLES must not gain a new way to do
/// that just because it happens at create time. Denying `@everyone` and
/// granting the creator escalates nothing the creator lacks, so this is not
/// the privilege-escalation case `set_role_overwrite`'s callers otherwise
/// guard against.
async fn create(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<CreateRequest>,
) -> Result<Json<ChannelDto>, ApiError> {
    // Charged like rename and delete, which both do; create was the one write
    // in this file that was not, so it could be looped without limit.
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let base_permissions = state.store.base_permissions(ctx.user_id).await?;
    if !base_permissions.contains(Permissions::MANAGE_CHANNELS) {
        return Err(ApiError::Forbidden);
    }

    let name = validate_channel_name(&req.name)?;
    let kind = req.kind.as_deref().unwrap_or("text");
    if !matches!(kind, "text" | "voice") {
        return Err(ApiError::BadRequest("kind must be text or voice"));
    }
    if req.join_muted == Some(true) && kind != "voice" {
        return Err(ApiError::BadRequest(JOIN_MUTED_VOICE_ONLY));
    }
    let default_notification = req
        .default_notification
        .as_deref()
        .map(validate_default_notification)
        .transpose()?
        .unwrap_or_default();
    let id = req
        .id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(ChannelId))
        .transpose()?
        .unwrap_or_else(ChannelId::generate);

    let category_id = req
        .category_id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(ChannelCategoryId))
        .transpose()?;

    let restricted = req.restricted.unwrap_or(false);
    if restricted && !base_permissions.contains(Permissions::MANAGE_ROLES) {
        return Err(ApiError::Forbidden);
    }
    let private_to = restricted.then_some(ctx.user_id);

    let created = state
        .store
        .create_channel_with_id(
            id,
            name,
            kind,
            category_id,
            private_to,
            ChannelDefaults {
                join_muted: req.join_muted == Some(true),
                notification: default_notification,
            },
        )
        .await?;
    let channel = created.channel;
    let restricted = state.store.channel_restricted(channel.id).await?;
    // An idempotent retry must not fan out again; see the note on `CreatedChannel::fresh`.
    if created.fresh {
        state
            .hub
            .publish(Event::ChannelCreated(Arc::new(channel.clone()), restricted));
    }
    Ok(Json(ChannelDto::with_restricted(channel, restricted)))
}

/// Renames a channel, replaces its topic, and/or sets its slow-mode interval.
/// Requires MANAGE_CHANNELS at the deployment level - the same gate `create`
/// and `delete` use, not a new one for the topic or slow-mode half of this
/// route.
async fn update(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<UpdateChannelRequest>,
) -> Result<Json<ChannelDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    if !state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_CHANNELS)
    {
        return Err(ApiError::Forbidden);
    }

    let name = req.name.as_deref().map(validate_channel_name).transpose()?;
    let topic = req
        .topic
        .as_deref()
        .map(validate_channel_topic)
        .transpose()?;
    let slow_mode_seconds = req
        .slow_mode_seconds
        .map(validate_slow_mode_seconds)
        .transpose()?;
    let user_limit = req.user_limit.map(validate_user_limit).transpose()?;
    let default_notification = req
        .default_notification
        .as_deref()
        .map(validate_default_notification)
        .transpose()?;
    if name.is_none()
        && topic.is_none()
        && slow_mode_seconds.is_none()
        && req.join_muted.is_none()
        && default_notification.is_none()
        && req.creates_rooms.is_none()
        && user_limit.is_none()
    {
        return Err(ApiError::BadRequest("nothing to update"));
    }
    let makes_rooms = req.creates_rooms == Some(true);
    let limits = user_limit.is_some_and(|limit| limit > 0);
    if req.join_muted == Some(true) || makes_rooms || limits {
        let current = state
            .store
            .channel(channel_id)
            .await?
            .ok_or(ApiError::NotFound("channel not found"))?;
        if current.kind != "voice" && req.join_muted == Some(true) {
            return Err(ApiError::BadRequest(JOIN_MUTED_VOICE_ONLY));
        }
        if (makes_rooms || limits) && current.kind != "voice"
            || makes_rooms && current.room.is_room()
        {
            return Err(ApiError::BadRequest(ROOMS_VOICE_ONLY));
        }
    }

    let channel = state
        .store
        .update_channel_settings(
            channel_id,
            ChannelPatch {
                name,
                topic: topic.as_ref().map(|t| t.as_deref()),
                slow_mode_seconds,
                join_muted: req.join_muted,
                default_notification,
                creates_rooms: req.creates_rooms,
                user_limit,
                room_locked: None,
            },
        )
        .await?
        .ok_or(ApiError::NotFound("channel not found"))?;
    let restricted = state.store.channel_restricted(channel_id).await?;
    state
        .hub
        .publish(Event::ChannelUpdated(Arc::new(channel.clone()), restricted));
    Ok(Json(ChannelDto::with_restricted(channel, restricted)))
}

/// Soft-deletes a channel. Requires MANAGE_CHANNELS at the deployment level.
///
/// Refuses to delete the deployment's last live channel: with zero channels
/// left nobody has anywhere to land, which is exactly why bootstrap seeds a
/// `general` channel for a fresh deployment in the first place. A second
/// delete of an already-deleted channel is not an error, matching the rest of
/// this API's delete verbs; a channel id that was never real is a plain 404,
/// same as it would be for any other resource a manager is allowed to see.
///
/// The row is fetched regardless of `deleted_at`, because telling "already
/// gone" apart from "never existed" is what makes that retry succeed.
///
/// A DM is a channel of kind `dm` in the same table, and it is not a
/// manageable channel: its only access rule is membership of the pair, which
/// this deployment-wide check knows nothing about. The store refuses it too,
/// but it can only answer "no rows matched", which this handler would report
/// as the last-channel conflict. Answering 404 here keeps the status honest
/// and matches how a DM is invisible to `GET /channels`.
async fn delete(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);

    if !state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_CHANNELS)
    {
        return Err(ApiError::Forbidden);
    }

    // Includes soft-deleted rows so a retry succeeds; see the note above.
    let channel = state
        .store
        .channel_including_deleted(channel_id)
        .await?
        .ok_or(ApiError::NotFound("channel not found"))?;

    // 404 rather than letting the store's "no rows" surface as a conflict;
    // see the note above.
    if channel.kind == DM_CHANNEL_KIND {
        return Err(ApiError::NotFound("channel not found"));
    }

    match state.store.delete_channel(channel_id).await {
        Ok(deleted) => {
            end_voice_room(&state, channel_id).await;
            // Only a genuine delete is worth publishing; a retry changes nothing.
            if deleted {
                state.hub.publish(Event::ChannelDeleted { channel_id });
            }
            Ok(StatusCode::NO_CONTENT)
        }
        Err(DeleteChannelError::LastChannel) => Err(ApiError::Conflict(
            "cannot delete the deployment's last channel",
        )),
        Err(DeleteChannelError::Internal(e)) => Err(e.into()),
    }
}

/// Ends any voice room the deleted channel was still hosting.
///
/// A LiveKit token is a bearer credential this server cannot revoke, so
/// deleting the channel row on its own left a live call running in a channel
/// that no longer existed, with every participant free to stay and anybody
/// holding an unexpired token free to rejoin it.
///
/// Called for every deleted channel rather than only a `voice` one, and on an
/// idempotent retry as well as a genuine delete: the end state this wants is
/// "no room", which is already true for a channel that never had one, and a
/// retry is the natural second chance if the first attempt could not reach
/// the SFU.
async fn end_voice_room(state: &AppState, channel_id: ChannelId) {
    match state.voice.delete_room(channel_id).await {
        // No SFU configured at all: there is no room to end.
        Ok(()) | Err(VoiceError::Unavailable) => {}
        Err(VoiceError::Internal(err)) => {
            tracing::warn!(%err, "could not end the deleted channel's voice room");
        }
    }
}
