// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The theme file a member publishes to the Space store (decision 0106).
//!
//! Validation lives here so the route and the tests share one definition, and
//! mirrors the client's own checks: a file that passes one must pass the other.

use std::collections::BTreeMap;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::media;

pub const FORMAT: &str = "slimm-theme";
pub const VERSION: u32 = 1;
pub const MAX_NAME_CHARS: usize = 40;
pub const MAX_PICTURE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_PICTURE_SIDE: u32 = 4096;
pub const MAX_STORE_THEMES: i64 = 50;

const BASES: &[&str] = &[
    "dark",
    "light",
    "trueBlack",
    "catppuccin",
    "softDark",
    "forest",
    "halloween",
];
const EFFECTS: &[&str] = &["halloweenWebs"];
const TOKENS: &[&str] = &[
    "surfaceSunken",
    "surfaceBase",
    "surfaceRaised",
    "borderSubtle",
    "borderStrong",
    "textPrimary",
    "textSecondary",
    "textDisabled",
    "accent",
    "accentFill",
    "accentOn",
    "accentSoft",
    "accentRing",
    "focusRing",
    "dangerText",
    "dangerBorder",
    "warnText",
    "warnSoft",
    "stripe",
];
const MAY_HAVE_ALPHA: &[&str] = &["accentRing", "warnSoft", "stripe"];
const SURFACES: [&str; 3] = ["surfaceSunken", "surfaceBase", "surfaceRaised"];

#[derive(Debug, Deserialize)]
/// The file as written, unknown keys refused.
#[serde(deny_unknown_fields)]
struct Doc {
    format: String,
    version: u32,
    name: String,
    #[serde(default)]
    author: Option<String>,
    base: String,
    brightness: String,
    tokens: BTreeMap<String, String>,
    #[serde(default)]
    backdrop: Option<Backdrop>,
}

#[derive(Debug, Deserialize)]
/// The optional backdrop of a theme.
#[serde(deny_unknown_fields)]
struct Backdrop {
    #[serde(default)]
    effect: Option<String>,
    #[serde(default)]
    picture: Option<Picture>,
}

#[derive(Debug, Deserialize)]
/// A backdrop picture and the settings of 0104.
#[serde(deny_unknown_fields)]
struct Picture {
    #[serde(default)]
    data: Option<String>,
    dim: f64,
    vignette: bool,
    blur: f64,
}

/// A document that passed every check, split into what the row stores.
#[derive(Debug)]
pub struct ValidTheme {
    pub name: String,
    /// The document without the picture bytes, with `picture.present` instead.
    pub doc: String,
    pub picture: Option<(Vec<u8>, &'static str)>,
}

pub fn validate(raw: &Value) -> Result<ValidTheme, Vec<String>> {
    let doc: Doc = serde_json::from_value(raw.clone()).map_err(|e| vec![e.to_string()])?;
    let mut problems = Vec::new();
    if doc.format != FORMAT || doc.version != VERSION {
        problems.push(format!("expected format {FORMAT} version {VERSION}"));
    }
    check_text("name", &doc.name, 1, &mut problems);
    if let Some(author) = &doc.author {
        check_text("author", author, 0, &mut problems);
    }
    if !BASES.contains(&doc.base.as_str()) {
        problems.push(format!("base must be one of {}", BASES.join(", ")));
    }
    if !matches!(doc.brightness.as_str(), "light" | "dark") {
        problems.push("brightness must be light or dark".to_owned());
    }
    let colours = parse_tokens(&doc.tokens, &mut problems);
    if problems.is_empty() {
        check_contrast(&colours, &mut problems);
    }
    let picture = check_backdrop(doc.backdrop.as_ref(), &mut problems);
    if !problems.is_empty() {
        return Err(problems);
    }
    let mut stored = raw.clone();
    if let Some(p) = stored.pointer_mut("/backdrop/picture") {
        *p = json!({
            "present": true,
            "dim": doc.backdrop.as_ref().and_then(|b| b.picture.as_ref()).map(|p| p.dim),
            "vignette": doc.backdrop.as_ref().and_then(|b| b.picture.as_ref()).map(|p| p.vignette),
            "blur": doc.backdrop.as_ref().and_then(|b| b.picture.as_ref()).map(|p| p.blur),
        });
    }
    Ok(ValidTheme {
        name: doc.name.trim().to_owned(),
        doc: stored.to_string(),
        picture,
    })
}

fn check_text(field: &str, text: &str, min: usize, problems: &mut Vec<String>) {
    let len = text.trim().chars().count();
    if len < min || len > MAX_NAME_CHARS {
        problems.push(format!(
            "{field} must be {min} to {MAX_NAME_CHARS} characters"
        ));
    }
    if text.chars().any(crate::hidden_chars::is_hidden_char) {
        problems.push(format!("{field} must not contain control characters"));
    }
}

fn parse_tokens(
    tokens: &BTreeMap<String, String>,
    problems: &mut Vec<String>,
) -> BTreeMap<String, [f64; 3]> {
    let mut colours = BTreeMap::new();
    for key in tokens.keys() {
        if !TOKENS.contains(&key.as_str()) {
            problems.push(format!("unknown token {key}"));
        }
    }
    for key in TOKENS {
        let Some(text) = tokens.get(*key) else {
            problems.push(format!("missing token {key}"));
            continue;
        };
        match parse_colour(text, MAY_HAVE_ALPHA.contains(key)) {
            Some(rgb) => {
                colours.insert((*key).to_owned(), rgb);
            }
            None => problems.push(format!("token {key} is not a valid colour")),
        }
    }
    colours
}

fn parse_colour(text: &str, alpha_ok: bool) -> Option<[f64; 3]> {
    let digits = text.strip_prefix('#')?;
    if !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let rgb = match digits.len() {
        6 => digits,
        8 if alpha_ok => &digits[2..],
        _ => return None,
    };
    let value = u32::from_str_radix(rgb, 16).ok()?;
    Some([
        f64::from((value >> 16) & 255),
        f64::from((value >> 8) & 255),
        f64::from(value & 255),
    ])
}

fn luminance(rgb: [f64; 3]) -> f64 {
    let channel = |v: f64| {
        let c = v / 255.0;
        if c <= 0.03928 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])
}

fn contrast(a: [f64; 3], b: [f64; 3]) -> f64 {
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

fn check_contrast(c: &BTreeMap<String, [f64; 3]>, problems: &mut Vec<String>) {
    let at = |k: &str| c[k];
    for surface in SURFACES {
        for (text, floor) in [
            ("textPrimary", 4.5),
            ("textSecondary", 4.5),
            ("accent", 4.5),
            ("dangerText", 4.5),
            ("warnText", 4.5),
            ("borderStrong", 3.0),
        ] {
            if contrast(at(text), at(surface)) < floor {
                problems.push(format!("{text} on {surface} is below {floor}:1"));
            }
        }
    }
    if contrast(at("accentOn"), at("accentFill")) < 4.5 {
        problems.push("accentOn on accentFill is below 4.5:1".to_owned());
    }
    if contrast(at("accent"), at("accentSoft")) < 4.5 {
        problems.push("accent on accentSoft is below 4.5:1".to_owned());
    }
    let base = at("surfaceBase");
    if contrast(at("textDisabled"), base) >= contrast(at("textSecondary"), base) {
        problems.push("textDisabled must be quieter than textSecondary".to_owned());
    }
}

fn check_backdrop(
    backdrop: Option<&Backdrop>,
    problems: &mut Vec<String>,
) -> Option<(Vec<u8>, &'static str)> {
    let backdrop = backdrop?;
    if let Some(effect) = &backdrop.effect
        && !EFFECTS.contains(&effect.as_str())
    {
        problems.push(format!("unknown backdrop effect {effect}"));
    }
    let picture = backdrop.picture.as_ref()?;
    if !(0.0..=1.0).contains(&picture.dim) || !(0.0..=1.0).contains(&picture.blur) {
        problems.push("picture dim and blur must be between 0 and 1".to_owned());
    }
    let Some(data) = picture.data.as_deref() else {
        problems.push("picture data is required".to_owned());
        return None;
    };
    let Ok(bytes) = BASE64.decode(data) else {
        problems.push("picture data must be base64".to_owned());
        return None;
    };
    if bytes.is_empty() || bytes.len() > MAX_PICTURE_BYTES {
        problems.push("picture must be 1 byte to 2 MiB".to_owned());
        return None;
    }
    match media::check_image(&bytes, media::Motion::StillOnly, MAX_PICTURE_SIDE) {
        Ok(header) => Some((bytes, header.content_type)),
        Err(_) => {
            problems
                .push("picture must be a still PNG, JPEG or WebP, at most 4096 pixels".to_owned());
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub fn sample() -> Value {
        json!({
            "format": "slimm-theme", "version": 1, "name": "Dusk", "author": "me",
            "base": "dark", "brightness": "dark",
            "tokens": {
                "surfaceSunken": "#0B0D10", "surfaceBase": "#12151A", "surfaceRaised": "#1C2027",
                "borderSubtle": "#2A2F38", "borderStrong": "#7C8696",
                "textPrimary": "#EEF1F5", "textSecondary": "#A9B2BF", "textDisabled": "#5E6672",
                "accent": "#7FB2FF", "accentFill": "#7FB2FF", "accentOn": "#06101F",
                "accentSoft": "#1B2A44", "accentRing": "#407FB2FF", "focusRing": "#7FB2FF",
                "dangerText": "#F0958A", "dangerBorder": "#D0675B",
                "warnText": "#E0B050", "warnSoft": "#1AE0B050", "stripe": "#12A9B2BF"
            }
        })
    }

    #[test]
    fn every_built_in_preset_exported_by_the_client_validates() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/space_themes");
        let mut seen = 0;
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let doc: Value =
                serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            if let Err(problems) = validate(&doc) {
                panic!("{}: {problems:?}", path.display());
            }
            seen += 1;
        }
        assert_eq!(seen, 7);
    }

    #[test]
    fn a_complete_file_validates_and_keeps_its_name() {
        let ok = validate(&sample()).unwrap();
        assert_eq!(ok.name, "Dusk");
        assert!(ok.picture.is_none());
    }

    #[test]
    fn missing_unknown_and_malformed_tokens_are_each_named() {
        let mut doc = sample();
        doc["tokens"].as_object_mut().unwrap().remove("accent");
        doc["tokens"]["bogus"] = json!("#000000");
        doc["tokens"]["surfaceBase"] = json!("red");
        let problems = validate(&doc).unwrap_err().join("|");
        assert!(problems.contains("missing token accent"));
        assert!(problems.contains("unknown token bogus"));
        assert!(problems.contains("surfaceBase is not a valid colour"));
    }

    #[test]
    fn low_contrast_text_is_refused_with_the_pair() {
        let mut doc = sample();
        doc["tokens"]["textPrimary"] = json!("#1C2027");
        let problems = validate(&doc).unwrap_err().join("|");
        assert!(problems.contains("textPrimary on surfaceBase is below 4.5:1"));
    }

    #[test]
    fn alpha_is_only_allowed_on_the_translucent_tokens() {
        let mut doc = sample();
        doc["tokens"]["accent"] = json!("#807FB2FF");
        assert!(validate(&doc).is_err());
    }

    #[test]
    fn unknown_keys_a_wrong_format_and_an_empty_name_are_refused() {
        let mut doc = sample();
        doc["extra"] = json!(1);
        assert!(validate(&doc).is_err());
        let mut doc = sample();
        doc["format"] = json!("other");
        doc["name"] = json!("  ");
        let problems = validate(&doc).unwrap_err().join("|");
        assert!(problems.contains("expected format"));
        assert!(problems.contains("name must be"));
    }

    #[test]
    fn a_picture_must_be_a_real_still_image() {
        let mut doc = sample();
        doc["backdrop"] = json!({"picture": {"data": BASE64.encode(b"not an image"),
            "dim": 0.5, "vignette": true, "blur": 0.0}});
        assert!(validate(&doc).unwrap_err().join("|").contains("still PNG"));
    }

    #[test]
    fn an_effect_must_be_known() {
        let mut doc = sample();
        doc["backdrop"] = json!({"effect": "snow"});
        assert!(validate(&doc).is_err());
        doc["backdrop"] = json!({"effect": "halloweenWebs"});
        assert!(validate(&doc).is_ok());
    }
}
