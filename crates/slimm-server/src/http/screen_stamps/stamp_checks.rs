// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The checks on a stamp request that need no store: one content, a place on the screen, a size.

use serde::Deserialize;
use uuid::Uuid;

use super::super::reaction_emoji::is_reaction;
use crate::ids::{EmojiId, UserId};

/// The smallest and largest longest side, as a fraction of the shared screen's height.
pub(super) const SIZE_RANGE: (f64, f64) = (0.04, 0.30);

/// `POST /channels/{channel_id}/voice/screen-stamps`.
#[derive(Deserialize)]
pub(super) struct StampRequest {
    id: String,
    target_user_id: String,
    x: f64,
    y: f64,
    size: f64,
    #[serde(default)]
    emoji: Option<String>,
    #[serde(default)]
    attachment_id: Option<String>,
}

/// What a well-formed stamp shows.
#[derive(Debug, PartialEq)]
pub(super) enum Content {
    Emoji(String),
    /// An attachment's raw sha256.
    Picture(Vec<u8>),
}

/// A stamp request that passed every check that needs no store.
#[derive(Debug, PartialEq)]
pub(super) struct Checked {
    pub id: Uuid,
    pub target: UserId,
    pub centre: (f64, f64),
    pub size: f64,
    pub content: Content,
}

/// The request's fields, checked and with the size clamped, or why it was refused.
pub(super) fn check(req: StampRequest) -> Result<Checked, &'static str> {
    let id = Uuid::parse_str(&req.id).map_err(|_| "invalid id")?;
    let target =
        UserId(Uuid::parse_str(&req.target_user_id).map_err(|_| "invalid target_user_id")?);
    let on_screen = |v: f64| v.is_finite() && (0.0..=1.0).contains(&v);
    if !on_screen(req.x) || !on_screen(req.y) {
        return Err("x and y must be between 0 and 1");
    }
    if !req.size.is_finite() {
        return Err("size must be a number");
    }
    let content = match (req.emoji, req.attachment_id) {
        (Some(emoji), None) if is_reaction(&emoji) => Content::Emoji(emoji),
        (Some(_), None) => return Err("emoji must be one emoji, a :shortcode: or an emoji id"),
        (None, Some(hex)) => Content::Picture(
            crate::media::from_hex(&hex)
                .filter(|bytes| bytes.len() == 32)
                .ok_or("invalid attachment_id")?,
        ),
        _ => return Err("a stamp needs exactly one of emoji or attachment_id"),
    };
    Ok(Checked {
        id,
        target,
        centre: (req.x, req.y),
        size: req.size.clamp(SIZE_RANGE.0, SIZE_RANGE.1),
        content,
    })
}

/// The custom emoji an emoji stamp names by id, which must exist in this Space.
pub(super) fn custom_emoji_id(key: &str) -> Option<EmojiId> {
    Uuid::parse_str(key).ok().map(EmojiId)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(emoji: Option<&str>, attachment_id: Option<&str>) -> StampRequest {
        StampRequest {
            id: Uuid::now_v7().to_string(),
            target_user_id: Uuid::now_v7().to_string(),
            x: 0.42,
            y: 0.31,
            size: 0.12,
            emoji: emoji.map(str::to_owned),
            attachment_id: attachment_id.map(str::to_owned),
        }
    }

    #[test]
    fn an_emoji_stamp_passes_with_its_centre_and_size() {
        let checked = check(request(Some("\u{1F389}"), None)).unwrap();
        assert_eq!(checked.centre, (0.42, 0.31));
        assert_eq!(checked.size, 0.12);
        assert_eq!(checked.content, Content::Emoji("\u{1F389}".to_owned()));
    }

    #[test]
    fn a_picture_stamp_names_a_sha256() {
        let checked = check(request(None, Some(&"ab".repeat(32)))).unwrap();
        assert_eq!(checked.content, Content::Picture(vec![0xab; 32]));
        assert!(check(request(None, Some("abcd"))).is_err());
        assert!(check(request(None, Some(&"zz".repeat(32)))).is_err());
    }

    #[test]
    fn a_stamp_carries_exactly_one_content() {
        assert!(check(request(None, None)).is_err());
        assert!(check(request(Some("\u{1F389}"), Some(&"ab".repeat(32)))).is_err());
    }

    #[test]
    fn an_emoji_stamp_cannot_smuggle_text() {
        assert!(check(request(Some("buy my thing at example.com"), None)).is_err());
        assert!(check(request(Some(":party_parrot:"), None)).is_ok());
        assert!(check(request(Some(&Uuid::now_v7().to_string()), None)).is_ok());
    }

    #[test]
    fn the_size_is_clamped_to_the_cap() {
        let mut huge = request(Some("\u{1F389}"), None);
        huge.size = 5.0;
        assert_eq!(check(huge).unwrap().size, SIZE_RANGE.1);
        let mut tiny = request(Some("\u{1F389}"), None);
        tiny.size = -1.0;
        assert_eq!(check(tiny).unwrap().size, SIZE_RANGE.0);
    }

    #[test]
    fn a_centre_off_the_screen_is_refused() {
        for (x, y) in [
            (-0.01, 0.5),
            (0.5, 1.01),
            (f64::NAN, 0.5),
            (0.5, f64::INFINITY),
        ] {
            let mut off = request(Some("\u{1F389}"), None);
            off.x = x;
            off.y = y;
            assert!(check(off).is_err(), "({x}, {y})");
        }
    }

    #[test]
    fn only_a_uuid_key_names_a_custom_emoji() {
        let id = Uuid::now_v7();
        assert_eq!(custom_emoji_id(&id.to_string()), Some(EmojiId(id)));
        assert_eq!(custom_emoji_id(":party:"), None);
        assert_eq!(custom_emoji_id("\u{1F389}"), None);
    }
}
