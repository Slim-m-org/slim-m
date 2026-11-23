// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Spoken marks (decision 0113, amended 2026-11-22): "hey space, mark that" and
//! "hey space, note ..." read from a transcript line the server already kept.
//! Nothing here hears audio; it reads text, and only for a Space that turned
//! voice commands on. The rules and the measurement behind them are in
//! docs/research/voice-command-phrase-2026-11-22.md.

use std::collections::HashMap;

/// The phrase a Space starts with.
pub const DEFAULT_PHRASE: &str = "hey space";
/// The longest note a command keeps, as for a typed note.
const MAX_NOTE_CHARS: usize = 500;
/// How long a line that is only the phrase waits for its command.
pub const ARM_MS: i64 = 10_000;
/// The least time between two commands from one speaker.
pub const COOLDOWN_MS: i64 = 5_000;

const FILLERS: [&str; 5] = ["please", "um", "uh", "okay", "ok"];
/// "clip" counts as a mark: it is what people say, and a mark is all this records.
const MARK_VERBS: [&str; 3] = ["mark", "bookmark", "clip"];
const RESERVED: [&str; 3] = ["mark", "note", "bookmark"];

/// What one line asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    None,
    /// Only the phrase: the speaker's next line may carry the command.
    Wake,
    Mark,
    Note(String),
}

/// A Space's wake phrase, normalised into words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WakePhrase(Vec<String>);

impl WakePhrase {
    /// The phrase, or why it cannot be one: 2 to 4 words of letters, 3 to 40
    /// characters, and none of the command words.
    pub fn parse(raw: &str) -> Result<Self, &'static str> {
        let trimmed = raw.trim();
        let chars = trimmed.chars().count();
        if !(3..=40).contains(&chars) {
            return Err("the wake phrase must be 3 to 40 characters");
        }
        if !trimmed
            .chars()
            .all(|c| c.is_alphabetic() || c == ' ' || c == '\'')
        {
            return Err("the wake phrase must be letters and spaces only");
        }
        let words = words(trimmed);
        if !(2..=4).contains(&words.len()) {
            return Err("the wake phrase must be 2 to 4 words");
        }
        if words.iter().any(|w| RESERVED.contains(&w.as_str())) {
            return Err("the wake phrase must not contain mark, note or bookmark");
        }
        Ok(Self(words))
    }

    /// The phrase as it is stored and shown.
    pub fn text(&self) -> String {
        self.0.join(" ")
    }
}

/// Lowercase words with punctuation dropped, so "Hey, Space!" reads as two words.
fn words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}

/// What whisper was measured to write for a short phrase word it misheard.
fn aliases(want: &str) -> &'static [&'static str] {
    match want {
        "hey" => &["pay", "hay"],
        _ => &[],
    }
}

/// One edit for a word of 4 or more letters, so "space" survives "spaced" but not "place".
fn close_enough(heard: &str, want: &str) -> bool {
    if heard == want || aliases(want).contains(&heard) {
        return true;
    }
    if want.chars().count() < 4 {
        return false;
    }
    edits(heard, want) <= 1
}

fn edits(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut cur = vec![i + 1];
        for (j, cb) in b.iter().enumerate() {
            cur.push(
                (prev[j + 1] + 1)
                    .min(cur[j] + 1)
                    .min(prev[j] + usize::from(ca != *cb)),
            );
        }
        prev = cur;
    }
    prev[b.len()]
}

/// The command in `rest`, the words after the phrase: one optional filler, then a verb.
fn command(rest: &[String]) -> Parsed {
    let rest = match rest.first() {
        Some(first) if FILLERS.contains(&first.as_str()) => &rest[1..],
        _ => rest,
    };
    let Some(verb) = rest.first() else {
        return Parsed::None;
    };
    if MARK_VERBS.contains(&verb.as_str()) {
        return Parsed::Mark;
    }
    if verb == "note" && rest.len() > 1 {
        return Parsed::Note(rest[1..].join(" ").chars().take(MAX_NOTE_CHARS).collect());
    }
    Parsed::None
}

/// What `text` asks for under `phrase`: the phrase's words in order anywhere in
/// the line, then the command right after it. A line holds at most one.
pub fn parse(text: &str, phrase: &WakePhrase) -> Parsed {
    let words = words(text);
    let n = phrase.0.len();
    let Some(end) = (0..(words.len() + 1).saturating_sub(n)).find(|&i| {
        phrase
            .0
            .iter()
            .enumerate()
            .all(|(k, want)| close_enough(&words[i + k], want))
    }) else {
        return Parsed::None;
    };
    let rest = &words[end + n..];
    if rest.iter().all(|w| FILLERS.contains(&w.as_str())) {
        return Parsed::Wake;
    }
    command(rest)
}

/// Per speaker: who said only the phrase and until when, and when each last gave a command.
#[derive(Debug, Default)]
pub struct Listening {
    armed: HashMap<(uuid::Uuid, crate::ids::UserId), i64>,
    last: HashMap<(uuid::Uuid, crate::ids::UserId), i64>,
}

impl Listening {
    /// The command `text` gives, said by `who` in `session` at `at`, after the phrase, an earlier wake and the cooldown.
    pub fn hear(
        &mut self,
        (session, who): (uuid::Uuid, crate::ids::UserId),
        at: i64,
        text: &str,
        phrase: &WakePhrase,
    ) -> Parsed {
        let key = (session, who);
        let parsed = match parse(text, phrase) {
            Parsed::Wake => {
                self.armed.insert(key, at + ARM_MS);
                return Parsed::None;
            }
            Parsed::None if self.armed.get(&key).is_some_and(|&until| at <= until) => {
                command(&words(text))
            }
            other => other,
        };
        if parsed == Parsed::None {
            return parsed;
        }
        self.armed.remove(&key);
        if self
            .last
            .get(&key)
            .is_some_and(|&last| at - last < COOLDOWN_MS)
        {
            return Parsed::None;
        }
        self.last.insert(key, at);
        parsed
    }

    /// Forgets wakes and cooldowns that ran out before `now`.
    pub fn prune(&mut self, now: i64) {
        self.armed.retain(|_, until| *until >= now);
        self.last.retain(|_, at| now - *at < COOLDOWN_MS);
    }
}

#[cfg(test)]
mod tests;
