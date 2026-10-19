// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Bot provisioning, command registration and permissioning, in call order:
//! create, list, register commands as the bot itself, read both ways,
//! repermission, revoke - order matters since a revoked token can no longer
//! call `setBotCommands`, and `setBotPermissions`/`revokeBot` both need a
//! live bot.
//!
//! Runs near the end of the script, after the member-facing cases, because
//! creating a bot adds a member and nothing earlier should have to account for
//! it.

use serde_json::json;

use crate::world::Contract;

use super::text;

pub(crate) async fn bot_calls(c: &mut Contract, root: &str, channel: &str) {
    let created = c
        .json(
            "createBot",
            "POST",
            "/bots",
            root,
            json!({ "username": "helper-bot", "display_name": "Helper" }),
        )
        .await;
    c.get("listBots", "/bots", root).await;
    c.get("getSuggestedBotPrefix", "/bots/suggested-prefix", root)
        .await;

    let bot_id = text(&created["bot"], "user_id");
    let bot_token = text(&created, "token");

    c.json(
        "setBotCommands",
        "PUT",
        "/bots/commands",
        &bot_token,
        json!({
            "prefix": "!",
            "commands": [
                { "name": "ping", "description": "check if I'm alive" },
                {
                    "name": "sources",
                    "description": "pick a store",
                    "options": [{ "name": "source", "required": true, "choices": ["steam", "gog"] }]
                }
            ]
        }),
    )
    .await;
    c.get(
        "getMemberPermissions",
        &format!("/members/{bot_id}/permissions"),
        &bot_token,
    )
    .await;
    c.get("getBotCommands", &format!("/bots/{bot_id}/commands"), root)
        .await;
    c.get(
        "listChannelBotCommands",
        &format!("/channels/{channel}/bot-commands"),
        root,
    )
    .await;

    let anchor = c
        .json(
            "sendMessage",
            "POST",
            &format!("/channels/{channel}/messages"),
            root,
            json!({ "id": uuid::Uuid::now_v7().to_string(), "content": "!ping" }),
        )
        .await;
    c.json(
        "sendEphemeralMessage",
        "POST",
        &format!("/channels/{channel}/ephemeral-messages"),
        &bot_token,
        json!({ "in_reply_to_id": text(&anchor, "id"), "content": "pong, only you" }),
    )
    .await;

    let with_buttons = c
        .json(
            "sendMessage",
            "POST",
            &format!("/channels/{channel}/messages"),
            &bot_token,
            json!({
                "id": uuid::Uuid::now_v7().to_string(),
                "content": "pick one",
                "components": [{ "buttons": [
                    { "label": "Yes", "style": "primary", "custom_id": "yes" },
                    { "label": "Docs", "style": "link", "url": "https://example.com" }
                ]}]
            }),
        )
        .await;
    let message_id = text(&with_buttons, "id");
    let press_id = uuid::Uuid::now_v7().to_string();
    c.json(
        "pressMessageButton",
        "POST",
        &format!("/channels/{channel}/messages/{message_id}/interactions"),
        root,
        json!({ "id": press_id, "custom_id": "yes" }),
    )
    .await;
    c.json(
        "setMessageComponents",
        "PUT",
        &format!("/channels/{channel}/messages/{message_id}/components"),
        &bot_token,
        json!({ "components": [], "interaction_id": press_id }),
    )
    .await;
    c.bare(
        "acknowledgeInteraction",
        "POST",
        &format!("/channels/{channel}/interactions/{press_id}/ack"),
        &bot_token,
    )
    .await;

    c.json(
        "setBotUi",
        "PUT",
        "/bots/ui",
        &bot_token,
        json!({ "message_menu": [{ "id": "translate", "label": "Translate" }] }),
    )
    .await;
    c.get(
        "listChannelBotUi",
        &format!("/channels/{channel}/bot-ui"),
        root,
    )
    .await;
    c.json(
        "useBotUiEntry",
        "POST",
        &format!("/channels/{channel}/bot-ui/{bot_id}/interactions"),
        root,
        json!({
            "id": uuid::Uuid::now_v7().to_string(),
            "surface": "message_menu",
            "entry_id": "translate",
            "message_id": message_id,
        }),
    )
    .await;

    watch_session_calls(c, root, &bot_token).await;

    c.json(
        "setBotPermissions",
        "PATCH",
        &format!("/bots/{bot_id}/permissions"),
        root,
        json!({ "permissions": 0 }),
    )
    .await;
    c.bare("revokeBot", "POST", &format!("/bots/{bot_id}/revoke"), root)
        .await;
}

/// A bot runs a watch session in a voice channel of its own and a member reads it.
async fn watch_session_calls(c: &mut Contract, root: &str, bot_token: &str) {
    let room = c
        .json(
            "createChannel",
            "POST",
            "/channels",
            root,
            json!({ "name": "watch-room", "kind": "voice" }),
        )
        .await;
    let room_id = text(&room, "id");
    let uri = format!("/channels/{room_id}/watch-session");
    c.bare(
        "sendVoiceHeartbeat",
        "POST",
        &format!("/channels/{room_id}/voice/heartbeat"),
        bot_token,
    )
    .await;
    c.json(
        "setWatchSession",
        "PUT",
        &uri,
        bot_token,
        json!({
            "item_id": "item-1",
            "title": "A Film",
            "duration_ms": 5_400_000,
            "playing": true,
            "position_ms": 60_000,
        }),
    )
    .await;
    c.json(
        "tickWatchSession",
        "POST",
        &format!("{uri}/tick"),
        bot_token,
        json!({ "playing": true, "position_ms": 65_000 }),
    )
    .await;
    c.get("getWatchSession", &uri, root).await;
    c.bare("endWatchSession", "DELETE", &uri, bot_token).await;
}
