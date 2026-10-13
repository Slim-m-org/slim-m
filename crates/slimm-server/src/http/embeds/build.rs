// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The write half of embeds: caps and [`build_embeds`], shared by the
//! webhook and send routes. Caps are Discord's own limits; see
//! `docs/decisions/0030-incoming-webhooks.md`.

use serde::Deserialize;

use super::super::error::ApiError;
use super::super::link_preview::LinkPreviews;
use crate::store::{NewEmbed, NewEmbedField};

/// Most embeds one message may carry - Discord's own limit.
pub const MAX_EMBEDS_PER_MESSAGE: usize = 10;
/// Longest an embed's title may be.
pub const TITLE_MAX: usize = 256;
/// Longest an embed's description may be.
pub const DESCRIPTION_MAX: usize = 4096;
/// Most fields one embed may carry.
pub const FIELDS_MAX: usize = 25;
/// Longest one field's name may be.
pub const FIELD_NAME_MAX: usize = 256;
/// Longest one field's value may be.
pub const FIELD_VALUE_MAX: usize = 1024;
/// Longest an embed's footer text may be.
pub const FOOTER_MAX: usize = 2048;
/// Longest an embed's author name may be.
pub const AUTHOR_NAME_MAX: usize = 256;
/// The sum of every title, description, author name, footer text, and field
/// name/value across every embed on one message - Discord's own total.
pub const TOTAL_MAX: usize = 6000;

/// The caller-facing request shape for one embed. No `author.icon_url` or
/// `footer.icon_url` (see decision 0030's `avatar_url`); unrecognised
/// fields are accepted and discarded, not refused.
#[derive(Deserialize, Default)]
pub(crate) struct RawEmbed {
    #[serde(default)]
    pub(crate) title: Option<String>,
    #[serde(default)]
    pub(crate) description: Option<String>,
    #[serde(default)]
    pub(crate) url: Option<String>,
    #[serde(default)]
    pub(crate) color: Option<i64>,
    #[serde(default)]
    pub(crate) author: Option<RawEmbedAuthor>,
    #[serde(default)]
    pub(crate) fields: Vec<RawEmbedField>,
    #[serde(default)]
    pub(crate) footer: Option<RawEmbedFooter>,
    #[serde(default)]
    pub(crate) timestamp: Option<i64>,
    #[serde(default)]
    pub(crate) image: Option<RawEmbedMedia>,
    #[serde(default)]
    pub(crate) thumbnail: Option<RawEmbedMedia>,
}

#[derive(Deserialize)]
pub(crate) struct RawEmbedAuthor {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) url: Option<String>,
}

#[derive(Deserialize)]
pub(crate) struct RawEmbedFooter {
    pub(crate) text: String,
}

#[derive(Deserialize)]
pub(crate) struct RawEmbedMedia {
    pub(crate) url: String,
}

#[derive(Deserialize)]
pub(crate) struct RawEmbedField {
    pub(crate) name: String,
    pub(crate) value: String,
    #[serde(default)]
    pub(crate) inline: bool,
}

/// `value`'s length, or a 400 naming how far over `max` it is.
fn check_len(value: &str, max: usize, label: &str) -> Result<usize, ApiError> {
    let len = value.chars().count();
    if len > max {
        return Err(ApiError::BadRequestDetail(format!(
            "{label} is {} characters over the {max}-character limit",
            len - max,
        )));
    }
    Ok(len)
}

/// Refuses a heading-like field that carries a hidden character: these are
/// read as a name or a title, the places a text-direction override spoofs.
fn check_visible(value: &str, label: &str) -> Result<(), ApiError> {
    if value
        .chars()
        .any(super::super::hidden_chars::is_hidden_char)
    {
        return Err(ApiError::BadRequestDetail(format!(
            "{label} must not contain control or invisible characters"
        )));
    }
    Ok(())
}

/// Trims `value`, treats blank as absent, and caps it at `max`.
fn optional_text(
    value: Option<String>,
    max: usize,
    label: &str,
) -> Result<(Option<String>, usize), ApiError> {
    let Some(value) = value else {
        return Ok((None, 0));
    };
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok((None, 0));
    }
    let len = check_len(trimmed, max, label)?;
    Ok((Some(trimmed.to_owned()), len))
}

/// A clickable link, held to the same rules as a link button's.
fn link(raw: &str, label: &str) -> Result<String, ApiError> {
    crate::components::checked_link(raw, super::super::hidden_chars::is_hidden_char).map_err(|_| {
        ApiError::BadRequestDetail(format!(
            "{label} must be an http or https link with a host, at most {} characters",
            crate::components::MAX_URL_CHARS
        ))
    })
}

/// [`optional_text`] for a single-line field.
fn optional_heading(
    value: Option<String>,
    max: usize,
    label: &str,
) -> Result<(Option<String>, usize), ApiError> {
    if let Some(text) = &value {
        check_visible(text, label)?;
    }
    optional_text(value, max, label)
}

/// Validates and caps a send or delivery's `embeds`. A text cap 400s; an
/// image/thumbnail URL the guard refuses is dropped instead.
pub(crate) fn build_embeds(
    raw: Vec<RawEmbed>,
    link_previews: &LinkPreviews,
) -> Result<Vec<NewEmbed>, ApiError> {
    if raw.len() > MAX_EMBEDS_PER_MESSAGE {
        return Err(ApiError::BadRequestDetail(format!(
            "{} embeds is {} over the {MAX_EMBEDS_PER_MESSAGE}-embed limit",
            raw.len(),
            raw.len() - MAX_EMBEDS_PER_MESSAGE,
        )));
    }

    let mut total = 0usize;
    let mut built = Vec::with_capacity(raw.len());
    for embed in raw {
        let (title, len) = optional_heading(embed.title, TITLE_MAX, "an embed title")?;
        total += len;
        let (description, len) =
            optional_text(embed.description, DESCRIPTION_MAX, "an embed description")?;
        total += len;
        let (author_name, author_url) = match embed.author {
            Some(author) => {
                let (name, len) =
                    optional_heading(Some(author.name), AUTHOR_NAME_MAX, "an embed author name")?;
                total += len;
                let url = author
                    .url
                    .map(|raw| link(&raw, "an embed author url"))
                    .transpose()?;
                (name, url)
            }
            None => (None, None),
        };
        let (footer_text, len) = match embed.footer {
            Some(footer) => optional_heading(Some(footer.text), FOOTER_MAX, "an embed footer")?,
            None => (None, 0),
        };
        total += len;

        if embed.fields.len() > FIELDS_MAX {
            return Err(ApiError::BadRequestDetail(format!(
                "{} fields is {} over the {FIELDS_MAX}-field limit",
                embed.fields.len(),
                embed.fields.len() - FIELDS_MAX,
            )));
        }
        let mut fields = Vec::with_capacity(embed.fields.len());
        for field in embed.fields {
            let name = field.name.trim();
            if name.is_empty() {
                return Err(ApiError::BadRequest(
                    "an embed field name must not be empty",
                ));
            }
            check_visible(name, "an embed field name")?;
            let value = field.value.trim();
            if value.is_empty() {
                return Err(ApiError::BadRequest(
                    "an embed field value must not be empty",
                ));
            }
            total += check_len(name, FIELD_NAME_MAX, "an embed field name")?;
            total += check_len(value, FIELD_VALUE_MAX, "an embed field value")?;
            fields.push(NewEmbedField {
                name: name.to_owned(),
                value: value.to_owned(),
                inline: field.inline,
            });
        }

        if total > TOTAL_MAX {
            return Err(ApiError::BadRequestDetail(format!(
                "the embeds on this message are {} characters over the {TOTAL_MAX}-character total limit",
                total - TOTAL_MAX,
            )));
        }

        // Out of range is dropped rather than refused; a decorative field must never block the message.
        let color = embed.color.filter(|c| (0..=0xFF_FFFF).contains(c));
        let image_url = embed
            .image
            .map(|m| m.url)
            .filter(|url| link_previews.allows_embed_image(url));
        let thumbnail_url = embed
            .thumbnail
            .map(|m| m.url)
            .filter(|url| link_previews.allows_embed_image(url));

        built.push(NewEmbed {
            title,
            description,
            url: embed
                .url
                .map(|raw| link(&raw, "an embed url"))
                .transpose()?,
            color,
            author_name,
            author_url,
            footer_text,
            timestamp: embed.timestamp,
            image_url,
            thumbnail_url,
            fields,
        });
    }
    Ok(built)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn embed(title: &str) -> RawEmbed {
        RawEmbed {
            title: Some(title.to_owned()),
            ..RawEmbed::default()
        }
    }

    /// `ApiError` has no `Debug` impl, so `.unwrap()` cannot report it.
    fn expect_built(result: Result<Vec<NewEmbed>, ApiError>) -> Vec<NewEmbed> {
        match result {
            Ok(built) => built,
            Err(_) => panic!("expected build_embeds to succeed"),
        }
    }

    #[test]
    fn an_out_of_range_colour_is_dropped_not_refused() {
        let built = expect_built(build_embeds(
            vec![RawEmbed {
                color: Some(-1),
                ..embed("t")
            }],
            &LinkPreviews::disabled(),
        ));
        assert_eq!(built[0].color, None);
    }

    #[test]
    fn the_total_cap_counts_across_every_embed_on_the_message() {
        // Two titles, neither over TITLE_MAX alone, that together sum past TOTAL_MAX.
        let big = "x".repeat(TOTAL_MAX / 2 + 10);
        let err =
            build_embeds(vec![embed(&big), embed(&big)], &LinkPreviews::disabled()).unwrap_err();
        assert!(matches!(err, ApiError::BadRequestDetail(_)));
    }

    #[test]
    fn an_embed_image_is_dropped_when_link_previews_are_disabled() {
        let built = expect_built(build_embeds(
            vec![RawEmbed {
                image: Some(RawEmbedMedia {
                    url: "https://cdn.example.com/a.png".to_owned(),
                }),
                ..embed("t")
            }],
            &LinkPreviews::disabled(),
        ));
        assert_eq!(built[0].image_url, None);
    }
}
