// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Authorizing a button click, a form and its answer for one connection. See
//! docs/decisions/0039-bot-message-buttons.md.

use super::authorization::{Authorization, read_with_retry};
use super::frames::ServerFrame;
use super::interaction_click_frame::InteractionClickFrame;
use crate::components::form::Form;
use crate::hub::Event;
use crate::permissions::Permissions;
use crate::store::{Interaction, SessionContext, Store};

/// `None` when `event` is not an interaction event. A click goes to the owning
/// bot's connections only and its answer to the clicker's only, and both need
/// the recipient to still see the channel. These ride the ephemeral channel and
/// have no catch-up path, so the view read is retried once before giving up.
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
                ServerFrame::InteractionCreated(InteractionClickFrame::new(
                    interaction,
                    clicker_display_name,
                    input,
                ))
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
    let can_view = read_with_retry(|| {
        store.has_permission(
            ctx.user_id,
            interaction.channel_id,
            Permissions::VIEW_CHANNEL,
        )
    })
    .await;
    decide(can_view, frame)
}

/// A read that still fails after its retry is `Unknown`, never `Withhold`.
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

    #[tokio::test]
    async fn a_transient_view_read_failure_still_delivers() {
        let calls = std::cell::Cell::new(0);
        let can_view = read_with_retry(|| {
            calls.set(calls.get() + 1);
            let attempt = calls.get();
            async move {
                if attempt == 1 {
                    Err(anyhow::anyhow!("busy"))
                } else {
                    Ok(true)
                }
            }
        })
        .await;
        let outcome = decide(can_view, || ServerFrame::ReportsChanged);
        assert!(matches!(outcome, Authorization::Deliver(_)));
        assert_eq!(calls.get(), 2);
    }

    #[tokio::test]
    async fn a_persistent_failure_retries_once_then_gives_up() {
        let calls = std::cell::Cell::new(0);
        let can_view = read_with_retry(|| {
            calls.set(calls.get() + 1);
            async { Err::<bool, _>(anyhow::anyhow!("busy")) }
        })
        .await;
        assert!(can_view.is_err());
        assert_eq!(calls.get(), 2);
    }

    #[test]
    fn a_store_error_is_undecidable_not_withheld() {
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
