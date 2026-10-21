// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's own data. Every section comes from a query keyed on that member
//! (`store::export_member`), and the text of other people's messages is never
//! read: saved messages carry text only when the member wrote them.

use serde_json::json;

use super::build::{Builder, Rows};
use crate::ids::UserId;

const NOT_INCLUDED: &[&str] = &[
    "Messages written by other people, including the other side of your direct messages",
    "Direct messages you did not write",
    "Text of saved messages that someone else wrote (only their ids are kept)",
    "Messages and files you deleted, and anything in a deleted channel",
    "Your password, sign-in sessions, devices, push tokens and two-factor secrets",
    "Reports you filed, moderation records, invite codes you used",
    "Read positions and typing or presence state",
    "Canvas drawings and notes you placed, and polls, bots, webhooks or modules you created",
    "Who blocked you, and notes other members wrote about you",
];

const TRACKED: Rows = Rows {
    track: true,
    skip_empty: false,
};
const PLAIN: Rows = Rows {
    track: false,
    skip_empty: false,
};

pub(super) async fn collect(b: &mut Builder<'_>, user: UserId) -> anyhow::Result<()> {
    let store = b.store().clone();
    let (messages, files) = store.export_member_counts(user).await?;
    b.set_total(u64::try_from(messages + files)?).await?;
    b.not_included(NOT_INCLUDED);

    let profile = store
        .export_member_profile(user)
        .await?
        .ok_or_else(|| anyhow::anyhow!("the account is gone"))?;
    b.json("profile.json", "Your profile, nickname and roles", &profile)
        .await?;
    let settings = store.export_member_settings(user).await?;
    b.json(
        "settings.json",
        "Notification and presence settings",
        &settings.unwrap_or_else(|| json!({})),
    )
    .await?;
    b.jsonl(
        "linked_accounts.jsonl",
        "Accounts you linked, such as Discord",
        store.export_member_linked_accounts(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "messages.jsonl",
        "Messages you wrote, in channels and in direct messages",
        store.export_member_messages(user),
        TRACKED,
    )
    .await?;
    b.jsonl(
        "reactions.jsonl",
        "Reactions you added, by message id",
        store.export_member_reactions(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "saved.jsonl",
        "Messages you saved; text only for your own",
        store.export_member_saved(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "notes.jsonl",
        "Private notes you wrote about other members",
        store.export_member_notes(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "blocks.jsonl",
        "Members you blocked",
        store.export_member_blocks(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "poll_votes.jsonl",
        "Your votes in polls, by message id",
        store.export_member_poll_votes(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "call_events.jsonl",
        "When you joined and left voice calls",
        store.export_member_call_events(user),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "attachments.jsonl",
        "Index of the files you uploaded that are still on your messages",
        store.export_member_attachments(user),
        PLAIN,
    )
    .await?;
    profile_images(b, user, &profile).await
}

async fn profile_images(
    b: &mut Builder<'_>,
    user: UserId,
    profile: &serde_json::Value,
) -> anyhow::Result<()> {
    let id = user.to_string();
    if !profile["avatar_updated_at"].is_null()
        && let Ok(bytes) = b.media().read_avatar(&id).await
    {
        b.binary("profile/avatar", "Your avatar image", &bytes)
            .await?;
    }
    if !profile["banner_updated_at"].is_null()
        && let Ok(bytes) = b.media().read_user_banner(&id).await
    {
        b.binary("profile/banner", "Your profile banner image", &bytes)
            .await?;
    }
    Ok(())
}
