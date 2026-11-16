// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the reactions route accepts as an "emoji".
//!
//! A reaction is stored as the text the client sent, and a client sends one of
//! three things: one emoji grapheme, the `:shortcode:` of a custom emoji (the
//! chip resolves it at draw time, so a deleted emoji keeps its reactions), or a
//! custom emoji's id. Anything else is a sentence under somebody's message.

/// Longer than a custom emoji's name may be: the standard set runs to 67.
const MAX_SHORTCODE_LEN: usize = 80;

/// Which of the three accepted forms a string is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ReactionEmoji<'a> {
    /// One emoji grapheme, as sent.
    Single(&'a str),
    /// The name between a `:shortcode:`'s colons.
    Shortcode(&'a str),
    /// A custom emoji's id.
    Id(uuid::Uuid),
}

/// True when `text` is a single emoji, a `:shortcode:` or an emoji id.
pub(super) fn is_reaction(text: &str) -> bool {
    parse(text).is_some()
}

/// Reads `text` as one of the forms [`is_reaction`] accepts.
///
/// A shortcode may hold `+` and `-` as well as what a custom emoji name may:
/// bots send the standard ones, and `:+1:`, `:t-rex:` and `:piñata:` are among them.
pub(super) fn parse(text: &str) -> Option<ReactionEmoji<'_>> {
    if let Some(name) = shortcode_name(text) {
        return Some(ReactionEmoji::Shortcode(name));
    }
    if let Ok(id) = uuid::Uuid::parse_str(text) {
        return Some(ReactionEmoji::Id(id));
    }
    is_single_emoji(text).then_some(ReactionEmoji::Single(text))
}

fn shortcode_name(text: &str) -> Option<&str> {
    let name = text.strip_prefix(':')?.strip_suffix(':')?;
    let usable = !name.is_empty()
        && name.len() <= MAX_SHORTCODE_LEN
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '+' | '-'));
    usable.then_some(name)
}

fn is_single_emoji(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    cluster_len(&chars) == Some(chars.len())
}

/// How many leading characters form one emoji cluster, if any do.
fn cluster_len(chars: &[char]) -> Option<usize> {
    keycap_len(chars)
        .or_else(|| flag_len(chars))
        .or_else(|| tag_flag_len(chars))
        .or_else(|| zwj_sequence_len(chars))
}

const VARIATION_SELECTOR_16: char = '\u{FE0F}';
const ZERO_WIDTH_JOINER: char = '\u{200D}';

fn keycap_len(chars: &[char]) -> Option<usize> {
    let [base, rest @ ..] = chars else {
        return None;
    };
    if !(base.is_ascii_digit() || matches!(base, '#' | '*')) {
        return None;
    }
    let skipped = usize::from(rest.first() == Some(&VARIATION_SELECTOR_16));
    (rest.get(skipped) == Some(&'\u{20E3}')).then_some(skipped + 2)
}

fn flag_len(chars: &[char]) -> Option<usize> {
    let regional = |c: &char| ('\u{1F1E6}'..='\u{1F1FF}').contains(c);
    (chars.len() >= 2 && regional(&chars[0]) && regional(&chars[1])).then_some(2)
}

fn tag_flag_len(chars: &[char]) -> Option<usize> {
    if chars.first() != Some(&'\u{1F3F4}') {
        return None;
    }
    let tags = chars[1..]
        .iter()
        .take_while(|c| ('\u{E0020}'..='\u{E007E}').contains(*c))
        .count();
    (tags > 0 && chars.get(1 + tags) == Some(&'\u{E007F}')).then_some(tags + 2)
}

fn zwj_sequence_len(chars: &[char]) -> Option<usize> {
    let mut used = element_len(chars)?;
    while chars.get(used) == Some(&ZERO_WIDTH_JOINER) {
        match element_len(&chars[used + 1..]) {
            Some(next) => used += 1 + next,
            None => break,
        }
    }
    Some(used)
}

/// One pictograph with its optional skin tone and presentation selector.
fn element_len(chars: &[char]) -> Option<usize> {
    if !is_pictographic(*chars.first()?) {
        return None;
    }
    let mut used = 1;
    if chars
        .get(used)
        .is_some_and(|c| ('\u{1F3FB}'..='\u{1F3FF}').contains(c))
    {
        used += 1;
    }
    if chars.get(used) == Some(&VARIATION_SELECTOR_16) {
        used += 1;
    }
    Some(used)
}

/// A coarse reading of Extended_Pictographic: the blocks emoji are drawn from,
/// without the 1F3FB..1F3FF skin tones, which only ever follow a pictograph.
fn is_pictographic(c: char) -> bool {
    matches!(c,
        '\u{00A9}' | '\u{00AE}' | '\u{203C}' | '\u{2049}' | '\u{2122}' | '\u{2139}'
        | '\u{2194}'..='\u{21AA}'
        | '\u{231A}'..='\u{23FA}'
        | '\u{24C2}'
        | '\u{25AA}'..='\u{25FE}'
        | '\u{2600}'..='\u{27BF}'
        | '\u{2934}'..='\u{2935}'
        | '\u{2B05}'..='\u{2B55}'
        | '\u{3030}' | '\u{303D}' | '\u{3297}' | '\u{3299}'
        | '\u{1F000}'..='\u{1F3FA}'
        | '\u{1F400}'..='\u{1FAFF}'
    )
}

#[cfg(test)]
mod tests {
    use super::{ReactionEmoji, is_reaction, parse};

    #[test]
    fn each_form_reads_as_its_kind() {
        let id = "0190f1c2-7a3b-7c3e-8f00-1234567890ab";
        assert_eq!(parse("\u{1F44D}"), Some(ReactionEmoji::Single("\u{1F44D}")));
        assert_eq!(
            parse(":party_parrot:"),
            Some(ReactionEmoji::Shortcode("party_parrot"))
        );
        assert_eq!(parse(id), Some(ReactionEmoji::Id(id.parse().unwrap())));
        assert_eq!(parse("hello"), None);
    }

    #[test]
    fn single_emoji_shortcodes_and_ids_pass() {
        for ok in [
            "\u{1F44D}",
            "\u{2764}",
            "\u{2764}\u{FE0F}",
            "\u{1F44D}\u{1F3FD}",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            "\u{1F1E8}\u{1F1E6}",
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
            "#\u{FE0F}\u{20E3}",
            ":party_parrot:",
            ":+1:",
            ":-1:",
            ":t-rex:",
            "0190f1c2-7a3b-7c3e-8f00-1234567890ab",
        ] {
            assert!(is_reaction(ok), "{ok:?}");
        }
    }

    #[test]
    fn text_and_runs_of_emoji_are_refused() {
        for bad in [
            "",
            "hello world",
            "a",
            "1",
            "\u{1F44D}\u{1F44D}",
            "\u{1F44D}x",
            "\u{1F44D}\u{200D}",
            "\u{1F3FD}",
            "::",
            ":a b:",
            ":a:b:",
            "\u{202E}",
        ] {
            assert!(!is_reaction(bad), "{bad:?}");
        }
    }

    /// Every emoji and shortcode the client's picker can send. Refusing one
    /// here would mean a member cannot react with something the app offers.
    #[test]
    fn everything_the_picker_offers_is_accepted() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/fixtures/picker_emoji.json")).unwrap();
        let strings = |key: &str| -> Vec<String> {
            fixture[key]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect()
        };
        let chars = strings("chars");
        assert!(
            chars.len() > 3000,
            "the fixture holds {} emoji",
            chars.len()
        );
        let refused: Vec<_> = chars.iter().filter(|c| !is_reaction(c)).collect();
        assert!(refused.is_empty(), "{} refused: {refused:?}", refused.len());

        let refused: Vec<_> = strings("names")
            .into_iter()
            .filter(|name| !is_reaction(&format!(":{name}:")))
            .collect();
        assert!(
            refused.is_empty(),
            "{} shortcodes refused: {refused:?}",
            refused.len()
        );
    }
}
