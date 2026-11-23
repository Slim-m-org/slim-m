// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

fn ms(stamp: &str) -> i64 {
    stamp.parse::<Timestamp>().unwrap().as_millisecond()
}

fn line<'a>(
    call: u8,
    at: &str,
    secs: i64,
    language: Option<&'a str>,
    text: &'a str,
) -> StatLine<'a> {
    let at = ms(at);
    StatLine {
        transcript: [call; 16],
        at,
        end_at: at + secs * 1000,
        language,
        text,
    }
}

fn tally(zone: &str, lines: &[StatLine<'_>]) -> Tally {
    let mut tally = Tally::new(TimeZone::get(zone).unwrap());
    lines.iter().for_each(|l| tally.add(l));
    tally
}

fn fixture() -> Vec<StatLine<'static>> {
    vec![
        line(
            1,
            "2026-10-24T10:00:00Z",
            10,
            Some("en"),
            "Um, I mean, it's basically a well-known thing",
        ),
        line(
            1,
            "2026-10-24T10:01:00Z",
            130,
            Some("en"),
            "You know, like, we actually did it",
        ),
        line(2, "2026-10-25T10:00:00Z", 30, Some("ja"), "こんにちは世界"),
    ]
}

#[test]
fn a_fixture_gives_hand_computed_numbers() {
    let stats = tally("UTC", &fixture()).finish(false);
    assert_eq!(stats.since, Some(ms("2026-10-24T10:00:00Z")));
    assert_eq!(stats.calls, 2);
    assert_eq!(stats.talk_ms, 170_000);
    assert_eq!((stats.words, stats.characters), (15, 7));
    assert_eq!(stats.words_per_minute, Some(6.4));
    let fillers = stats.fillers.unwrap();
    assert_eq!(fillers.total, 6);
    assert_eq!(fillers.per_100_words, 40.0);
    assert_eq!(
        fillers.phrases,
        [
            ("actually", 1),
            ("basically", 1),
            ("i mean", 1),
            ("like", 1),
            ("um", 1),
            ("you know", 1)
        ]
    );
    let codes: Vec<_> = stats
        .languages
        .iter()
        .map(|l| (l.code.as_str(), l.talk_ms, l.pace))
        .collect();
    assert_eq!(codes, [("en", 140_000, Some(6.4)), ("other", 30_000, None)]);
    assert_eq!(stats.languages[0].share, 0.824);
}

#[test]
fn a_short_stretch_of_talk_has_no_pace_and_a_japanese_line_counts_characters() {
    let one = [line(
        1,
        "2026-10-24T10:00:00Z",
        20,
        Some("ja"),
        "こんにちは世界",
    )];
    let stats = tally("UTC", &one).finish(false);
    assert_eq!(
        (stats.words, stats.characters, stats.words_per_minute),
        (0, 7, None)
    );
    assert!(
        stats.fillers.is_none(),
        "fillers are counted on English lines only"
    );
}

#[test]
fn a_filler_phrase_counts_only_when_set_off_by_commas() {
    let plain = [line(
        1,
        "2026-10-24T10:00:00Z",
        5,
        Some("en"),
        "I like it and you know it",
    )];
    assert_eq!(tally("UTC", &plain).finish(false).fillers.unwrap().total, 0);
}

#[test]
fn a_curly_apostrophe_and_a_hyphen_stay_inside_one_word() {
    assert_eq!(count_words("It\u{2019}s a well-known - thing"), 4);
}

#[test]
fn buckets_follow_the_zone_across_the_daylight_saving_change() {
    let lines = [
        line(1, "2026-10-24T22:30:00Z", 5, Some("en"), "one"),
        line(1, "2026-10-25T22:30:00Z", 5, Some("en"), "two"),
        line(1, "2026-10-25T23:30:00Z", 5, Some("en"), "three"),
    ];
    let berlin = tally("Europe/Berlin", &lines).finish(false);
    let days: Vec<_> = berlin
        .buckets
        .iter()
        .map(|b| (b.date.as_str(), b.words))
        .collect();
    assert_eq!(days, [("2026-10-25", 2), ("2026-10-26", 1)]);
    let utc = tally("UTC", &lines).finish(false);
    let days: Vec<_> = utc
        .buckets
        .iter()
        .map(|b| (b.date.as_str(), b.words))
        .collect();
    assert_eq!(days, [("2026-10-24", 1), ("2026-10-25", 2)]);
}

#[test]
fn weekly_buckets_start_on_monday_and_gaps_are_filled() {
    let lines = [
        line(1, "2026-10-24T10:00:00Z", 5, Some("en"), "one"),
        line(1, "2026-11-09T10:00:00Z", 5, Some("en"), "two three"),
    ];
    let stats = tally("UTC", &lines).finish(true);
    let weeks: Vec<_> = stats
        .buckets
        .iter()
        .map(|b| (b.date.as_str(), b.words))
        .collect();
    assert_eq!(
        weeks,
        [
            ("2026-10-19", 1),
            ("2026-10-26", 0),
            ("2026-11-02", 0),
            ("2026-11-09", 2)
        ]
    );
}

#[test]
fn nothing_counted_gives_an_empty_answer() {
    let stats = tally("UTC", &[]).finish(false);
    assert_eq!((stats.since, stats.calls, stats.talk_ms), (None, 0, 0));
    assert!(stats.buckets.is_empty() && stats.languages.is_empty() && stats.fillers.is_none());
}
