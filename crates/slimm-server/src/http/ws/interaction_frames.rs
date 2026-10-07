// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Authorizing a button click and its answer for one connection. See
//! docs/decisions/0039-bot-message-buttons.md.

use super::authorization::Authorization;
use super::frames::ServerFrame;
use crate::hub::Event;
use crate::permissions::Permissions;
use crate::store::{Interaction, SessionContext, Store};

/// `None` when `event` is not an interaction event. A click goes to the owning
/// bot's connections only and its answer to the clicker's only, and both need
/// the recipient to still see the channel. A store error withholds: neither
/// frame has a catch-up path, and the clicker's client times out visibly.
pub(super) async fn authorize(
    store: &Store,
    ctx: &SessionContext,
    event: &Event,
) -> Option<Authorization> {
    match event {
        Event::InteractionCreated {
            interaction,
            clicker_display_name,
        } => Some(
            deliver_to(store, ctx, interaction, interaction.bot_id, || {
                ServerFrame::InteractionCreated {
                    interaction_id: interaction.id.to_string(),
                    channel_id: interaction.channel_id.to_string(),
                    message_id: interaction.message_id.map(|m| m.to_string()),
                    custom_id: interaction.custom_id.clone(),
                    kind: interaction.kind.as_str().to_owned(),
                    option_id: interaction.option_id.clone(),
                    user_id: interaction.clicker_id.to_string(),
                    user_display_name: clicker_display_name.clone(),
                    created_at: interaction.created_at,
                }
            })
            .await,
        ),
        Event::InteractionAnswered { interaction } => Some(
            deliver_to(store, ctx, interaction, interaction.clicker_id, || {
                ServerFrame::InteractionAnswered {
                    interaction_id: interaction.id.to_string(),
                    channel_id: interaction.channel_id.to_string(),
                    message_id: interaction.message_id.map(|m| m.to_string()),
                }
            })
            .await,
        ),
        _ => None,
    }
}

async fn deliver_to(
    store: &Store,
    ctx: &SessionContext,
    interaction: &Interaction,
    recipient: crate::ids::UserId,
    frame: impl FnOnce() -> ServerFrame,
) -> Authorization {
    if ctx.user_id != recipient {
        return Authorization::Withhold;
    }
    let can_view = matches!(
        store
            .has_permission(
                ctx.user_id,
                interaction.channel_id,
                Permissions::VIEW_CHANNEL
            )
            .await,
        Ok(true)
    );
    if can_view {
        Authorization::Deliver(Box::new(frame()))
    } else {
        Authorization::Withhold
    }
}
