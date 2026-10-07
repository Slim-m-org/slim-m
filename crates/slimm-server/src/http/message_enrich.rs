// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Turning a page of stored messages into the DTOs every read route answers
//! with, reactions and polls attached.
//!
//! Split out of [`super::messages`] when that file crossed the 500-line hard
//! ceiling. Its own file rather than a section of that one because it belongs
//! to no single route: list, full-text search, sync and the pinned-message
//! list all enrich a page the same way, and doing it per route is how the
//! `/sync` deltas once came back with an empty `reactions` array while the
//! same message fetched by list carried them. Forwards are attached here
//! for that same reason.

use super::AppState;
use super::embeds;
use super::message_dto::{CallDto, CodeRunDto};
use super::messages::{AttachmentDto, MessageDto, ReactionDto};
use crate::ids::{ChannelId, MessageId, UserId};
use crate::store::Message;

/// Batch-attaches each message's reaction summary and, if it carries one,
/// its poll, to its DTO - in a fixed small number of queries rather than one
/// per row, which only bites once a channel has real traffic. Shared by
/// [`list`], the full-text search route, sync, and the pinned-message list,
/// which all enrich a page of messages the same way.
pub(crate) async fn with_reactions(
    state: &AppState,
    viewer: UserId,
    messages: Vec<Message>,
) -> anyhow::Result<Vec<MessageDto>> {
    let ids: Vec<MessageId> = messages.iter().map(|m| m.id).collect();
    let mut by_message = state.store.reactions_for_messages(&ids, viewer).await?;
    let mut attachments_by_message = state.store.attachments_for_messages(&ids).await?;
    let mut threads_by_message = state.store.thread_summaries_for_messages(&ids).await?;
    let mut forwards_by_message = super::message_forwards::for_messages(state, &ids).await?;
    let mut code_runs_by_message = state.store.code_runs_for_messages(&ids).await?;
    let mut calls_by_message = state.store.calls_for_messages(&ids).await?;
    let mut embeds_by_message = state.store.embeds_for_messages(&ids).await?;
    let mut webhook_usernames = state.store.webhook_usernames_for_messages(&ids).await?;
    let mut components_by_message = state.store.components_for_messages(&ids).await?;
    let mentioned = state.store.mentioned_messages_for(viewer, &ids).await?;
    // One more batched query; empty when no message on this page has a thread, which is the common case.
    let thread_channel_ids: Vec<ChannelId> = threads_by_message
        .iter()
        .map(|(_, s)| s.channel_id)
        .collect();
    let unread_by_channel = state
        .store
        .thread_unread_counts(&thread_channel_ids, viewer)
        .await?;

    let mut dtos: Vec<MessageDto> = Vec::with_capacity(messages.len());
    for message in messages {
        let id = message.id;
        let mut dto = MessageDto::from(message);
        if let Some(pos) = by_message.iter().position(|(mid, _)| *mid == id) {
            let (_, summaries) = by_message.swap_remove(pos);
            dto.reactions = summaries
                .into_iter()
                .map(|s| ReactionDto {
                    emoji: s.emoji,
                    count: s.count,
                    reacted: s.reacted,
                })
                .collect();
        }
        if let Some(pos) = attachments_by_message
            .iter()
            .position(|(mid, _)| *mid == id)
        {
            let (_, summaries) = attachments_by_message.swap_remove(pos);
            dto.attachments = summaries.into_iter().map(AttachmentDto::from).collect();
        }
        if let Some(pos) = threads_by_message.iter().position(|(mid, _)| *mid == id) {
            let (_, summary) = threads_by_message.swap_remove(pos);
            dto.thread_unread_count = Some(
                unread_by_channel
                    .iter()
                    .find(|(cid, _)| *cid == summary.channel_id)
                    .map(|(_, count)| *count)
                    .unwrap_or(0),
            );
            dto.thread_channel_id = Some(summary.channel_id.to_string());
            dto.thread_reply_count = Some(summary.reply_count);
            dto.thread_last_reply_at = summary.last_reply_at;
        }
        if let Some(pos) = calls_by_message.iter().position(|(mid, _)| *mid == id) {
            let (_, record) = calls_by_message.swap_remove(pos);
            dto.call = Some(CallDto::from(record));
        }
        if let Some(pos) = code_runs_by_message.iter().position(|(mid, _)| *mid == id) {
            let (_, runs) = code_runs_by_message.swap_remove(pos);
            dto.code_runs = runs
                .into_iter()
                .map(|r| CodeRunDto {
                    block_index: r.block_index,
                    module_id: r.module_id,
                    command: r.command,
                    ok: r.ok,
                    output: r.output,
                    ran_by: r.ran_by.map(|u| u.to_string()),
                    ran_at: r.ran_at,
                })
                .collect();
        }
        dto.forwarded = forwards_by_message.remove(&id);
        dto.mentions_me = mentioned.contains(&id);
        dto.webhook_username = webhook_usernames.remove(&id);
        if let Some(pos) = embeds_by_message.iter().position(|(mid, _)| *mid == id) {
            let (_, stored) = embeds_by_message.swap_remove(pos);
            dto.embeds = embeds::dtos_from_stored(&state.link_previews, stored);
        }
        if let Some(pos) = components_by_message.iter().position(|(mid, _)| *mid == id) {
            dto.components = components_by_message.swap_remove(pos).1;
        }
        dtos.push(dto);
    }
    // Paired positionally: the loop above pushes one `dtos` entry per `ids` entry.
    super::polls::attach_polls(&state.store, viewer, &ids, &mut dtos).await?;
    super::apps::attach_app_surfaces(&state.store, &ids, &mut dtos).await?;
    Ok(dtos)
}
