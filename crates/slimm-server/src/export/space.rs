// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A whole space for an administrator. Direct messages, deleted content and
//! every credential stay out; see `store::export_space` for the queries.

use serde_json::{Value, json};
use uuid::Uuid;

use super::build::{Builder, Rows};

const NOT_INCLUDED: &[&str] = &[
    "Direct messages",
    "Deleted messages, deleted channels and temporary voice rooms",
    "Passwords, sessions, devices, push tokens, two-factor secrets and bot tokens",
    "Invites, reports, moderation history and the admin audit log",
    "Canvas boards, polls, module data and webhook secrets",
    "Edit history: only the current text of each message",
];

const TRACKED: Rows = Rows {
    track: true,
    skip_empty: true,
};
const PLAIN: Rows = Rows {
    track: false,
    skip_empty: false,
};

pub(super) async fn collect(b: &mut Builder<'_>) -> anyhow::Result<()> {
    let store = b.store().clone();
    let (messages, files) = store.export_space_counts().await?;
    b.set_total(u64::try_from(messages + files)?).await?;
    b.not_included(NOT_INCLUDED);

    let mut space = store
        .export_space_settings()
        .await?
        .unwrap_or_else(|| json!({}));
    space["name"] = json!(store.deployment_name().await?);
    b.json(
        "space.json",
        "The space's name, description, rules and join policy",
        &space,
    )
    .await?;
    space_images(b, &space).await?;
    b.jsonl(
        "roles.jsonl",
        "Roles and their permission bits",
        store.export_space_roles(),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "categories.jsonl",
        "Channel categories",
        store.export_space_categories(),
        PLAIN,
    )
    .await?;
    let channels = channel_ids(b, &store).await?;
    b.jsonl(
        "members.jsonl",
        "Members, bots and webhooks with their role ids; no credentials",
        store.export_space_members(),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "pins.jsonl",
        "Pinned messages",
        store.export_space_pins(),
        PLAIN,
    )
    .await?;
    b.jsonl(
        "emoji.jsonl",
        "Custom emoji",
        store.export_space_emoji(),
        PLAIN,
    )
    .await?;
    for channel in channels {
        let path = format!("channels/{channel}/messages.jsonl");
        b.jsonl(
            &path,
            "Messages of one channel or thread, oldest first",
            store.export_space_messages(channel),
            TRACKED,
        )
        .await?;
    }
    b.jsonl(
        "attachments.jsonl",
        "Index of the files on messages and emoji",
        store.export_space_attachments(),
        PLAIN,
    )
    .await?;
    Ok(())
}

/// Writes `channels.jsonl` and returns the ids whose messages follow.
async fn channel_ids(
    b: &mut Builder<'_>,
    store: &crate::store::Store,
) -> anyhow::Result<Vec<Uuid>> {
    let mut rows = store.export_space_channels();
    let mut ids = Vec::new();
    while let Some(row) = rows.recv().await {
        if let Some(id) = row?["id"].as_str().and_then(|s| Uuid::parse_str(s).ok()) {
            ids.push(id);
        }
    }
    b.jsonl(
        "channels.jsonl",
        "Channels, threads and their permission overwrites",
        store.export_space_channels(),
        PLAIN,
    )
    .await?;
    Ok(ids)
}

async fn space_images(b: &mut Builder<'_>, space: &Value) -> anyhow::Result<()> {
    if !space["icon_updated_at"].is_null()
        && let Ok(bytes) = b.media().read_space_icon().await
    {
        b.binary("space/icon", "The space icon image", &bytes)
            .await?;
    }
    if !space["banner_updated_at"].is_null()
        && let Ok(bytes) = b.media().read_space_banner().await
    {
        b.binary("space/banner", "The space banner image", &bytes)
            .await?;
    }
    Ok(())
}
