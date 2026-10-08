// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Building the `message.created`/`message.edited` wire frames, split out of
//! [`super::authorization::authorize`] when adding `mentions_me`'s own
//! per-connection lookup pushed that file past the 500-line hard ceiling.
//!
//! `Err(())` stands in for [`super::authorization::Authorization::Unknown`]:
//! a failed store read here is unresolved, not "no mention", the same
//! discipline `Event::ReactionsChanged` already follows in `authorization.rs`
//! for its own fresh-per-event store read.

use super::super::apps::AppSurfaceDto;
use super::super::embeds;
use super::super::link_preview::LinkPreviews;
use super::super::message_dto::{CallDto, CodeRunDto};
use super::super::polls::PollDto;
use super::{AttachmentDto, MessageDto, frames::ServerFrame};
use crate::hub::Event;
use crate::ids::UserId;
use crate::store::{
    AppSurface, AttachmentSummary, CallRecord, CodeRunSummary, Embed, ForwardSummary, Message,
    Poll, Store,
};

/// Everything about a freshly created message that the bare row cannot
/// express, bundled so [`created`] stays within the positional-parameter
/// limit. Every field is resolved once by the sender - see
/// [`crate::hub::Event::MessageCreated`] - rather than queried here per
/// subscriber: most messages launch no app and carry no poll, and this runs
/// once per delivered message per connection.
pub(super) struct MessageExtras {
    pub attachments: Vec<AttachmentSummary>,
    pub forwarded: Option<ForwardSummary>,
    pub app_surface: Option<AppSurface>,
    pub code_run: Option<CodeRunSummary>,
    pub poll: Option<Poll>,
    /// Raw; image tokens resolve here, per connection.
    pub embeds: Vec<Embed>,
    pub call: Option<CallRecord>,
    pub components: Vec<crate::components::ComponentRow>,
}

/// [`created`] for a [`Event::MessageCreated`], cloning its shared payload only
/// here, past every filter in `authorize`; anything else is unresolved.
pub(super) async fn created_from_event(
    store: &Store,
    link_previews: &LinkPreviews,
    viewer: UserId,
    event: Event,
) -> Result<ServerFrame, ()> {
    let Event::MessageCreated {
        message,
        attachments,
        forwarded,
        app_surface,
        code_run,
        poll,
        embeds,
        call,
        components,
        lookups,
    } = event
    else {
        return Err(());
    };
    let facts = lookups.get(store, message.id).await.map_err(|_| ())?;
    let extras = MessageExtras {
        attachments: (*attachments).clone(),
        forwarded: forwarded.map(|f| (*f).clone()),
        app_surface: app_surface.map(|s| (*s).clone()),
        code_run: code_run.map(|c| (*c).clone()),
        poll: poll.map(|p| (*p).clone()),
        embeds: (*embeds).clone(),
        call: call.map(|c| (*c).clone()),
        components: (*components).clone(),
    };
    Ok(created(
        link_previews,
        (*message).clone(),
        extras,
        facts.mentioned.contains(&viewer),
        facts.webhook_username.clone(),
    ))
}

/// The frame for a freshly sent message. `mentions_me` and the webhook label
/// come from the event's shared [`crate::hub::CreatedLookups`], so a hundred
/// connections cost two store reads instead of two hundred.
fn created(
    link_previews: &LinkPreviews,
    message: Message,
    extras: MessageExtras,
    mentions_me: bool,
    webhook_username: Option<String>,
) -> ServerFrame {
    let channel_id = message.channel_id.to_string();
    let seq = message.seq.0;
    let mut dto = MessageDto::from(message);
    dto.attachments = extras
        .attachments
        .into_iter()
        .map(AttachmentDto::from)
        .collect();
    dto.forwarded = extras.forwarded.map(Into::into);
    // Without these an app or a poll arrives blank until the next cold read.
    dto.app_surface = extras.app_surface.map(AppSurfaceDto::from);
    dto.poll = extras.poll.map(PollDto::from);
    dto.embeds = embeds::dtos_from_stored(link_previews, extras.embeds);
    dto.components = extras.components;
    if let Some(run) = extras.code_run {
        dto.code_runs = vec![CodeRunDto {
            block_index: run.block_index,
            module_id: run.module_id,
            command: run.command,
            ok: run.ok,
            output: run.output,
            ran_by: run.ran_by.map(|u| u.to_string()),
            ran_at: run.ran_at,
        }];
    }
    dto.mentions_me = mentions_me;
    dto.webhook_username = webhook_username;
    // Without this a call arrives blank until the next cold read.
    dto.call = extras.call.map(CallDto::from);
    ServerFrame::MessageCreated {
        channel_id,
        seq,
        message: dto,
    }
}

/// [`created`]'s own sibling for an edit, which carries the message-op
/// stream's own `op_seq` rather than nothing extra.
pub(super) async fn edited(
    store: &Store,
    viewer: UserId,
    message: Message,
    op_seq: i64,
    forwarded: Option<ForwardSummary>,
) -> Result<ServerFrame, ()> {
    let channel_id = message.channel_id.to_string();
    let seq = message.seq.0;
    let message_id = message.id;
    let mut dto = MessageDto::from(message);
    dto.forwarded = forwarded.map(Into::into);
    dto.webhook_username = store
        .webhook_message_username(message_id)
        .await
        .map_err(|_| ())?;
    dto.mentions_me = store
        .is_mentioned(message_id, viewer)
        .await
        .map_err(|_| ())?;
    Ok(ServerFrame::MessageEdited {
        channel_id,
        seq,
        op_seq: Some(op_seq),
        message: dto,
    })
}
