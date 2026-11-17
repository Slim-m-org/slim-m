<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# How the listener hears candidate wake phrases (2026-11-16)

Nick asked for voice commands on call transcripts, such as "hey space, clip that".
No command code exists yet, so this note measures what the listener writes down when someone says each candidate phrase.
It follows the method of `call-audio-real-speech-2026-11-02.md`: piper speech, the real endpointer and the real whisper.cpp base model, at the prod defaults in `crates/slimm-listener/src/config.rs`.
Run on `b22/integration` at `4786b70d1`.

## Recommendation in short

1. Use "hey space, mark that" as the phrase.
   It was heard exactly 35 of 36 times with no babble, and 41 of 48 times when the babble condition is included.
   No other phrase did better, and it is the only one whose wake word is not a mishearing magnet.
2. Match it on whole utterances of at most 6 words, with Levenshtein distance 1 on the space-free text and a small alias table for "hey".
   That rule found 35 of 36 and fired on 0 of 192 ordinary sentences.
3. Do not use a bare "mark that" or "note that".
   They are heard well, but both are everyday English: matched anywhere in a line they fired on 12 and 14 of 192 ordinary sentences.
4. Do not use "clip" as the command word.
   It collides with soundboard clips, and whisper turned it into "flip", "click", "look at" and "put" in 5 of 36 clips.
5. Whatever the phrase, treat the line's own `start_ms` and `end_ms` as the moment of the command, not the time the line arrives.
   The line reached the server a median 3.7 s after the speaker stopped in this run, so "mark that" has to bookmark where the speech was, not where the clock is.

## What was run

- The throwaway harness fed raw 16 kHz mono audio to the real `Endpointer` in 10 ms chunks and sent each utterance it returned to the real `WhisperTranscriber`.
  Settings were the defaults: `ggml-base.bin`, greedy decoding, one thread per utterance, language auto-detected.
- This skips LiveKit and Opus, so it does not include the codec and the 48 kHz to 16 kHz resample the real path has.
  It also means each condition was run once per clip, with no overlap between speakers.
- Speech came from piper with two voices, `en_US-lessac-medium` and `en_US-ryan-medium`.
  Those are the only two voices installed here, so "several voices" is two.
- Each phrase was said at three speeds (piper length scale 0.85, 1.0 and 1.25) with two generator noise settings (0.667 and 0.9), which gives 12 distinct clips per phrase.
- Every clip was mixed into four conditions, giving 48 runs per phrase.
  - `clean`: a very quiet pink-noise floor, like a good microphone in a quiet room.
  - `noise 20 dB`: pink noise 20 dB under the speech, like a fan or a keyboard.
  - `noise 10 dB`: pink noise 10 dB under the speech, a loud room.
  - `babble`: other piper speech 10 dB under the speaker, as a television or a second person bleeding into the microphone.
- Each clip had 1 s of background before the speech and 1.5 s after, which is what lets the endpointer find the end.
- The phrases were: "hey space, mark that", "hey slim, mark that", "slim, mark that", "mark that", "note that", "hey slim, clip that", and "hey slim, bookmark that" as a second command word.
- For false positives there were 48 ordinary sentences, each in both voices and in clean and 10 dB noise, so 192 negative runs.
  Many were chosen to be near misses: "We need to mark that deadline on the calendar", "Can you note that the meeting moved to Thursday", "Did you see the clip that he posted yesterday", "Hey, space is a bit tight on this server", "Mark that as done in the tracker".
- Nothing played on any device.
  All audio was files, and the only processes started were piper and the measuring binary, and both exited on their own.

## Findings

### How often the transcript contains the phrase

"Strict" means the lower-cased transcript with punctuation removed contains the phrase's words in order, with no fuzzy matching at all.
The first four columns are out of 12 runs each.

| phrase | clean | noise 20 dB | noise 10 dB | babble | strict, no babble | best rule, no babble |
| --- | --- | --- | --- | --- | --- | --- |
| hey space, mark that | 12 | 12 | 11 | 6 | 35/36 | 35/36 |
| hey slim, mark that | 11 | 9 | 8 | 4 | 28/36 | 35/36 |
| slim, mark that | 11 | 10 | 7 | 2 | 28/36 | 34/36 |
| mark that | 12 | 12 | 10 | 5 | 34/36 | 34/36 |
| note that | 9 | 10 | 7 | 1 | 26/36 | 33/36 |
| hey slim, clip that | 12 | 12 | 7 | 8 | 31/36 | 34/36 |
| hey slim, bookmark that | 10 | 10 | 8 | 3 | 28/36 | 28/36 |

"Best rule" is the matcher described below: utterance of at most the phrase's word count plus two, Levenshtein distance 1, aliases on.
For the two "slim" prefix phrases the stem rule in the matcher section lifts "slim, mark that" from 28 to 34 of 36.

Things to read from it:

- Clean speech is not the problem.
  Every phrase except "note that" is heard exactly in at least 10 of 12 clean runs.
- Loud noise hurts the short words most.
  "hey slim, clip that" fell from 12 to 7 of 12 at 10 dB, all of it "flip" and "click".
- Babble is bad for every phrase, 1 to 8 of 12 for strict matching.
  The background speech is real words, so whisper writes down some or all of it, and the phrase is often inside a longer line that is not a command (see the whole-utterance gate below).
  A second person at only 10 dB under the speaker is a hard case, and real calls mostly give each person their own track, so this is a floor for mic bleed rather than a typical call.
- The two voices differ a lot per phrase.
  "hey slim, mark that" was heard 11 of 18 for lessac and 17 of 18 for ryan.
  "note that" was 17 of 18 for lessac and 9 of 18 for ryan.
  "hey space, mark that" was 17 and 18 of 18, the smallest gap.
  Speed mattered less: "hey space, mark that" was 12, 12 and 11 of 12 at fast, normal and slow.

### Common mis-hearings

These are the exact texts whisper returned instead of the phrase, outside babble.

- "hey space, mark that": "base base, mark that" (1 of 36).
  In babble it also became "he's space, mark that", which the aliases would catch.
- "hey slim, mark that": "he slim, mark that" (7 of 36), "hey slims, mark eaters", "hey slim, work that".
- "slim, mark that": "slim mark them" (3), "slim mark back" (2), "slim mark thett" (2), "slim markbath", and "till then, mark that".
  The wake word "slim" without "hey" in front gives whisper nothing to anchor on, and the word "that" is the one it loses.
- "mark that": "mark them" (2).
- "note that": "not that" (7), "not bad" (3), "nope that", "note them".
  "not that" is a real sentence fragment, so a fuzzy match on it has no safe margin.
- "hey slim, clip that": "flip that" (3), "click that", "look at that", "put that", "clipback".
- "hey slim, bookmark that": "bookmarked that" (5), "bookmarked app" (2), "both marked out".

The last word of a short phrase is the weak one: "that" became "them", "back", "app", "out" and "thett" for several phrases.

### Latency from the end of speech

Measured as the stream time the endpointer needed to close the utterance after the last voiced sample, plus the wall time of the whisper call, for the first utterance in each of the 252 runs without babble.

| part | p50 | p95 | max |
| --- | --- | --- | --- |
| endpointer waiting for silence | about 0.5 to 1.0 s, depending on how the phrase ends | | |
| whisper call, one thread | 3.1 s | 3.3 s | |
| speech end to a line in hand | 3.7 s | 4.7 s | 5.0 s |

By phrase, the p50 total ranged from 3.6 s ("hey slim, bookmark that") to 4.1 s ("mark that").
The earlier note measured 2.3 s p50 and 2.4 s max on the same CPU model in a container with 4 cpus.
This run shared the machine with other jobs (load average 11 to 16 on 32 threads), and whisper took about 3.1 s per utterance regardless of length because it pads every utterance to a 30 s window.
So treat 2.3 s as the idle figure and 3.7 s as what a busy host looks like; both are under the decision's 5 s target, but a command that must feel instant will not.
The whisper time did not change with the phrase.

### False positives from ordinary speech

Whisper transcribed the 192 ordinary sentences almost word for word, including "Mark that has done in the tracker" for "Mark that as done in the tracker".
That makes the matcher's gate matter more than its fuzziness.

| rule | hey space | hey slim | slim | mark that | note that | clip that |
| --- | --- | --- | --- | --- | --- | --- |
| phrase anywhere in the line, distance 1 | 0/192 | 0/192 | 0/192 | 12/192 | 14/192 | 4/192 |
| phrase anywhere in the line, distance 2 | 0/192 | 0/192 | 0/192 | 16/192 | 18/192 | 8/192 |
| line at most 2 words longer than the phrase, distance 1 | 0/192 | 0/192 | 0/192 | 0/192 | 0/192 | 0/192 |

The lines that fired without the gate were "I think we should mark that down as a win for the team", "Can you note that the meeting moved to Thursday", "Did you see the clip that he posted yesterday", "He said the market that day was crazy" (at distance 2), and "Can you clip the video to the start of the song" (at distance 2).
The wake-word phrases never fired in these sentences even without the gate, because none of them said "hey space" or "hey slim" next to the command.
The gate costs recall only in babble, where the phrase sits inside a longer line (see the first table, column "babble").

## Matcher rules

These are the rules the numbers above came from, and what to build.

1. Take the listener's `text` for one segment and lower-case it.
2. Replace every character that is not a letter or an apostrophe with a space, and split on spaces.
   That removes the commas and full stops whisper adds and the dashes it sometimes inserts.
3. Map the aliases `he`, `hay` and `hi` to `hey`, and `slims` and `slimp` to `slim` if the product name is ever the wake word.
4. Gate on length: ignore the segment if it has more than the phrase's word count plus two words.
   For "hey space, mark that" that is 6 words.
   This allows a leading "okay" or "um" and nothing that reads as a sentence.
5. Slide a window over the segment of the phrase's word count, one fewer and one more.
   Join each window with no spaces, so "book mark" and "bookmark" compare equal, and compare it with the phrase joined the same way.
6. Fire when the Levenshtein distance is at most 1.
   Distance 2 added 1 of 36 for "hey slim" and 4 of 36 for "slim, mark that", but it also made "mark that" fire on "market that" and made "clip that" fire on "clip the", so it is not worth it for the recommended phrase.
7. For prefixed phrases, also accept the stem: the wake words within distance 1, then one word within distance 1 of "mark", ignoring whatever follows.
   This is what recovers "slim mark them" and "slim mark back".
   It matched 34 of 36 for "slim, mark that" and 35 of 36 for the "hey" phrases, with 0 of 192 false positives.
   It does not help "bookmark", which whisper writes as "bookmarked" or "book marked".
8. Do not match inside a segment that spans two speakers; segments are per speaker already, so this needs no code.

The one run that none of these recover is "base base, mark that" for "hey space".
Adding "base" as an alias for "space" would fix it, but "base" is a common word, so I would not.

## What this does not settle

- Two voices from one speech model are not a population.
  Accents, a headset that clips, and people who run the words together will do worse, and whisper's base model is the weakest of the usual sizes.
- Piper speaks in a neutral, evenly paced voice; people say "hey space" with a gap and a rising tone.
  A real test needs a handful of people saying each phrase on their own microphones.
- The babble condition shows the limit of the approach: when the person next to you is talking, a text matcher has nothing to work with.
- I did not test a phrase said mid-sentence ("yeah okay, hey space, mark that, anyway").
  The endpointer cuts after 600 ms of silence, so a pause before the phrase makes it its own line and the gate passes; without a pause it will usually fail the gate.
  This is an inference from the endpointer code, not a measurement.
- The prod listener settings were not checked; the defaults in `config.rs` were used as the brief said.
