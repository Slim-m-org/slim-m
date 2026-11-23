// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;
use crate::ids::UserId;

fn phrase() -> WakePhrase {
    WakePhrase::parse(DEFAULT_PHRASE).unwrap()
}

#[test]
fn the_phrase_then_a_verb_is_a_command() {
    let p = phrase();
    assert_eq!(parse("Hey Space, mark that.", &p), Parsed::Mark);
    assert_eq!(parse("hey space bookmark this", &p), Parsed::Mark);
    assert_eq!(parse("Hey space, clip that!", &p), Parsed::Mark);
    assert_eq!(
        parse("Okay so hey space, please mark that.", &p),
        Parsed::Mark
    );
    assert_eq!(
        parse("The build looks wrong, hey space, mark that.", &p),
        Parsed::Mark
    );
    assert_eq!(
        parse("Hey space, note call the plumber tomorrow.", &p),
        Parsed::Note("call the plumber tomorrow".into())
    );
    assert_eq!(parse("Hey spaced, mark that", &p), Parsed::Mark);
}

#[test]
fn nothing_else_is_acted_on() {
    let p = phrase();
    for line in [
        "hey, space it out a bit more",
        "that clip was really funny",
        "mark my words, it will rain",
        "we should mark that down as done",
        "hey Mark, did you see that",
        "hey Spencer, mark that",
        "hey Stacey, mark that one for me",
        "hey place, mark that",
        "hey space, note",
        "hey space, you can mark that later",
    ] {
        assert_eq!(parse(line, &p), Parsed::None, "{line}");
    }
    assert_eq!(parse("Hey space.", &p), Parsed::Wake);
    assert_eq!(parse("hey space, um", &p), Parsed::Wake);
}

#[test]
fn a_note_is_cut_to_500_characters() {
    let long = format!("hey space note {}", "word ".repeat(200));
    let Parsed::Note(text) = parse(&long, &phrase()) else {
        panic!("a note");
    };
    assert_eq!(text.chars().count(), 500);
}

#[test]
fn a_phrase_must_be_two_to_four_words_without_command_words() {
    assert!(WakePhrase::parse("hey").is_err());
    assert!(WakePhrase::parse("hey there you lovely space").is_err());
    assert!(WakePhrase::parse("hey mark").is_err());
    assert!(WakePhrase::parse("hey sp4ce").is_err());
    assert!(WakePhrase::parse(&"a ".repeat(30)).is_err());
    assert_eq!(
        WakePhrase::parse("  Hey   Orbit ").unwrap().text(),
        "hey orbit"
    );
}

#[test]
fn a_wake_arms_the_speaker_for_ten_seconds_and_a_command_cools_down() {
    let p = phrase();
    let (session, alex, sam) = (uuid::Uuid::now_v7(), UserId::generate(), UserId::generate());
    let mut ears = Listening::default();
    assert_eq!(
        ears.hear((session, alex), 0, "Hey space.", &p),
        Parsed::None
    );
    assert_eq!(
        ears.hear((session, sam), 1_000, "Mark that.", &p),
        Parsed::None,
        "only the speaker who woke it"
    );
    assert_eq!(
        ears.hear((session, alex), 2_000, "Mark that.", &p),
        Parsed::Mark
    );
    assert_eq!(
        ears.hear((session, alex), 3_000, "hey space mark that", &p),
        Parsed::None,
        "a second command inside 5 s is ignored"
    );
    assert_eq!(
        ears.hear((session, alex), 8_000, "hey space mark that", &p),
        Parsed::Mark
    );
    assert_eq!(
        ears.hear((session, alex), 20_000, "Hey space.", &p),
        Parsed::None
    );
    assert_eq!(
        ears.hear((session, alex), 31_000, "mark that", &p),
        Parsed::None,
        "the wake lapses after 10 s"
    );
}

#[derive(serde::Deserialize)]
struct Fixture {
    phrase: String,
    clips: Vec<Clip>,
}

#[derive(serde::Deserialize)]
struct Clip {
    said: String,
    heard: Vec<String>,
    expect: String,
    /// Whisper's text no longer holds the phrase, so no parser could act on it.
    #[serde(default)]
    lost: bool,
}

fn first_command(clip: &Clip, phrase: &WakePhrase) -> &'static str {
    let (session, who) = (uuid::Uuid::now_v7(), UserId::generate());
    let mut ears = Listening::default();
    for (n, line) in clip.heard.iter().enumerate() {
        let at = i64::try_from(n).unwrap() * 2_000;
        match ears.hear((session, who), at, line, phrase) {
            Parsed::Mark => return "mark",
            Parsed::Note(_) => return "note",
            Parsed::None | Parsed::Wake => {}
        }
    }
    "none"
}

/// Every line whisper heard in the measurement: no false command, and every command it heard whole.
#[test]
fn the_measured_whisper_text_parses_as_the_research_note_says() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/research/voice-command-phrase-2026-11-22-fixture.json"
    );
    let fixture: Fixture = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let phrase = WakePhrase::parse(&fixture.phrase).unwrap();
    for clip in &fixture.clips {
        let got = first_command(clip, &phrase);
        if clip.expect == "none" {
            assert_eq!(got, "none", "{:?} heard as {:?}", clip.said, clip.heard);
        } else if !clip.lost {
            assert_eq!(
                got, clip.expect,
                "{:?} heard as {:?}",
                clip.said, clip.heard
            );
        }
    }
}
