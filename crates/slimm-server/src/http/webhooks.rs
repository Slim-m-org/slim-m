// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Incoming webhook delivery: the one route a webhook credential can use.
//!
//! See `docs/decisions/0030-incoming-webhooks.md`. Everything downstream of
//! resolving the credential reuses the ordinary send path unchanged - the
//! same store insert, mention resolution, hub fan-out and push wake a normal
//! `POST /channels/{channel_id}/messages` triggers - which is deliberate: a
//! webhook message is attributable, reportable and moderator-deletable with
//! no new code precisely because it is a message like any other, authored by
//! a user-shaped principal.
//!
//! What is different here, and is the whole of this file:
//!
//! - No `Authed`. The credential is a `(webhook_id, token)` pair in the path,
//!   never a bearer token, so this never goes through the extractor every
//!   other route shares - there is no session for it to resolve to.
//! - No permission check. A webhook has exactly one verb on exactly one
//!   channel, fixed at mint, so the only question is whether the credential
//!   still resolves at all; see `Store::authenticate_webhook`'s own doc.
//! - Two rate-limit buckets in a specific order, the second charged directly
//!   against the limiter rather than through `enforce`: see [`deliver`]'s
//!   own doc.
//! - A permissive request body: an unrecognised field is accepted and
//!   discarded rather than refused, which is what `#[derive(Deserialize)]`
//!   already does for any field [`DeliverRequest`] does not name, with no
//!   `deny_unknown_fields` to opt back into the ordinary refusal.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::AppState;
use super::channel_slow_mode::enforce_slow_mode;
use super::embeds;
use super::error::ApiError;
use super::extract::{Json, Query, enforce};
use super::messages::{parse_uuid, validate_content};
use super::post_commit::after_commit;
use crate::hub::Event;
use crate::ids::{MessageId, WebhookId};
use crate::ratelimit::Class;
use crate::store::NewMessage;

/// Same ceiling as an ordinary send's body limit
/// (`messages::MESSAGE_BODY_LIMIT`); a Discord-shaped payload with an
/// honoured `content`, `username` and `embeds` is not meaningfully larger
/// than a plain send.
const BODY_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/webhooks/{webhook_id}/{token}", post(deliver))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

/// The header a caller sends to make a retried delivery idempotent - see this
/// module's own doc and `docs/decisions/0030-incoming-webhooks.md`'s "Replay"
/// section. Absent, every delivery mints a fresh message id and the caller
/// gets ordinary at-least-once behaviour (a duplicate on a retry).
const IDEMPOTENCY_KEY_HEADER: &str = "idempotency-key";

/// A Discord-shaped incoming-webhook body. Only `content`, `username` and
/// `embeds` are read; every other field Discord defines (`avatar_url`,
/// `tts`, `flags`, `components`, `thread_name`, `poll`, `attachments`,
/// `allowed_mentions`) - and anything neither this shape nor Discord's ever
/// named - is accepted and silently discarded, never a 400. See this file's
/// own doc for why no `deny_unknown_fields` is the whole mechanism.
#[derive(Deserialize)]
struct DeliverRequest {
    #[serde(default)]
    content: Option<String>,
    /// A per-post label, shown in the name slot beside the always-on
    /// `Webhook` badge. Never written to the principal's own
    /// `display_name` and never returned as a message's
    /// `author_display_name` - see the decision record's "`username`
    /// becomes a label" section. Read back as a message's `webhook_username`.
    #[serde(default)]
    username: Option<String>,
    /// Structured content; caps are shared with the ordinary send route.
    #[serde(default, deserialize_with = "embeds::null_as_empty")]
    embeds: Vec<embeds::WebhookEmbed>,
}

#[derive(Deserialize)]
struct DeliverParams {
    #[serde(default)]
    wait: bool,
}

/// The minimal acknowledgement `?wait=true` asks for - never the full
/// `Message` DTO, which carries per-viewer fields (`mentions_me`, a
/// reaction's own `reacted`) that mean nothing for a caller that is not a
/// viewer. See the decision record's "Response shape" section.
#[derive(Serialize)]
struct DeliveredDto {
    id: String,
    channel_id: String,
    seq: i64,
    created_at: i64,
}

/// Longest a `username` label may be - the same ceiling
/// `validate_label` gives a display name, since this fills the identical
/// visual slot.
const USERNAME_MAX_CHARS: usize = 64;

/// Delivers one webhook post.
///
/// Rate limiting is two independent charges against [`Class::Webhook`],
/// charged in the order `docs/decisions/0030-incoming-webhooks.md` requires.
/// The first is `enforce(..., None, ...)`, address-keyed exactly the way any
/// unauthenticated route's charge already is, and charged before the token
/// lookup so an unknown-token flood costs a map probe rather than a database
/// query. The second, only once the credential resolves, keys on the
/// webhook's own principal id instead - never the caller's address, for the
/// same reason 0028 keys a bot's budget on its account rather than wherever
/// it happens to be calling from - which `enforce`'s own signature has no
/// shape for, so it is charged directly against the limiter.
///
/// A malformed id is a 400. Every other failure past the rate limit - an
/// unknown id, a wrong token, or a revoked one - answers with the same 404, so
/// this route is never an existence oracle for which webhook ids are live.
async fn deliver(
    State(state): State<AppState>,
    parts: Parts,
    Path((webhook_id, token)): Path<(String, String)>,
    Query(params): Query<DeliverParams>,
    Json(body): Json<DeliverRequest>,
) -> Result<Response, ApiError> {
    enforce(&state, &parts, None, Class::Webhook)?;

    let webhook_id = WebhookId(parse_uuid(&webhook_id)?);
    let Some(context) = state.store.authenticate_webhook(webhook_id, &token).await? else {
        return Err(ApiError::NotFound("no such webhook"));
    };

    let principal_key = format!("u:{}", context.principal_id);
    state.limiter.admit(Class::Webhook, &principal_key)?;

    let content = validate_content(body.content.as_deref().unwrap_or(""), false)?;
    let username = match body.username.as_deref().map(str::trim) {
        Some(name) if !name.is_empty() => {
            if name.chars().count() > USERNAME_MAX_CHARS {
                return Err(ApiError::BadRequestDetail(format!(
                    "username is {} characters over the {USERNAME_MAX_CHARS}-character limit",
                    name.chars().count() - USERNAME_MAX_CHARS,
                )));
            }
            if name.chars().any(super::hidden_chars::is_hidden_char) {
                return Err(ApiError::BadRequest(
                    "username must not contain control or invisible characters",
                ));
            }
            Some(name)
        }
        _ => None,
    };
    let embeds = embeds::build_embeds(
        body.embeds.into_iter().map(Into::into).collect(),
        &state.link_previews,
    )?;

    let id = idempotent_message_id(&parts, webhook_id);
    let channel_id = context.channel_id;
    let stored_already = state.store.message_including_deleted(id).await?.is_some();
    if !stored_already {
        enforce_slow_mode(&state, channel_id, context.principal_id).await?;
    }

    let sent = state
        .store
        .send_message(NewMessage::plain(
            channel_id,
            context.principal_id,
            id,
            content,
        ))
        .await?;

    if sent.fresh {
        if let Some(username) = username {
            after_commit(
                "its username",
                state
                    .store
                    .set_webhook_message_username(sent.message.id, username)
                    .await,
            );
        }
        let stored_embeds = after_commit(
            "its embeds",
            embeds::store_and_reload(&state, sent.message.id, true, &embeds).await,
        );
        after_commit(
            "its mentions",
            super::message_mentions::resolve_and_store(
                &state,
                channel_id,
                context.principal_id,
                sent.message.id,
                &sent.message.content,
            )
            .await,
        );
        state.hub.publish(Event::MessageCreated {
            message: std::sync::Arc::new(sent.message.clone()),
            attachments: std::sync::Arc::new(Vec::new()),
            forwarded: None,
            app_surface: None,
            code_run: None,
            poll: None,
            embeds: std::sync::Arc::new(stored_embeds),
            call: None,
            components: std::sync::Arc::new(Vec::new()),
        });
        state.push.notify_message(
            state.store.clone(),
            crate::push::SentMessage {
                channel_id,
                author_id: context.principal_id,
                message_id: sent.message.id,
                seq: sent.message.seq,
                content: sent.message.content.clone(),
                presence: state.hub.presence(),
            },
        );
        super::threads::notify_reply(&state, channel_id).await;
    }

    state.store.touch_webhook_delivery(webhook_id).await?;

    if params.wait {
        Ok((
            StatusCode::OK,
            Json(DeliveredDto {
                id: sent.message.id.to_string(),
                channel_id: channel_id.to_string(),
                seq: sent.message.seq.0,
                created_at: sent.message.created_at,
            }),
        )
            .into_response())
    } else {
        Ok(StatusCode::NO_CONTENT.into_response())
    }
}

/// The message id this delivery writes under: derived deterministically from
/// `Idempotency-Key` when a caller sends one, so a retried request (a timeout,
/// a dropped response) lands on the exact same id and `Store::send_message`'s
/// own idempotency does the rest, with no new mechanism. A caller that sends
/// nothing gets a fresh id every time - ordinary at-least-once delivery, a
/// duplicate on a retry, never a silently dropped message; see
/// `docs/decisions/0030-incoming-webhooks.md`'s "Replay" section.
///
/// Namespaced on the webhook's own id, not a single fixed namespace, so two
/// different webhooks that both happen to use the key `"1"` never collide.
fn idempotent_message_id(parts: &Parts, webhook_id: WebhookId) -> MessageId {
    let key = parts
        .headers
        .get(IDEMPOTENCY_KEY_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|key| !key.is_empty());
    match key {
        Some(key) => MessageId(Uuid::new_v5(&webhook_id.0, key.as_bytes())),
        None => MessageId::generate(),
    }
}
