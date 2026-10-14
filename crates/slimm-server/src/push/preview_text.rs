// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a lock-screen preview says for a message with no text of its own.
//!
//! A bot's embed-only post and a member's bare image carry empty `content`,
//! and the iOS extension refuses an empty body and leaves "New message", so
//! the preview reads what the message does carry instead.

use crate::ids::MessageId;
use crate::store::{AttachmentSummary, Embed, Store};

/// The text a preview shows: the message's own, or else what it carries.
pub(super) async fn preview_text(store: &Store, message_id: MessageId, content: &str) -> String {
    if !content.trim().is_empty() {
        return content.to_owned();
    }
    let embeds = store
        .embeds_for_messages(&[message_id])
        .await
        .ok()
        .and_then(|rows| rows.into_iter().next())
        .map(|(_, embeds)| embeds)
        .unwrap_or_default();
    let attachments = store
        .attachments_for_messages(&[message_id])
        .await
        .ok()
        .and_then(|rows| rows.into_iter().next())
        .map(|(_, attachments)| attachments)
        .unwrap_or_default();
    describe(&embeds, &attachments)
}

/// Pure so it can be tested without a store: the first embed's title, then its
/// description, then its author; otherwise a sentence about the attachments.
pub(super) fn describe(embeds: &[Embed], attachments: &[AttachmentSummary]) -> String {
    let from_embed = embeds.iter().find_map(|embed| {
        [&embed.title, &embed.description, &embed.author_name]
            .into_iter()
            .flatten()
            .map(|text| text.trim())
            .find(|text| !text.is_empty())
            .map(str::to_owned)
    });
    if let Some(text) = from_embed {
        return text;
    }
    match attachments {
        [] => String::new(),
        [one] if one.content_type.starts_with("image/") => "Sent an image".to_owned(),
        [one] if one.content_type.starts_with("video/") => "Sent a video".to_owned(),
        [one] => format!("Sent {}", one.filename),
        many if many.iter().all(|a| a.content_type.starts_with("image/")) => {
            format!("Sent {} images", many.len())
        }
        many => format!("Sent {} files", many.len()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn embed(title: Option<&str>, description: Option<&str>) -> Embed {
        Embed {
            title: title.map(str::to_owned),
            description: description.map(str::to_owned),
            url: None,
            color: None,
            author_name: None,
            author_url: None,
            footer_text: None,
            timestamp: None,
            image_url: None,
            thumbnail_url: None,
            fields: Vec::new(),
        }
    }

    fn file(name: &str, kind: &str) -> AttachmentSummary {
        AttachmentSummary {
            id: "a".to_owned(),
            filename: name.to_owned(),
            content_type: kind.to_owned(),
            size: 1,
            spoiler: false,
        }
    }

    #[test]
    fn an_embed_names_the_message_before_its_attachments() {
        let embeds = [embed(Some("  "), Some("Dune: Part Two"))];
        let files = [file("poster.png", "image/png")];
        assert_eq!(describe(&embeds, &files), "Dune: Part Two");
    }

    #[test]
    fn attachments_alone_are_described() {
        assert_eq!(
            describe(&[], &[file("a.png", "image/png")]),
            "Sent an image"
        );
        assert_eq!(
            describe(&[], &[file("notes.pdf", "application/pdf")]),
            "Sent notes.pdf"
        );
        let two = [file("a.png", "image/png"), file("b.jpg", "image/jpeg")];
        assert_eq!(describe(&[], &two), "Sent 2 images");
        assert_eq!(describe(&[], &[]), "");
    }
}
