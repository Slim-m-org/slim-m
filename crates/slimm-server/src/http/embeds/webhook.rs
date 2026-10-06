// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The webhook route's embed: Discord's shape, read tolerantly. A value of
//! the wrong type on a decorative field degrades instead of refusing the
//! delivery. See decision 0030's "acceptance, not fidelity".

use serde::{Deserialize, Deserializer};

use super::build::{RawEmbed, RawEmbedAuthor, RawEmbedField, RawEmbedFooter, RawEmbedMedia};
use super::rfc3339;

/// A webhook caller's embed; [`RawEmbed`] stays strict for this repo's own clients.
#[derive(Deserialize)]
pub(crate) struct WebhookEmbed {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    color: Option<i64>,
    #[serde(default)]
    author: Option<RawEmbedAuthor>,
    #[serde(default, deserialize_with = "null_as_empty")]
    fields: Vec<RawEmbedField>,
    #[serde(default)]
    footer: Option<RawEmbedFooter>,
    #[serde(default, deserialize_with = "tolerant_timestamp")]
    timestamp: Option<i64>,
    #[serde(default)]
    image: Option<RawEmbedMedia>,
    #[serde(default)]
    thumbnail: Option<RawEmbedMedia>,
}

impl From<WebhookEmbed> for RawEmbed {
    fn from(embed: WebhookEmbed) -> Self {
        RawEmbed {
            title: embed.title,
            description: embed.description,
            url: embed.url,
            color: embed.color,
            author: embed.author,
            fields: embed.fields,
            footer: embed.footer,
            timestamp: embed.timestamp,
            image: embed.image,
            thumbnail: embed.thumbnail,
        }
    }
}

/// A JSON `null` where a list belongs reads as an empty one.
pub(crate) fn null_as_empty<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(deserializer)?.unwrap_or_default())
}

#[derive(Deserialize)]
/// What a sender's `timestamp` may be on the wire; only the first two are kept.
#[serde(untagged)]
enum WireTimestamp {
    Millis(i64),
    Text(String),
    Unreadable(serde::de::IgnoredAny),
}

/// Epoch milliseconds from an integer or an RFC 3339 string; anything else is dropped.
fn tolerant_timestamp<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<i64>, D::Error> {
    Ok(match Option::<WireTimestamp>::deserialize(deserializer)? {
        Some(WireTimestamp::Millis(ms)) => Some(ms),
        Some(WireTimestamp::Text(text)) => rfc3339::parse_ms(&text),
        Some(WireTimestamp::Unreadable(_)) | None => None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn timestamp_of(value: serde_json::Value) -> Option<i64> {
        let embed: WebhookEmbed = serde_json::from_value(json!({ "timestamp": value })).unwrap();
        embed.timestamp
    }

    #[test]
    fn an_integer_is_epoch_milliseconds_as_before() {
        assert_eq!(
            timestamp_of(json!(1_791_115_200_000_i64)),
            Some(1_791_115_200_000)
        );
    }

    #[test]
    fn an_iso_string_is_converted() {
        assert_eq!(
            timestamp_of(json!("2026-10-04T12:00:00.000Z")),
            Some(1_791_115_200_000)
        );
    }

    #[test]
    fn null_an_unparseable_string_and_other_types_are_dropped() {
        for value in [
            json!(null),
            json!("yesterday"),
            json!(1.5),
            json!(true),
            json!({ "at": 1 }),
            json!([1]),
            json!(u64::MAX),
        ] {
            assert_eq!(timestamp_of(value.clone()), None, "{value}");
        }
    }

    #[test]
    fn a_missing_timestamp_and_null_fields_are_fine() {
        let embed: WebhookEmbed =
            serde_json::from_value(json!({ "title": "t", "fields": null })).unwrap();
        let raw = RawEmbed::from(embed);
        assert_eq!(raw.timestamp, None);
        assert!(raw.fields.is_empty());
    }
}
