<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# How whisper hears "hey space" (2026-11-22)

Spoken marks ("hey space, mark that", "hey space, note ...") read the text the server transcript already keeps.
Before they shipped, this run measured how the base whisper model writes the phrase, and what the parser in `crates/slimm-server/src/call_audio/commands.rs` makes of it.

## Result in short

1. 250 of 264 spoken commands were acted on (94.7%), across two voices, three speeds, and clean, room noise at 20 and 10 dB SNR, and music at 10 dB.
2. No false command in 62 minutes of negative speech that was chosen to trip it ("hey, space it out", "that clip was funny", "mark my words", "hey Stacey, mark that", "we should mark that down"), plus 5 minutes of noise, music and silence: 0 false accepts per hour.
3. The model took 3.9 s per utterance at p50 and 4.8 s at p95 on one thread each, on a machine also running a large test suite; the earlier unloaded figure was 2.3 s from the end of speech (call-audio-real-speech-2026-11-02.md). A spoken mark lands when its line does.
4. The parser gained one alias from the run: "hey" may be written "pay" or "hay". Nothing else was added, and no initial prompt is used.
5. This is synthetic speech. Real microphones, accents and people talking over each other will do worse, so voice commands stay off by default and are a Space's choice.

## What was run

- Speech from piper 1.8 with the `en_US-lessac-medium` and `en_US-ryan-medium` voices at length scales 0.85, 1.0 and 1.2, resampled to 16 kHz.
- Each clip had half a second of lead-in and a second after the speech. Room noise (filtered random noise) and music (decaying chords) were mixed in at the stated SNR against the speech's own level.
- `crates/slimm-listener/tests/wake_phrase.rs` played each clip through the real endpointer and the base model (`ggml-base.bin`, language detected, as a call does).
  The endpointer was first fed two minutes of the clip's own lead-in, because in a call its noise floor is learnt long before anyone speaks; without that, a noisy clip never ended an utterance.
- `score.py` applied the parser's rules to the raw text; `fixture.py` wrote the distinct transcriptions to `voice-command-phrase-2026-11-22-fixture.json`, which the server's parser test reads.
  The scripts are in `voice-command-phrase/`, and the run took 1347 clips, 1.33 hours of audio.

Positive set (each in all 24 voice, speed and noise combinations): "mark that", "mark this", "bookmark that", "clip that" alone; two notes; a mark at the start and at the end of a sentence; "okay so hey space, please mark that"; a note at the end of a sentence; and "hey space" and "mark that" as two utterances 1.2 s apart.

## Misses

| Heard as | Clips | Why the parser passes |
| --- | --- | --- |
| "A space. Clip that." | 4 | "hey" lost entirely; "a" is too common a word to alias. |
| "That was a good point, hey space, no to ask Ada..." | 4 | "note" heard as "no"; acting on "no" would turn "hey space, no, I meant..." into a note. |
| "Hey Space, both mark that." | 2 | "bookmark" split; "both" is not a verb. |
| "Hey Space, flip that." / "Glipp that." | 2 | "clip" misheard. |
| "Hey Space, no call the plumber..." | 1 | As above. |
| "Mark that." alone | 1 | The "hey space" half was below the endpointer's threshold at 10 dB SNR, so it never became a line. |

The 2 "pay space" lines are now accepted through the alias.
No negative ever produced the phrase followed by a verb; "Hey, space it out a bit more" was transcribed with the phrase 24 times and correctly ignored.
On noise alone whisper wrote "[BLANK_AUDIO]" and "(upbeat music)", and once a Japanese closing phrase before a real command; none of these can act.

## What it decided

- Ship spoken marks behind the per-Space switch, off by default, with the default phrase "hey space".
- Keep the verbs to mark, bookmark, clip (a mark only) and note, each matched exactly.
- Keep the 10 s wake window: the split clips were caught that way in 23 of 24 runs.
