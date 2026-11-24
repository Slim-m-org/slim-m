// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Authorizing a button click, a form and its answer for one connection. See
//! docs/decisions/0039-bot-message-buttons.md.

use super::authorization::Authorization;
use super::frames::ServerFrame;
use crate::components::form::Form;
use crate::hub::Event;
use crate::permissions::Permissions;
use crate::store::{Interaction, SessionContext, Store};

/// `None` when `event` is not an interaction event. A click goes to the owning
/// bot's connections only and its answer to the clicker's only, and both need
/// the recipient to still see the channel. A store error is `Unknown`: neither
/// frame has a catch-up path, so the connection resyncs rather than losing it.
pub(super) async fn authorize(
    store: &Store,
    ctx: &SessionContext,
    event: &Event,
) -> Option<Authorization> {
    match event {
        Event::InteractionCreated {
            interaction,
            clicker_display_name,
            input,
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
                    values: input.values.clone(),
                    fields: input.fields.clone(),
                    origin_interaction_id: input.origin_id.map(|id| id.to_string()),
                }
            })
            .await,
        ),
        Event::InteractionForm { interaction, form } => Some(
            deliver_to(store, ctx, interaction, interaction.clicker_id, || {
                ServerFrame::InteractionForm {
                    interaction_id: interaction.id.to_string(),
                    channel_id: interaction.channel_id.to_string(),
                    bot_id: interaction.bot_id.to_string(),
                    message_id: interaction.message_id.map(|m| m.to_string()),
                    form: Form::clone(form),
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
    let can_view = store
        .has_permission(
            ctx.user_id,
            interaction.channel_id,
            Permissions::VIEW_CHANNEL,
        )
        .await;
    decide(can_view, frame)
}

/// A failed read is `Unknown`, never `Withhold`, so the event is not lost for good.
fn decide(can_view: anyhow::Result<bool>, frame: impl FnOnce() -> ServerFrame) -> Authorization {
    match can_view {
        Ok(true) => Authorization::Deliver(Box::new(frame())),
        Ok(false) => Authorization::Withhold,
        Err(_) => Authorization::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_store_error_resyncs_instead_of_dropping_the_frame() {
        let outcome = decide(Err(anyhow::anyhow!("busy")), || ServerFrame::ReportsChanged);
        assert!(matches!(outcome, Authorization::Unknown));
    }

    #[test]
    fn a_denied_view_withholds_and_an_allowed_one_delivers() {
        let denied = decide(Ok(false), || ServerFrame::ReportsChanged);
        assert!(matches!(denied, Authorization::Withhold));
        let allowed = decide(Ok(true), || ServerFrame::ReportsChanged);
        assert!(matches!(allowed, Authorization::Deliver(_)));
    }
}
