// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The half of the pass that builds and reads content: channels, roles and
//! overwrites, then a message carrying every optional part a `Message` has -
//! an attachment, a poll, a reaction and a pin - so the calls that return
//! whole messages return a fully populated one rather than a bare text row.

use serde_json::json;
use uuid::Uuid;

use super::read_state::read_state;
use super::{
    PNG, THUMBS_UP, media_slot_calls, object_lock_calls, overwrite_calls, role_calls, text,
};
use crate::world::{Contract, Payload};

/// Builds the channel the message calls run in, plus the role, overwrite and
/// direct-message state, and returns that channel's id and the caller's DM
/// channel id with bob.
pub(super) async fn channel_calls(c: &mut Contract, root: &str, bob_id: &str) -> (String, String) {
    c.get("listChannels", "/channels", root).await;
    let channel = c
        .json(
            "createChannel",
            "POST",
            "/channels",
            root,
            json!({ "name": "contract", "kind": "text" }),
        )
        .await;
    let channel = text(&channel, "id");
    c.json(
        "updateChannel",
        "PATCH",
        &format!("/channels/{channel}"),
        root,
        json!({ "name": "contract", "topic": "what the schema promises" }),
    )
    .await;
    c.get(
        "getChannelPermissions",
        &format!("/channels/{channel}/permissions"),
        root,
    )
    .await;
    let scratch = c
        .json(
            "createChannel",
            "POST",
            "/channels",
            root,
            json!({ "name": "scratch", "kind": "voice" }),
        )
        .await;
    c.bare(
        "deleteChannel",
        "DELETE",
        &format!("/channels/{}", text(&scratch, "id")),
        root,
    )
    .await;

    let category = c
        .json(
            "createCategory",
            "POST",
            "/categories",
            root,
            json!({ "name": "extras" }),
        )
        .await;
    let category_id = text(&category, "id");
    c.json(
        "updateCategory",
        "PATCH",
        &format!("/categories/{category_id}"),
        root,
        json!({ "name": "extras", "position": 0 }),
    )
    .await;
    let scratch_category = c
        .json(
            "createCategory",
            "POST",
            "/categories",
            root,
            json!({ "name": "scratch" }),
        )
        .await;
    c.bare(
        "deleteCategory",
        "DELETE",
        &format!("/categories/{}", text(&scratch_category, "id")),
        root,
    )
    .await;

    c.get("listCategories", "/categories", root).await;

    let live = c.get("listChannels", "/channels", root).await;
    let mut order: Vec<String> = live
        .as_array()
        .unwrap()
        .iter()
        .map(|c| text(c, "id"))
        .collect();
    order.reverse();
    c.json(
        "reorderChannels",
        "PUT",
        "/channels/order",
        root,
        json!({
            "categories": [{ "category_id": category_id, "channel_ids": order }]
        }),
    )
    .await;

    let dm = c
        .bare("openDirectMessage", "POST", &format!("/dms/{bob_id}"), root)
        .await;
    let dm_channel = text(&dm, "channel_id");
    c.get("listDirectMessages", "/dms", root).await;
    c.bare(
        "hideDirectMessage",
        "DELETE",
        &format!("/dms/{bob_id}"),
        root,
    )
    .await;

    role_calls(c, root, bob_id).await;

    let first_stroke = c
        .json(
            "placeCanvasObject",
            "POST",
            &format!("/channels/{channel}/canvas/objects"),
            root,
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "stroke",
                "x": 100.0, "y": 100.0, "w": 40.0, "h": 20.0,
                "props": { "points": [0.0, 0.0, 40.0, 20.0], "width": 3.0, "color": "annotation" },
            }),
        )
        .await;
    let first_object_id = text(&first_stroke, "id");
    // A second object, so removing the first below still leaves listCanvasViewport's page non-empty.
    c.json(
        "placeCanvasObject",
        "POST",
        &format!("/channels/{channel}/canvas/objects"),
        root,
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "stroke",
            "x": 200.0, "y": 200.0, "w": 40.0, "h": 20.0,
            "props": { "points": [0.0, 0.0, 40.0, 20.0], "width": 3.0, "color": "annotation" },
        }),
    )
    .await;
    let removed = c
        .json(
            "submitCanvasOp",
            "POST",
            &format!("/channels/{channel}/canvas/ops"),
            root,
            json!({
                "id": Uuid::now_v7().to_string(),
                "kind": "remove",
                "object_ids": [first_object_id],
            }),
        )
        .await;
    let remove_op_id = text(&removed["op"], "id");
    // Undoes the removal above, so this response's `op.kind` is `restore` and
    // `object_ids` is exercised on that shape too, not only on `remove`.
    c.json(
        "submitCanvasOp",
        "POST",
        &format!("/channels/{channel}/canvas/ops"),
        root,
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "restore",
            "target_op": remove_op_id,
        }),
    )
    .await;
    // A canvas image needs an already-uploaded attachment to name.
    let canvas_attachment = c
        .call(
            "uploadAttachment",
            "POST",
            "/attachments?filename=pasted.png",
            Some(root),
            Payload::Bytes(PNG.to_vec()),
        )
        .await;
    let canvas_attachment = text(&canvas_attachment, "id");
    // Exercises the `image` kind on both `CanvasObjectPlacement` and `CanvasObject`.
    c.json(
        "placeCanvasObject",
        "POST",
        &format!("/channels/{channel}/canvas/objects"),
        root,
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "image",
            "x": 300.0, "y": 300.0, "w": 64.0, "h": 64.0,
            "props": { "attachment": canvas_attachment, "content_type": "image/png" },
        }),
    )
    .await;
    // Exercises `move` on `CanvasOpRequest`, `CanvasOpResult` and the ops feed below.
    c.json(
        "submitCanvasOp",
        "POST",
        &format!("/channels/{channel}/canvas/ops"),
        root,
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "move",
            "object_id": first_object_id,
            "x": 250.0, "y": 250.0, "w": 40.0, "h": 20.0,
        }),
    )
    .await;
    // Exercises `reorder` on `CanvasOpRequest`, `CanvasOpResult` and the ops feed below.
    c.json(
        "submitCanvasOp",
        "POST",
        &format!("/channels/{channel}/canvas/ops"),
        root,
        json!({
            "id": Uuid::now_v7().to_string(),
            "kind": "reorder",
            "object_id": first_object_id,
            "z_index": 500,
        }),
    )
    .await;
    // Both objects live again, so this page still carries what it had before.
    c.get(
        "listCanvasViewport",
        &format!("/channels/{channel}/canvas/objects?min_x=0&min_y=0&max_x=1920&max_y=1080"),
        root,
    )
    .await;
    // Covers place, remove, restore, a second place (the image), move, and reorder.
    c.get(
        "listCanvasOps",
        &format!("/channels/{channel}/canvas/ops?after_seq=0"),
        root,
    )
    .await;
    media_slot_calls(c, root, &channel, bob_id).await;
    object_lock_calls(c, root, &channel).await;

    overwrite_calls(c, root, bob_id, &channel).await;

    (channel, dm_channel)
}

/// Sends everything a `Message` can carry - an attachment, a poll, a reaction
/// and a pin - before the two calls that return whole messages read it back.
/// Returns the id of the message the reports below are filed against.
pub(super) async fn message_calls(c: &mut Contract, root: &str, channel: &str) -> String {
    let attachment = c
        .call(
            "uploadAttachment",
            "POST",
            "/attachments?filename=pixel.png",
            Some(root),
            Payload::Bytes(PNG.to_vec()),
        )
        .await;
    let attachment = text(&attachment, "id");
    let messages = format!("/channels/{channel}/messages");
    let sent = c
        .json(
            "sendMessage",
            "POST",
            &messages,
            root,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "the first message",
                "attachment_ids": [attachment],
            }),
        )
        .await;
    let message = text(&sent, "id");
    let seq = sent["seq"].as_i64().unwrap_or(0);
    // Only fetchable once a live message references it, so not before now.
    c.get("getAttachment", &format!("/attachments/{attachment}"), root)
        .await;

    c.json(
        "editMessage",
        "PATCH",
        &format!("{messages}/{message}"),
        root,
        json!({ "content": "the first message, edited" }),
    )
    .await;
    c.get("getMessage", &format!("{messages}/{message}"), root)
        .await;
    // Now that it has been edited, its history has more than one version.
    c.get(
        "getMessageHistory",
        &format!("{messages}/{message}/history"),
        root,
    )
    .await;
    let poll = c
        .json(
            "sendPollMessage",
            "POST",
            &format!("{messages}/polls"),
            root,
            json!({
                "id": Uuid::now_v7().to_string(),
                "content": "pick one",
                "question": "does the schema still describe this?",
                "options": ["yes", "no"],
            }),
        )
        .await;
    c.json(
        "votePoll",
        "PUT",
        &format!("/messages/{}/polls/vote", text(&poll, "id")),
        root,
        json!({ "option": 0 }),
    )
    .await;
    c.bare(
        "addReaction",
        "PUT",
        &format!("/messages/{message}/reactions/{THUMBS_UP}"),
        root,
    )
    .await;
    c.get(
        "listReactionUsers",
        &format!("/messages/{message}/reactions/{THUMBS_UP}"),
        root,
    )
    .await;

    c.bare(
        "pinMessage",
        "PUT",
        &format!("{messages}/{message}/pin"),
        root,
    )
    .await;
    // Thread calls (openThread, getThreadParent, listThreads) moved to threads.rs; see script.rs.
    c.get(
        "listPinnedMessages",
        &format!("/channels/{channel}/pins"),
        root,
    )
    .await;
    c.get(
        "getPinnedMessageCount",
        &format!("/channels/{channel}/pins/count"),
        root,
    )
    .await;

    c.get("listMessages", &format!("{messages}?limit=50"), root)
        .await;
    c.get(
        "searchMessages",
        &format!("{messages}/search?q=message&limit=10"),
        root,
    )
    .await;
    c.get(
        "searchMessagesAll",
        "/search/messages?q=message&limit=10",
        root,
    )
    .await;
    read_state(c, root, channel, seq).await;

    // Saved before the list, so listSavedMessages validates a populated answer rather than an empty array.
    c.bare(
        "saveMessage",
        "PUT",
        &format!("/messages/{message}/save"),
        root,
    )
    .await;
    c.get("listSavedMessages", "/saved", root).await;
    c.bare(
        "unsaveMessage",
        "DELETE",
        &format!("/messages/{message}/save"),
        root,
    )
    .await;

    c.bare(
        "unpinMessage",
        "DELETE",
        &format!("{messages}/{message}/pin"),
        root,
    )
    .await;
    c.bare(
        "removeReaction",
        "DELETE",
        &format!("/messages/{message}/reactions/{THUMBS_UP}"),
        root,
    )
    .await;

    let doomed = c
        .json(
            "sendMessage",
            "POST",
            &messages,
            root,
            json!({ "id": Uuid::now_v7().to_string(), "content": "delete me" }),
        )
        .await;
    c.bare(
        "deleteMessage",
        "DELETE",
        &format!("{messages}/{}", text(&doomed, "id")),
        root,
    )
    .await;

    // Two at once, so the bulk path is driven with more than one id.
    let mut doomed_ids = Vec::new();
    for _ in 0..2 {
        let body = json!({ "id": Uuid::now_v7().to_string(), "content": "delete us" });
        let sent = c.json("sendMessage", "POST", &messages, root, body).await;
        doomed_ids.push(text(&sent, "id").to_owned());
    }
    let bulk = format!("{messages}/bulk-delete");
    let ids = json!({ "message_ids": doomed_ids });
    c.json("bulkDeleteMessages", "POST", &bulk, root, ids).await;

    message
}
