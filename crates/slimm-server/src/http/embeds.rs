// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Embeds: the colour-to-accent mapping and the wire DTO. The write half is
//! [`build`]. See `docs/decisions/0030-incoming-webhooks.md`.

mod build;
mod rfc3339;
mod webhook;

pub(crate) use build::{RawEmbed, build_embeds};
pub(crate) use webhook::{WebhookEmbed, null_as_empty};

use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::link_preview::LinkPreviews;
use crate::ids::{MessageId, UserId};
use crate::store::{Embed as StoreEmbed, NewEmbed};

/// A caller-supplied colour, reduced to one of a small closed set of
/// pre-tuned swatches - never a raw hex fill. See decision 0030.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EmbedAccent {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
}

/// Buckets a caller's raw 24-bit RGB integer into a hue range, or `None`
/// when it is absent, out of range, or too close to grey/black/white.
pub fn accent_for(color: i64) -> Option<EmbedAccent> {
    if !(0..=0xFF_FFFF).contains(&color) {
        return None;
    }
    let r = ((color >> 16) & 0xFF) as f64 / 255.0;
    let g = ((color >> 8) & 0xFF) as f64 / 255.0;
    let b = (color & 0xFF) as f64 / 255.0;
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let delta = max - min;
    let lightness = (max + min) / 2.0;
    if delta < 0.04 || !(0.06..0.94).contains(&lightness) {
        return None;
    }
    let saturation = delta / (1.0 - (2.0 * lightness - 1.0).abs());
    if saturation < 0.15 {
        return None;
    }
    let hue = if max == r {
        60.0 * (((g - b) / delta).rem_euclid(6.0))
    } else if max == g {
        60.0 * (((b - r) / delta) + 2.0)
    } else {
        60.0 * (((r - g) / delta) + 4.0)
    };
    // Six buckets, uneven: green and blue each span a wide perceptual band, red a narrow one.
    let hue = hue.rem_euclid(360.0);
    Some(match hue {
        h if !(15.0..345.0).contains(&h) => EmbedAccent::Red,
        h if h < 45.0 => EmbedAccent::Orange,
        h if h < 80.0 => EmbedAccent::Yellow,
        h if h < 170.0 => EmbedAccent::Green,
        h if h < 255.0 => EmbedAccent::Blue,
        _ => EmbedAccent::Purple,
    })
}

/// One field on an embed, exactly as it renders.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct EmbedFieldDto {
    pub(crate) name: String,
    pub(crate) value: String,
    pub(crate) inline: bool,
}

/// One embed as a message carries it. `image_token`/`thumbnail_token` are
/// redeemable tokens, never raw URLs - see decision 0019.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct EmbedDto {
    pub(crate) title: Option<String>,
    pub(crate) description: Option<String>,
    pub(crate) url: Option<String>,
    pub(crate) accent: Option<EmbedAccent>,
    pub(crate) author_name: Option<String>,
    pub(crate) author_url: Option<String>,
    #[serde(default)]
    pub(crate) fields: Vec<EmbedFieldDto>,
    pub(crate) footer_text: Option<String>,
    pub(crate) timestamp: Option<i64>,
    pub(crate) image_token: Option<String>,
    pub(crate) thumbnail_token: Option<String>,
}

/// Builds the wire DTO for one stored embed; the caller resolves the image
/// tokens first.
fn to_dto(
    embed: StoreEmbed,
    image_token: Option<String>,
    thumbnail_token: Option<String>,
) -> EmbedDto {
    EmbedDto {
        title: embed.title,
        description: embed.description,
        url: embed.url,
        accent: embed.color.and_then(accent_for),
        author_name: embed.author_name,
        author_url: embed.author_url,
        fields: embed
            .fields
            .into_iter()
            .map(|f| EmbedFieldDto {
                name: f.name,
                value: f.value,
                inline: f.inline,
            })
            .collect(),
        footer_text: embed.footer_text,
        timestamp: embed.timestamp,
        image_token,
        thumbnail_token,
    }
}

/// `(image_url, thumbnail_url)` to resolve before [`to_dto`].
fn image_urls(embed: &StoreEmbed) -> (Option<&str>, Option<&str>) {
    (embed.image_url.as_deref(), embed.thumbnail_url.as_deref())
}

/// Resolves every stored embed's images and builds the wire shape.
pub(crate) fn dtos_from_stored(
    link_previews: &LinkPreviews,
    stored: Vec<StoreEmbed>,
) -> Vec<EmbedDto> {
    stored
        .into_iter()
        .map(|embed| {
            let (image_url, thumbnail_url) = image_urls(&embed);
            let image_token = image_url.and_then(|url| link_previews.embed_image_token(url));
            let thumbnail_token =
                thumbnail_url.and_then(|url| link_previews.embed_image_token(url));
            to_dto(embed, image_token, thumbnail_token)
        })
        .collect()
}

/// `raw` built into embeds, only when `caller` is a bot.
pub(crate) async fn honored_for_send(
    state: &AppState,
    caller: UserId,
    raw: Vec<RawEmbed>,
) -> Result<Vec<NewEmbed>, ApiError> {
    if raw.is_empty() || !state.store.is_bot(caller).await? {
        return Ok(Vec::new());
    }
    build_embeds(raw, &state.link_previews)
}

/// Stores `embeds` when `fresh`, then reads back whatever actually landed.
pub(crate) async fn store_and_reload(
    state: &AppState,
    message_id: MessageId,
    fresh: bool,
    embeds: &[NewEmbed],
) -> anyhow::Result<Vec<StoreEmbed>> {
    if fresh && !embeds.is_empty() {
        state.store.set_message_embeds(message_id, embeds).await?;
    }
    Ok(state
        .store
        .embeds_for_messages(&[message_id])
        .await?
        .into_iter()
        .next()
        .map(|(_, stored)| stored)
        .unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pure_red_buckets_to_red() {
        assert_eq!(accent_for(0xE0_3B3B), Some(EmbedAccent::Red));
    }

    #[test]
    fn a_pure_green_buckets_to_green() {
        assert_eq!(accent_for(0x2E_A043), Some(EmbedAccent::Green));
    }

    #[test]
    fn a_pure_blue_buckets_to_blue() {
        assert_eq!(accent_for(0x1B_6F91), Some(EmbedAccent::Blue));
    }

    #[test]
    fn a_purple_buckets_to_purple() {
        assert_eq!(accent_for(0x8A_3FFC), Some(EmbedAccent::Purple));
    }

    #[test]
    fn black_has_no_accent() {
        assert_eq!(accent_for(0x00_0000), None);
    }

    #[test]
    fn white_has_no_accent() {
        assert_eq!(accent_for(0xFF_FFFF), None);
    }

    #[test]
    fn a_near_grey_has_no_accent() {
        assert_eq!(accent_for(0x80_8080), None);
    }

    #[test]
    fn an_out_of_range_value_has_no_accent() {
        assert_eq!(accent_for(-1), None);
        assert_eq!(accent_for(0x0100_0000), None);
    }
}
