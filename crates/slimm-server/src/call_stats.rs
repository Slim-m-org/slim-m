// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Talk statistics worked out from one member's own transcript lines (decision 0113).
//! The tally holds only counters: it never keeps a line's text, and it knows no other member.

use std::collections::{BTreeMap, HashSet};

use jiff::civil::Date;
use jiff::tz::TimeZone;
use jiff::{SignedDuration, Timestamp};

const DAY_MS: i64 = 86_400_000;
const MINUTE_MS: i64 = 60_000;
/// Talk time under which a pace says nothing.
const PACE_MIN_MS: i64 = MINUTE_MS;
/// A language below both of these goes into "other".
const OWN_LANGUAGE_SHARE: f64 = 0.05;
const OWN_LANGUAGE_MS: i64 = 2 * MINUTE_MS;
/// A window up to this long is bucketed by day, a longer one by week.
pub const DAY_BUCKET_LIMIT_DAYS: i64 = 92;
pub const OTHER: &str = "other";

/// Languages written without spaces between words, counted by character.
const CHARACTER_LANGUAGES: [&str; 8] = ["zh", "yue", "ja", "th", "lo", "km", "my", "bo"];
const FILLER_WORDS: [&str; 7] = [
    "um",
    "uh",
    "er",
    "hmm",
    "basically",
    "literally",
    "actually",
];
/// Fillers only when the transcriber sets them off with commas.
const FILLER_PHRASES: [&str; 3] = ["like", "you know", "i mean"];

/// One counted line: only what the numbers need.
pub struct StatLine<'a> {
    pub transcript: [u8; 16],
    pub at: i64,
    pub end_at: i64,
    pub language: Option<&'a str>,
    pub text: &'a str,
}

#[derive(Default)]
struct Language {
    talk_ms: i64,
    units: i64,
}

#[derive(Default)]
struct Day {
    talk_ms: i64,
    words: i64,
}

pub struct Tally {
    zone: TimeZone,
    since: Option<i64>,
    calls: HashSet<[u8; 16]>,
    talk_ms: i64,
    words: i64,
    characters: i64,
    word_talk_ms: i64,
    english_words: i64,
    fillers: BTreeMap<&'static str, i64>,
    languages: BTreeMap<String, Language>,
    days: BTreeMap<Date, Day>,
    /// The civil day last looked up as `[start, end)` in ms, since lines arrive in runs.
    day_span: Option<(i64, i64, Date)>,
}

#[derive(Debug, PartialEq)]
pub struct LanguageStat {
    pub code: String,
    pub talk_ms: i64,
    pub share: f64,
    pub pace: Option<f64>,
    pub unit: &'static str,
}

#[derive(Debug, PartialEq)]
pub struct FillerStats {
    pub total: i64,
    pub per_100_words: f64,
    pub phrases: Vec<(&'static str, i64)>,
}

#[derive(Debug, PartialEq)]
pub struct Bucket {
    pub date: String,
    pub talk_ms: i64,
    pub words: i64,
}

#[derive(Debug, PartialEq)]
pub struct Stats {
    pub since: Option<i64>,
    pub calls: i64,
    pub talk_ms: i64,
    pub words: i64,
    pub characters: i64,
    pub words_per_minute: Option<f64>,
    pub fillers: Option<FillerStats>,
    pub languages: Vec<LanguageStat>,
    pub weekly: bool,
    pub buckets: Vec<Bucket>,
}

impl Tally {
    pub fn new(zone: TimeZone) -> Self {
        Self {
            zone,
            since: None,
            calls: HashSet::new(),
            talk_ms: 0,
            words: 0,
            characters: 0,
            word_talk_ms: 0,
            english_words: 0,
            fillers: BTreeMap::new(),
            languages: BTreeMap::new(),
            days: BTreeMap::new(),
            day_span: None,
        }
    }

    pub fn add(&mut self, line: &StatLine<'_>) {
        let talk_ms = (line.end_at - line.at).max(0);
        let code = line
            .language
            .map(str::to_ascii_lowercase)
            .unwrap_or_default();
        let by_character = CHARACTER_LANGUAGES.contains(&code.as_str());
        let units = if by_character {
            count_characters(line.text)
        } else {
            count_words(line.text)
        };
        self.since = Some(self.since.map_or(line.at, |s| s.min(line.at)));
        self.calls.insert(line.transcript);
        self.talk_ms += talk_ms;
        let date = self.local_date(line.at);
        let day = self.days.entry(date).or_default();
        day.talk_ms += talk_ms;
        if by_character {
            self.characters += units;
        } else {
            self.words += units;
            self.word_talk_ms += talk_ms;
            day.words += units;
        }
        if code == "en" {
            self.english_words += units;
            self.count_fillers(line.text);
        }
        let language = self.languages.entry(code).or_default();
        language.talk_ms += talk_ms;
        language.units += units;
    }

    pub fn first_line_at(&self) -> Option<i64> {
        self.since
    }

    fn local_date(&mut self, at: i64) -> Date {
        if let Some((start, end, date)) = self.day_span
            && (start..end).contains(&at)
        {
            return date;
        }
        let stamp = Timestamp::from_millisecond(at).unwrap_or(Timestamp::UNIX_EPOCH);
        let zoned = stamp.to_zoned(self.zone.clone());
        let date = zoned.date();
        let span = zoned.start_of_day().ok().and_then(|start| {
            let next = start.checked_add(SignedDuration::from_hours(36)).ok()?;
            let end = next.start_of_day().ok()?;
            Some((
                start.timestamp().as_millisecond(),
                end.timestamp().as_millisecond(),
            ))
        });
        self.day_span = span.map(|(start, end)| (start, end, date));
        date
    }

    fn count_fillers(&mut self, text: &str) {
        let lowered = text.to_lowercase().replace(['\u{2019}', '\u{2018}'], "'");
        for word in words_of(&lowered) {
            if let Some(found) = FILLER_WORDS.iter().find(|f| **f == word) {
                *self.fillers.entry(found).or_default() += 1;
            }
        }
        for segment in lowered.split(',') {
            let phrase = words_of(segment).collect::<Vec<_>>().join(" ");
            if let Some(found) = FILLER_PHRASES.iter().find(|f| **f == phrase)
                && lowered.contains(',')
            {
                *self.fillers.entry(found).or_default() += 1;
            }
        }
    }

    /// `weekly` buckets by the Monday of each week instead of by day.
    pub fn finish(self, weekly: bool) -> Stats {
        let fillers = self.fillers_stats();
        let languages = self.language_stats();
        let buckets = self.buckets(weekly);
        Stats {
            since: self.since,
            calls: i64::try_from(self.calls.len()).unwrap_or(i64::MAX),
            talk_ms: self.talk_ms,
            words: self.words,
            characters: self.characters,
            words_per_minute: pace(self.words, self.word_talk_ms),
            fillers,
            languages,
            weekly,
            buckets,
        }
    }

    fn fillers_stats(&self) -> Option<FillerStats> {
        if self.english_words == 0 {
            return None;
        }
        let total: i64 = self.fillers.values().sum();
        let mut phrases: Vec<_> = self.fillers.iter().map(|(p, n)| (*p, *n)).collect();
        phrases.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
        Some(FillerStats {
            total,
            per_100_words: round1(total as f64 * 100.0 / self.english_words as f64),
            phrases,
        })
    }

    fn language_stats(&self) -> Vec<LanguageStat> {
        let mut own = Vec::new();
        let mut other = Language::default();
        for (code, lang) in &self.languages {
            let share = lang.talk_ms as f64 / self.talk_ms.max(1) as f64;
            if code.is_empty() || share < OWN_LANGUAGE_SHARE || lang.talk_ms < OWN_LANGUAGE_MS {
                other.talk_ms += lang.talk_ms;
                other.units += lang.units;
            } else {
                own.push(language_stat(code, lang, self.talk_ms));
            }
        }
        own.sort_by(|a, b| b.talk_ms.cmp(&a.talk_ms).then(a.code.cmp(&b.code)));
        if other.talk_ms > 0 {
            let mut row = language_stat(OTHER, &other, self.talk_ms);
            row.pace = None;
            own.push(row);
        }
        own
    }

    fn buckets(&self, weekly: bool) -> Vec<Bucket> {
        let mut merged: BTreeMap<Date, Day> = BTreeMap::new();
        for (date, day) in &self.days {
            let key = if weekly { monday_of(*date) } else { *date };
            let slot = merged.entry(key).or_default();
            slot.talk_ms += day.talk_ms;
            slot.words += day.words;
        }
        let (Some(first), Some(last)) =
            (merged.keys().next().copied(), merged.keys().last().copied())
        else {
            return Vec::new();
        };
        let step = if weekly { 7 } else { 1 };
        let mut out = Vec::new();
        let mut date = first;
        while date <= last {
            let day = merged.get(&date);
            out.push(Bucket {
                date: date.to_string(),
                talk_ms: day.map_or(0, |d| d.talk_ms),
                words: day.map_or(0, |d| d.words),
            });
            date = date.saturating_add(SignedDuration::from_hours(24 * step));
        }
        out
    }
}

fn language_stat(code: &str, lang: &Language, total_ms: i64) -> LanguageStat {
    let by_character = CHARACTER_LANGUAGES.contains(&code);
    LanguageStat {
        code: code.to_owned(),
        talk_ms: lang.talk_ms,
        share: round3(lang.talk_ms as f64 / total_ms.max(1) as f64),
        pace: pace(lang.units, lang.talk_ms),
        unit: if by_character { "characters" } else { "words" },
    }
}

fn pace(units: i64, talk_ms: i64) -> Option<f64> {
    (talk_ms >= PACE_MIN_MS).then(|| round1(units as f64 * MINUTE_MS as f64 / talk_ms as f64))
}

fn monday_of(date: Date) -> Date {
    let back = i64::from(date.weekday().to_monday_zero_offset());
    date.saturating_sub(SignedDuration::from_hours(24 * back))
}

/// The window's start in ms for `days`, or `None` for everything still kept.
pub fn window_start(now: i64, days: Option<i64>) -> Option<i64> {
    days.map(|d| now - d * DAY_MS)
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

/// Runs of letters and digits, joined across an inner apostrophe or hyphen.
fn words_of(text: &str) -> impl Iterator<Item = &str> {
    text.split(|c: char| !(c.is_alphanumeric() || c == '\'' || c == '-' || c == '\u{2019}'))
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()))
        .filter(|w| !w.is_empty())
}

pub fn count_words(text: &str) -> i64 {
    i64::try_from(words_of(text).count()).unwrap_or(i64::MAX)
}

pub fn count_characters(text: &str) -> i64 {
    i64::try_from(text.chars().filter(|c| c.is_alphanumeric()).count()).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests;
