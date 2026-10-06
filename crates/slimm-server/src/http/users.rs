// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! User profile routes: the caller's own account (`/me`), public profiles
//! (`/users`), and the deployment's member list (`/members`).
//!
//! Every profile returned here is the narrow public shape only: id,
//! username, display name, and creation time. Nothing from the auth tables
//! is reachable through any of these routes, and a deleted or anonymized
//! account answers exactly like an id that was never used, so none of them
//! can be used to confirm someone deleted their account.

use std::collections::HashMap;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::auth::validate_label;
use super::error::ApiError;
use super::extract::{AUTHED_READ, Authed, AuthedLimited, Json, Query, enforce};
use super::messages::parse_uuid;
use super::user_avatars::{delete_avatar, get_avatar, upload_avatar};
use super::user_status::{
    PROFILE_COLOR_COUNT, validate_about, validate_profile_color, validate_pronouns,
    validate_status_text,
};
use crate::hub::Event;
use crate::ids::{ChannelId, RoleId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{Store, User};

const BODY_LIMIT: usize = 4 * 1024;

/// Largest avatar a user may upload. Tighter than the general attachment
/// ceiling and not operator-configurable: an avatar is always a small,
/// single image, never a document or a large photo, so there is nothing here
/// a self-host operator would need to tune.
pub(super) const AVATAR_MAX_BYTES: u64 = 2 * 1024 * 1024;

/// Most ids `GET /users` may be asked about in one request.
const MAX_USER_BATCH: usize = 100;
/// Default and maximum page sizes for the member list.
const MEMBERS_DEFAULT_LIMIT: i64 = 50;
const MEMBERS_MAX_LIMIT: i64 = 200;

/// The user profile routes, mounted by [`super::router`].
///
/// Two sub-routers rather than one: `/me/avatar` needs a body-size ceiling
/// large enough for an image, while every other route here (all plain JSON
/// or bodyless) is deliberately kept to [`BODY_LIMIT`]. Merging them after
/// building each with its own `.layer(...)` keeps the small ceiling for the
/// routes that never needed a bigger one.
pub fn routes() -> Router<AppState> {
    let profile = Router::new()
        .route("/me", get(get_me).patch(update_me))
        .route("/users", get(list_users))
        .route("/users/{user_id}", get(get_user))
        .route("/users/{user_id}/avatar", get(get_avatar))
        .route("/members", get(list_members))
        .layer(DefaultBodyLimit::max(BODY_LIMIT));

    let avatar_upload = Router::new()
        .route("/me/avatar", post(upload_avatar).delete(delete_avatar))
        .layer(DefaultBodyLimit::max(AVATAR_MAX_BYTES as usize));

    profile.merge(avatar_upload)
}

// --- Wire types ---

#[derive(Serialize)]
pub(super) struct UserDto {
    id: String,
    username: String,
    /// What readers see: the nickname an administrator gave this account if
    /// there is one, else [`Self::account_display_name`]. Decision 0055.
    display_name: String,
    /// The account's own display name, whatever the nickname is.
    account_display_name: String,
    /// The space-local name an administrator gave this account, or `null`.
    nickname: Option<String>,
    created_at: i64,
    /// When this user's avatar was last set, or `null` for no avatar. Not a
    /// fetchable value on its own - a client appends it as a cache-busting
    /// query parameter on `GET /users/{userId}/avatar`, which ignores the
    /// query string itself and just serves whatever is currently stored.
    avatar_updated_at: Option<i64>,
    /// Role names this member holds, for a client to render a badge (e.g.
    /// "Op") beside them. Excludes `@everyone`: every member holds that one,
    /// so including it would put a meaningless badge on every row. Empty
    /// rather than omitted for a member with nothing beyond it - the same
    /// "always present, empty means none" convention `MessageDto::reactions`
    /// already follows. Deliberately no colour: badges use the design
    /// system's accent, not a per-role one.
    roles: Vec<String>,
    /// The same roles as ids, positionally matching [`Self::roles`].
    ///
    /// Both, rather than one: a badge renders the name, and an assignment is
    /// made against the id. Nothing stops two roles sharing a name, so a
    /// client deciding "does this member hold that role" by name would answer
    /// yes for both of them.
    role_ids: Vec<String>,
    /// The hoisted role this member is listed under in the member pane, or
    /// `null` when none of theirs is hoisted. Always one of [`Self::role_ids`].
    hoisted_role_id: Option<String>,
    /// That role's hierarchy position, so a client orders sections exactly
    /// without `GET /roles`, which needs MANAGE_ROLES.
    hoisted_role_position: Option<i64>,
    /// When this member's timeout lifts, in Unix milliseconds, or `null` if
    /// they are not timed out. An elapsed timeout reads as `null` rather than
    /// as a past deadline, so a client never has to do the comparison to know
    /// whether the badge belongs on screen.
    timed_out_until: Option<i64>,
    /// A short free-text status line this member set for themselves, or
    /// `null` for none. Shown in the member pane under the name; see
    /// migration 0044.
    status_text: Option<String>,
    /// A short self-described pronoun set ("she/her"), or `null` if unset.
    /// Shown on the member card beside the `@handle`; see migration 0075.
    pronouns: Option<String>,
    /// A short "about" line (190 characters), or `null` if unset. Shown on
    /// the member card under the status line; see migration 0075.
    about: Option<String>,
    /// An index into the design system's closed categorical colour set.
    /// Always present: an account that never chose one reads a stable
    /// default derived from its id, so a card is never colourless. See
    /// [`default_profile_color`] and `ProfileUpdate::profile_color`.
    profile_color: i64,
    /// The invite this member registered through, or `null` if they had
    /// none. Absent from the response entirely for a caller who does not
    /// hold BAN_MEMBERS, so it is only ever populated on the `GET /members`
    /// path and only for a moderator looking for a ban-evading return
    /// account; see MOD9.
    #[serde(skip_serializing_if = "Option::is_none")]
    invite_code: Option<String>,
    /// Whether this account is a bot rather than a person.
    ///
    /// The interface draws a badge from this, which is the one affordance that
    /// matters: a reader has to be able to tell that something was written by a
    /// program without inspecting anything. It says nothing about what the
    /// account may do - that is its roles, exactly as for a person.
    is_bot: bool,
    /// Whether this account is a webhook's principal rather than a person or
    /// a bot.
    ///
    /// The interface draws its always-on `Webhook` badge from this - the same
    /// affordance `is_bot` gets, and for the same reason: a reader has to be
    /// able to tell without inspecting anything. See
    /// `docs/decisions/0030-incoming-webhooks.md`. A webhook never appears in
    /// `GET /members` at all (it is not a participant), so this is only ever
    /// seen by resolving a message's own author id.
    is_webhook: bool,
}

/// The colour a card shows before its owner ever picks one: a stable index
/// into the closed set, derived from the account id rather than random, so a
/// member's card does not change colour on every reload before they choose
/// one for themselves.
fn default_profile_color(id: UserId) -> i64 {
    let bytes = id.0.as_bytes();
    (i64::from(bytes[bytes.len() - 1])).rem_euclid(PROFILE_COLOR_COUNT)
}

/// Builds one profile DTO, including this user's non-`@everyone` role names.
/// A single extra query beyond the profile fetch itself; see [`to_dtos`] for
/// the batched form a page of users needs instead of paying this per row.
pub(super) async fn to_dto(store: &Store, user: User) -> anyhow::Result<UserDto> {
    Ok(to_dtos(store, vec![user]).await?.remove(0))
}

/// Builds a page of profile DTOs, batching the roles lookup into one query
/// regardless of how many users are being described at once - the shape
/// [`Store::roles_for_users`] follows from [`Store::reactions_for_messages`],
/// which is what keeps `GET /members` (paginated up to 200) from paying one
/// query per row.
async fn to_dtos(store: &Store, users: Vec<User>) -> anyhow::Result<Vec<UserDto>> {
    let ids: Vec<UserId> = users.iter().map(|u| u.id).collect();
    let roles: HashMap<UserId, Vec<(RoleId, String)>> =
        store.roles_for_users(&ids).await?.into_iter().collect();
    // Batched for the same reason the roles above are; see this function's note.
    let timed_out = store.timed_out_among_until(&ids).await?;
    let hoisted = store.hoisted_roles_for_users(&ids).await?;
    let nicknames = store.nicknames_for(&ids).await?;
    Ok(users
        .into_iter()
        .map(|user| {
            let held = roles.get(&user.id).cloned().unwrap_or_default();
            let nickname = nicknames.get(&user.id).cloned();
            UserDto {
                id: user.id.to_string(),
                username: user.username,
                display_name: nickname
                    .clone()
                    .unwrap_or_else(|| user.display_name.clone()),
                account_display_name: user.display_name,
                nickname,
                created_at: user.created_at,
                avatar_updated_at: user.avatar_updated_at,
                roles: held.iter().map(|(_, name)| name.clone()).collect(),
                role_ids: held.iter().map(|(id, _)| id.to_string()).collect(),
                hoisted_role_id: hoisted.get(&user.id).map(|role| role.id.to_string()),
                hoisted_role_position: hoisted.get(&user.id).map(|role| role.position),
                timed_out_until: timed_out.get(&user.id).copied(),
                status_text: user.status_text,
                pronouns: user.pronouns,
                about: user.about,
                profile_color: user
                    .profile_color
                    .unwrap_or_else(|| default_profile_color(user.id)),
                invite_code: None,
                is_bot: user.is_bot,
                is_webhook: user.is_webhook,
            }
        })
        .collect())
}

#[derive(Serialize)]
struct MeDto {
    id: String,
    username: String,
    display_name: String,
    created_at: i64,
    avatar_updated_at: Option<i64>,
    /// The caller's base, deployment-level permission bitmask: the
    /// `@everyone` role plus every role they hold, ignoring any per-channel
    /// overwrite. A client uses this to decide which actions to show, but
    /// that is a UI nicety only; every write is re-authorized server-side
    /// from scratch regardless of what a client chose to display.
    ///
    /// Already has any timeout subtracted, so a client that greys the
    /// composer on a missing SEND_MESSAGES bit needs no separate rule for
    /// being timed out; [`Self::timed_out_until`] is what says *why*.
    permissions: i64,
    /// When the caller's own timeout lifts, or `null`. Present so the client
    /// can name what happened rather than leaving somebody with a disabled
    /// composer and no explanation.
    timed_out_until: Option<i64>,
    /// Why the caller was timed out, or `null` if they are not timed out, or
    /// the moderator left no reason. Self-view only: this is moderation
    /// information about the caller, so it belongs on [`MeDto`] and must
    /// never appear on [`UserDto`], which other members can read.
    timeout_reason: Option<String>,
    /// The caller's own status line, or `null`; see [`UserDto::status_text`].
    status_text: Option<String>,
    /// The caller's own pronouns, or `null`; see [`UserDto::pronouns`].
    pronouns: Option<String>,
    /// The caller's own about line, or `null`; see [`UserDto::about`].
    about: Option<String>,
    /// The caller's own profile colour index, or `null`; see
    /// [`UserDto::profile_color`].
    profile_color: i64,
    /// The caller's own stored presence choice (`online`, `away`, `dnd` or
    /// `hidden`). Self-view only: a hidden choice is invisible to everyone
    /// else, so this must never appear on [`UserDto`] or any other-user shape.
    presence_visibility: String,
}

/// The editable half of a profile.
///
/// Username is deliberately not a field: it backs the live per-account
/// uniqueness index (`users_username_live`), and changing it needs a dedicated
/// flow that can handle the resulting collision. That is why it is absent
/// rather than accepted and quietly ignored.
///
/// Every field is optional, absence meaning "leave it as it is" - the same
/// "at least one, absent means untouched" convention
/// `channels::UpdateChannelRequest` uses for its own name and topic, so a
/// caller changing only one field never has to resend the rest to satisfy
/// fields this route no longer requires. At least one must be present.
#[derive(Deserialize)]
struct UpdateMeRequest {
    #[serde(default)]
    display_name: Option<String>,
    /// Present (even as an empty or whitespace-only string) replaces it,
    /// clearing it back to `None` if the trimmed value is blank - see
    /// [`validate_status_text`].
    #[serde(default)]
    status_text: Option<String>,
    /// Same "present, even blank, replaces it" shape as `status_text`; see
    /// [`validate_pronouns`].
    #[serde(default)]
    pronouns: Option<String>,
    /// Same "present, even blank, replaces it" shape as `status_text`; see
    /// [`validate_about`].
    #[serde(default)]
    about: Option<String>,
    /// Absent leaves the colour as it is. There is no "clear" here: every
    /// account always has one, defaulting to an index derived from the
    /// account id (see `to_dtos`), so there is nothing meaningful to clear
    /// back to. An index outside the closed colour set is a 400 rather than
    /// clamped, per [`validate_profile_color`].
    #[serde(default)]
    profile_color: Option<i64>,
}

#[derive(Deserialize)]
struct ListUsersParams {
    ids: Option<String>,
}

#[derive(Deserialize)]
struct ListMembersParams {
    after: Option<String>,
    limit: Option<i64>,
    /// Narrows the roster to who can view this channel; see [`list_members`].
    channel: Option<String>,
}

// --- Handlers: /me ---

async fn get_me(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<MeDto>, ApiError> {
    let user = state
        .store
        .user_profile(ctx.user_id)
        .await?
        .ok_or(ApiError::Unauthorized)?;
    let permissions = state.store.base_permissions(ctx.user_id).await?;
    let timeout = state.store.member_timeout(ctx.user_id).await?;
    let visibility = state.store.presence_visibility(ctx.user_id).await?;
    Ok(Json(MeDto {
        id: user.id.to_string(),
        username: user.username,
        display_name: user.display_name,
        created_at: user.created_at,
        avatar_updated_at: user.avatar_updated_at,
        permissions: permissions.bits(),
        timed_out_until: timeout.as_ref().map(|t| t.until),
        timeout_reason: timeout.and_then(|t| t.reason),
        status_text: user.status_text,
        pronouns: user.pronouns,
        about: user.about,
        profile_color: user
            .profile_color
            .unwrap_or_else(|| default_profile_color(user.id)),
        presence_visibility: visibility.unwrap_or_default().as_str().to_owned(),
    }))
}

async fn update_me(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<UpdateMeRequest>,
) -> Result<Json<UserDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;

    if let Some(display_name) = &req.display_name {
        validate_label(display_name, "display_name must be 1 to 64 characters")?;
    }
    let status_text = req
        .status_text
        .as_deref()
        .map(validate_status_text)
        .transpose()?;
    let pronouns = req.pronouns.as_deref().map(validate_pronouns).transpose()?;
    let about = req.about.as_deref().map(validate_about).transpose()?;
    let profile_color = req.profile_color.map(validate_profile_color).transpose()?;
    if req.display_name.is_none()
        && status_text.is_none()
        && pronouns.is_none()
        && about.is_none()
        && profile_color.is_none()
    {
        return Err(ApiError::BadRequest("nothing to update"));
    }

    let user = state
        .store
        .update_profile(
            ctx.user_id,
            crate::store::ProfileUpdate {
                display_name: req.display_name.as_deref(),
                status_text: status_text.as_ref().map(|s| s.as_deref()),
                pronouns: pronouns.as_ref().map(|s| s.as_deref()),
                about: about.as_ref().map(|s| s.as_deref()),
                profile_color,
            },
        )
        .await?
        .ok_or(ApiError::Unauthorized)?;
    // Unconditional even on a no-op edit: this carries no ordering invariant a spurious publish could break.
    state.hub.publish(Event::ProfileChanged(ctx.user_id));
    Ok(Json(to_dto(&state.store, user).await?))
}

// --- Handlers: /users ---

async fn get_user(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    Path(user_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UserDto>, ApiError> {
    let user_id = UserId(parse_uuid(&user_id)?);
    let user = state
        .store
        .user_profile(user_id)
        .await?
        .ok_or(ApiError::NotFound("user not found"))?;
    Ok(Json(to_dto(&state.store, user).await?))
}

/// Batch profile lookup. A missing id (never existed, or deleted) is simply
/// absent from the result rather than reported, so the response may be
/// shorter than the request; the caller matches by id.
async fn list_users(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<ListUsersParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<UserDto>>, ApiError> {
    let raw = params.ids.unwrap_or_default();
    let mut ids = Vec::new();
    for part in raw.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if ids.len() >= MAX_USER_BATCH {
            return Err(ApiError::BadRequest("too many ids requested"));
        }
        ids.push(UserId(parse_uuid(part)?));
    }

    let users = state.store.user_profiles(&ids).await?;
    Ok(Json(to_dtos(&state.store, users).await?))
}

// --- Handlers: /members ---

/// Lists the deployment's live members for a member list. Any authenticated
/// caller may read it: a member list is deployment-wide, not scoped to any
/// one channel, so there is no channel permission to check it against.
///
/// `channel` narrows the roster to the members who can view that channel,
/// which is what a member pane beside a channel means by "who is here". It is
/// a display filter, not a confidentiality boundary: the unfiltered roster is
/// readable by any authenticated caller from this same route, by design.
///
/// A MANAGE_ROLES caller additionally gets each member's registration invite
/// code attached (see MOD9) - a moderation signal, not a public one, so it
/// is fetched and attached only here rather than in [`to_dtos`] itself,
/// which every other `UserDto` response also goes through.
///
/// MANAGE_ROLES rather than the BAN_MEMBERS this once used: a code is a
/// credential, not a label. `Store::redeem_invite` applies the invite's
/// `role_grant` to whoever spends it, and redeeming needs nothing but a
/// session, so a moderator who could not grant a role could read a still-live
/// code off this list and take that role - up to ADMINISTRATOR. Gating on the
/// permission that could grant it anyway closes that without losing the
/// ban-evasion signal for the people who set the roles in the first place.
async fn list_members(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    Query(params): Query<ListMembersParams>,
    State(state): State<AppState>,
) -> Result<Json<Vec<UserDto>>, ApiError> {
    let after = params
        .after
        .as_deref()
        .map(parse_uuid)
        .transpose()?
        .map(UserId);
    let limit = params
        .limit
        .unwrap_or(MEMBERS_DEFAULT_LIMIT)
        .clamp(1, MEMBERS_MAX_LIMIT);

    let members = match params.channel.as_deref().map(parse_uuid).transpose()? {
        Some(id) => {
            state
                .store
                .list_members_who_view(ChannelId(id), after, limit)
                .await?
        }
        None => state.store.list_members(after, limit).await?,
    };
    let ids: Vec<UserId> = members.iter().map(|m| m.id).collect();
    let mut dtos = to_dtos(&state.store, members).await?;

    // A code is a credential: redeeming it applies the role it grants.
    let sees_codes = state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_ROLES);
    if sees_codes {
        let invite_codes = state.store.registration_invite_codes(&ids).await?;
        for (dto, id) in dtos.iter_mut().zip(ids.iter()) {
            dto.invite_code = invite_codes.get(id).cloned();
        }
    }
    Ok(Json(dtos))
}
