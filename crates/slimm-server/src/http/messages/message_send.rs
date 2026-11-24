// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The send route, split out of `messages.rs` to keep that file under its
//! line budget; mounted from there like `message_get` and `message_history`.

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::request::Parts;

use super::super::AppState;
use super::super::attachment_ids::parse_attachment_ids;
use super::super::channel_slow_mode::enforce_slow_mode;
use super::super::embeds;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce};
use super::super::module_hooks::{Draft, HookPoint, guard_write};
use super::super::post_commit::after_commit;
use super::message_requests::SendRequest;
use super::{AttachmentDto, MessageDto, parse_uuid, validate_content};
use crate::hub::{Event, MessageEvent};
use crate::ids::{ChannelId, MessageId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::NewMessage;

/// Sends a message, idempotent by the client-generated message id.
///
/// A nonexistent channel grants no permissions, so this refuses both "you
/// cannot post here" and "no such channel" identically, revealing neither.
/// ATTACH_FILES is only demanded when the send actually carries something, so
/// an ordinary text message never needs it.
///
/// A retry of a send that already succeeded returns the stored message so the
/// client gets its acknowledgement, but must not repeat what already happened
/// once. Fanning it out again would show it twice to anyone whose client does
/// not de-duplicate, and pushing again would wake every idle recipient a
/// second time, outside the debounce window that exists to stop exactly that.
///
/// Push work is handed to a detached background task, because the message is
/// already committed and its response already on the way: a relay outage can
/// never turn a successful send into an error.
///
/// Unlike reactions and polls, attachments can exist the instant a message is
/// created (they were uploaded before this call and just linked inside it), so
/// the echoed response needs its own lookup rather than staying empty the way
/// a fresh message's reactions correctly do.
///
/// A fresh send is also where the channel's slow mode is enforced (see
/// `channel_slow_mode::enforce_slow_mode`), gated on the same `stored_already`
/// this function already computes for the forward check: a retry of a send
/// that already landed must never be refused for arriving "too soon".
/// `embeds` is honoured only from a bot, discarded otherwise.
pub(super) async fn send(
    Authed(ctx): Authed,
    Path(channel_id): Path<String>,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<SendRequest>,
) -> Result<Json<MessageDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let attachment_ids = parse_attachment_ids(&req.attachment_ids)?;
    let spoiler_ids = parse_attachment_ids(&req.spoiler_attachment_ids)?;
    if spoiler_ids.iter().any(|id| !attachment_ids.contains(id)) {
        return Err(ApiError::BadRequest(
            "spoiler_attachment_ids must be among attachment_ids",
        ));
    }

    // ATTACH_FILES only when the send carries something; the doc says why a missing and a denied channel look alike.
    let mut needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    if !attachment_ids.is_empty() {
        needed = needed.union(Permissions::ATTACH_FILES);
    }
    super::super::write_refusal::require(&state, ctx.user_id, channel_id, needed).await?;

    // A forward with no note of its own is a complete message; so is one that is only attachments.
    let carries_more = !attachment_ids.is_empty() || req.forwarded_from_id.is_some();
    let content = &*validate_content(&req.content, carries_more)?;
    let id = MessageId(parse_uuid(&req.id)?);
    let mut embeds = embeds::honored_for_send(&state, ctx.user_id, req.embeds).await?;
    let mut components =
        super::message_components::honored_for_send(&state, ctx.user_id, req.components).await?;
    let reply_to_id = req
        .reply_to_id
        .as_deref()
        .map(|raw| parse_uuid(raw).map(MessageId))
        .transpose()?;
    let mention_reply = req.mention_reply;
    // A retry must not re-authorize what already succeeded; the authoritative check still runs in the transaction.
    let stored_already = state.store.message_including_deleted(id).await?.is_some();
    // Never on a retry: see `enforce_slow_mode`'s own doc for why a second attempt at an id that already landed must not be refused.
    let slow_mode_window_ms = match stored_already {
        true => None,
        false => enforce_slow_mode(&state, channel_id, ctx.user_id).await?,
    };
    let forward = match &req.forwarded_from_id {
        // Parsed even on a retry, so a malformed id is still a 400.
        Some(raw) => {
            let named = MessageId(parse_uuid(raw)?);
            match stored_already {
                true => None,
                false => Some(super::message_forwards::resolve(&state, ctx.user_id, named).await?),
            }
        }
        None => None,
    };
    // A retry stores no new text, but may still store the embeds or buttons its first attempt did not.
    let draft = Draft {
        point: HookPoint::PreSend,
        channel_id,
        actor: ctx.user_id,
        reply_to: reply_to_id,
        content: (!stored_already).then_some(content),
        carries_more,
        own_module: None,
    };
    let intercepted = {
        let mut fields = embeds::text_fields(&mut embeds);
        fields.extend(super::message_components::label_fields(&mut components));
        guard_write(&state, &draft, &mut fields).await?
    };
    let content = intercepted.text(content);
    let sent = state
        .store
        .send_message_with_slow_mode(
            NewMessage {
                channel_id,
                author_id: ctx.user_id,
                id,
                content,
                attachment_ids: &attachment_ids,
                spoiler_ids: &spoiler_ids,
                reply_to_id,
                forward,
            },
            slow_mode_window_ms,
        )
        .await?;

    if sent.fresh {
        intercepted.save_annotations(&state, id).await;
    }

    // Read once and used twice: the live frame and this response need the same summaries, and a fresh message can already have them.
    let ids = [id];
    let (attachments, forwarded, stored_embeds, stored_components) = tokio::join!(
        state.store.attachments_for_messages(&ids),
        state.store.forwards_for_messages(&ids),
        embeds::store_and_reload(&state, id, sent.fresh, &embeds),
        super::message_components::store_and_reload(&state, id, sent.fresh, &components),
    );
    let attachments: Vec<_> = after_commit("reading its attachments back", attachments)
        .into_iter()
        .next()
        .map(|(_, summaries)| summaries)
        .unwrap_or_default();
    let forwarded = after_commit("reading its forward back", forwarded)
        .into_iter()
        .next()
        .map(|(_, summary)| summary);
    let stored_embeds = after_commit("its embeds", stored_embeds);
    let stored_components = after_commit("its components", stored_components);

    let reply_ping = match sent.message.reply_to_id.filter(|_| mention_reply) {
        Some(parent) => after_commit(
            "its reply ping",
            super::message_mentions::reply_ping_target(&state, channel_id, ctx.user_id, parent)
                .await,
        ),
        None => None,
    };
    // Also on a retry, which repairs mentions its first attempt failed to store; resolving is idempotent.
    after_commit(
        "its mentions",
        super::message_mentions::resolve_and_store(
            &state,
            channel_id,
            ctx.user_id,
            sent.message.id,
            &sent.message.content,
            reply_ping,
        )
        .await,
    );

    // An idempotent retry must not fan out or push again; see this function's note.
    if sent.fresh {
        super::super::read_sync::advance_for_author(&state, ctx.user_id, &sent.message).await;

        state.hub.publish(Event::Message(MessageEvent::Created {
            message: Arc::new(sent.message.clone()),
            attachments: Arc::new(attachments.clone()),
            forwarded: forwarded.clone().map(Arc::new),
            // An ordinary send never launches an app or carries a poll.
            app_surface: None,
            code_run: None,
            poll: None,
            embeds: Arc::new(stored_embeds.clone()),
            call: None,
            components: Arc::new(stored_components.clone()),
            lookups: Default::default(),
        }));

        // Cheap in-memory decision only, real work detached; see this function's note.
        state.push.notify_message(
            state.store.clone(),
            crate::push::SentMessage {
                channel_id,
                author_id: ctx.user_id,
                message_id: sent.message.id,
                seq: sent.message.seq,
                content: sent.message.content.clone(),
                presence: state.hub.presence(),
                reply_ping,
                mass_authority: Some(ctx.user_id),
            },
        );
        // A no-op for an ordinary channel; see `threads::notify_reply`.
        super::super::threads::notify_reply(&state, channel_id).await;
    }

    let mut dto: MessageDto = sent.message.into();
    dto.attachments = attachments.into_iter().map(AttachmentDto::from).collect();
    dto.forwarded = forwarded.map(Into::into);
    dto.embeds = embeds::dtos_from_stored(&state.link_previews, stored_embeds);
    dto.components = stored_components;
    Ok(Json(dto))
}
