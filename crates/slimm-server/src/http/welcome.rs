// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The optional welcome post when a member joins. A failure here is logged and
//! never fails the join that triggered it.

use std::sync::Arc;

use uuid::Uuid;

use super::AppState;
use super::message_mentions::resolve_and_store;
use crate::hub::Event;
use crate::ids::{MessageId, UserId};
use crate::store::NewMessage;

/// Fills `{user}` with an @mention and `{space}` with the deployment name.
pub(super) fn render_welcome(template: &str, username: &str, space: &str) -> String {
    template
        .replace("{user}", &format!("@{username}"))
        .replace("{space}", space)
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
    let content = render_welcome(&welcome.message, &user.username, &space);
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
    if let Err(err) = resolve_and_store(
        state,
        channel_id,
        author,
        sent.message.id,
        &sent.message.content,
        None,
    )
    .await
    {
        tracing::warn!(%err, "welcome stored, but its mentions failed");
    }
    state.hub.publish(Event::MessageCreated {
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
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::render_welcome;

    #[test]
    fn fills_the_placeholders() {
        assert_eq!(
            render_welcome("Hi {user}, welcome to {space}", "sam", "Home"),
            "Hi @sam, welcome to Home"
        );
    }
}
