// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The optional welcome post when a member joins. A failure here is logged and
//! never fails the join that triggered it.

use std::sync::Arc;

use uuid::Uuid;

use super::AppState;
use super::message_mentions::resolve_and_store_under;
use super::module_mentions::{inert, mentionable};
use crate::hub::{Event, MessageEvent};
use crate::ids::{MessageId, UserId};
use crate::store::NewMessage;

/// Fills `{user}` with how the joiner is named and `{space}` with the deployment name.
pub(super) fn render_welcome(template: &str, who: &str, space: &str) -> String {
    template.replace("{user}", who).replace("{space}", space)
}

/// An @mention, or the display name when the username ends in a character the mention grammar drops.
fn joiner_text(username: &str, display_name: &str) -> String {
    if mentionable(username) {
        format!("@{username}")
    } else {
        inert(display_name)
    }
}

pub(super) async fn post_welcome(state: &AppState, user_id: UserId) {
    if let Err(err) = try_post(state, user_id).await {
        tracing::warn!(%err, "could not post the welcome message");
    }
}

async fn try_post(state: &AppState, user_id: UserId) -> anyhow::Result<()> {
    let welcome = state.store.space_welcome().await?;
    let Some(channel_id) = welcome.channel_id.filter(|_| welcome.enabled) else {
        return Ok(());
    };
    let Some(user) = state.store.user_profile(user_id).await? else {
        return Ok(());
    };
    if state.store.channel(channel_id).await?.is_none() {
        return Ok(());
    }
    let space = state.store.deployment_name().await?;
    let content = render_welcome(
        welcome.template(),
        &joiner_text(&user.username, &user.display_name),
        &space,
    );
    let author = state.store.welcome_author().await?;
    // Derived from the joiner, so a retried join cannot welcome them twice.
    let id = MessageId(Uuid::new_v5(&user_id.0, b"slimm-welcome"));
    let sent = state
        .store
        .send_message(NewMessage::plain(channel_id, author, id, &content))
        .await
        .map_err(|err| anyhow::anyhow!("{err:?}"))?;
    if !sent.fresh {
        return Ok(());
    }
    if let Err(err) = resolve_and_store_under(
        state,
        channel_id,
        (author, Some(author)),
        sent.message.id,
        &sent.message.content,
        (None, &[user_id]),
    )
    .await
    {
        tracing::warn!(%err, "welcome stored, but its mentions failed");
    }
    state.hub.publish(Event::Message(MessageEvent::Created {
        message: Arc::new(sent.message),
        attachments: Arc::new(Vec::new()),
        forwarded: None,
        app_surface: None,
        code_run: None,
        poll: None,
        embeds: Arc::new(Vec::new()),
        call: None,
        components: Arc::new(Vec::new()),
        lookups: Default::default(),
    }));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{joiner_text, render_welcome};

    #[test]
    fn fills_the_placeholders() {
        assert_eq!(
            render_welcome("Hi {user}, welcome to {space}", "@sam", "Home"),
            "Hi @sam, welcome to Home"
        );
    }

    #[test]
    fn a_username_the_grammar_would_cut_is_named_not_mentioned() {
        assert_eq!(joiner_text("sam", "Sam"), "@sam");
        assert_eq!(joiner_text("sam.", "Sam D"), "Sam D");
    }
}
