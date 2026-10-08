// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one classifier for characters that change what a reader sees without
//! changing what the text does (trojan source, CVE-2021-42574).

/// True for a character that changes or hides what a reader sees: a control,
/// a text-direction mark, or one that draws nothing at all. `pub(crate)` so
/// names, status lines, presence, labels, code runs and module manifests all
/// refuse the same set: there were three lists, and they disagreed.
///
/// The blank ones are here because a label made only of U+3164 or U+2800
/// passed the direction-only list and rendered as an empty button. U+FE0F is
/// deliberately absent: it is what makes a heart an emoji.
pub(crate) fn is_hidden_char(c: char) -> bool {
    c.is_control()
        || matches!(c,
            '\u{00AD}'                 // soft hyphen
            | '\u{034F}'               // combining grapheme joiner
            | '\u{061C}'               // Arabic letter mark
            | '\u{115F}'..='\u{1160}'  // hangul choseong and jungseong fillers
            | '\u{17B4}'..='\u{17B5}'  // khmer inherent vowels, drawn as nothing
            | '\u{180E}'               // mongolian vowel separator
            | '\u{200B}'..='\u{200F}'  // zero-width space and joiners, LRM, RLM
            | '\u{2028}'..='\u{2029}'  // line and paragraph separators
            | '\u{202A}'..='\u{202E}'  // bidi embeddings and overrides
            | '\u{2060}'..='\u{206F}'  // word joiner, invisible operators, bidi isolates
            | '\u{2800}'               // braille blank
            | '\u{3164}'               // hangul filler
            | '\u{FEFF}'               // zero-width no-break space / BOM
            | '\u{FFA0}'               // halfwidth hangul filler
            | '\u{FFF9}'..='\u{FFFC}'  // interlinear annotation, object replacement
            | '\u{E0000}'..='\u{E007F}' // tag characters
        )
}

const ZWJ: char = '\u{200D}';
const TAG_FLAG_BASE: char = '\u{1F3F4}';
const TAG_END: char = '\u{E007F}';

fn is_tag_letter(c: char) -> bool {
    matches!(c, '\u{E0020}'..='\u{E007E}')
}

fn is_pictographic(c: char) -> bool {
    matches!(c,
        '\u{00A9}' | '\u{00AE}' | '\u{203C}' | '\u{2049}' | '\u{2122}' | '\u{2139}'
        | '\u{2190}'..='\u{21FF}'
        | '\u{2300}'..='\u{23FF}'
        | '\u{24C2}'
        | '\u{25A0}'..='\u{27BF}'
        | '\u{2900}'..='\u{297F}'
        | '\u{2B00}'..='\u{2BFF}'
        | '\u{3030}' | '\u{303D}' | '\u{3297}' | '\u{3299}'
        | '\u{1F000}'..='\u{1FAFF}')
}

/// True when `text` holds a hidden character that is not part of an emoji
/// sequence. A zero width joiner is allowed only between two emoji, and tag
/// characters only as the subdivision flag `U+1F3F4 tags... U+E007F`, so a
/// poll can carry a family or a Scottish flag while a bare joiner still fails.
pub(crate) fn hides_text_outside_emoji(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == ZWJ {
            let after_emoji =
                i > 0 && (is_pictographic(chars[i - 1]) || chars[i - 1] == '\u{FE0F}');
            let before_emoji = chars.get(i + 1).is_some_and(|n| is_pictographic(*n));
            if !(after_emoji && before_emoji) {
                return true;
            }
        } else if c == TAG_FLAG_BASE {
            let tags = chars[i + 1..]
                .iter()
                .take_while(|t| is_tag_letter(**t))
                .count();
            let closed = chars.get(i + 1 + tags) == Some(&TAG_END);
            if tags > 0 && closed {
                i += tags + 2;
                continue;
            }
        } else if is_hidden_char(c) {
            return true;
        }
        i += 1;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::{hides_text_outside_emoji, is_hidden_char};

    #[test]
    fn hidden_characters_are_told_apart_from_ordinary_text() {
        for hidden in [
            '\u{202E}',
            '\u{200B}',
            '\u{061C}',
            '\u{0}',
            '\u{2066}',
            '\u{2060}',
            '\u{FEFF}',
            '\u{3164}',
            '\u{2800}',
            '\u{2062}',
            '\u{FFA0}',
            '\u{FFFC}',
            '\u{00AD}',
            '\u{034F}',
            '\u{115F}',
            '\u{180E}',
            '\u{206A}',
            '\u{2028}',
            '\u{E0041}',
        ] {
            assert!(is_hidden_char(hidden), "{hidden:?}");
        }
        // U+FE0F and the heart it follows are ordinary text: an emoji must stay typable.
        for plain in [
            'a',
            ' ',
            '\u{e9}',
            '\u{4e2d}',
            '\u{FE0F}',
            '\u{2764}',
            '\u{1F600}',
        ] {
            assert!(!is_hidden_char(plain), "{plain:?}");
        }
    }

    #[test]
    fn joiners_and_tags_pass_only_inside_emoji_sequences() {
        for ok in [
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}",
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E007F} flag",
            "plain text",
        ] {
            assert!(!hides_text_outside_emoji(ok), "{ok:?}");
        }
        for bad in [
            "a\u{200D}b",
            "\u{200D}",
            "\u{1F468}\u{200D}",
            "\u{1F3F4}\u{E0067}",
            "\u{E0067}\u{E007F}",
            "\u{1F468}\u{200B}",
            "\u{202E}",
        ] {
            assert!(hides_text_outside_emoji(bad), "{bad:?}");
        }
    }

    /// Every code point, against the ranges `hidden_chars.json` lists. The
    /// Dart test (`code_hidden_characters_test.dart`) sweeps the same file, so
    /// the two classifiers cannot disagree about any character.
    #[test]
    fn the_shared_fixture_lists_exactly_the_hidden_characters() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/hidden_chars.json")).unwrap();
        let hex = |v: &serde_json::Value| u32::from_str_radix(v.as_str().unwrap(), 16).unwrap();
        let ranges: Vec<(u32, u32)> = fixture["hidden"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| (hex(&r["from"]), hex(&r["to"])))
            .collect();
        for code in 0..=0x10FFFFu32 {
            let Some(c) = char::from_u32(code) else {
                continue;
            };
            let listed = ranges
                .iter()
                .any(|(from, to)| (*from..=*to).contains(&code));
            assert_eq!(is_hidden_char(c), listed, "U+{code:04X}");
        }
        for plain in fixture["plain"].as_array().unwrap() {
            assert!(!is_hidden_char(char::from_u32(hex(plain)).unwrap()));
        }
    }
}
