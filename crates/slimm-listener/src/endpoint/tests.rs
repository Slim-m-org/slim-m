// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

/// A 440 Hz tone, or a deterministic hiss when `hz` is 0, of `amplitude` for `ms`.
fn signal(ms: usize, amplitude: f32, hz: f32) -> Vec<i16> {
    (0..ms * SAMPLE_RATE / 1000)
        .map(|n| {
            let wave = if hz == 0.0 {
                // A cheap deterministic noise.
                (((n as u32).wrapping_mul(2_654_435_761) >> 16) as f32 / 32_768.0) - 1.0
            } else {
                (n as f32 * hz * std::f32::consts::TAU / SAMPLE_RATE as f32).sin()
            };
            (wave * amplitude) as i16
        })
        .collect()
}

fn hiss(ms: usize, amplitude: f32) -> Vec<i16> {
    signal(ms, amplitude, 0.0)
}

fn speech(ms: usize) -> Vec<i16> {
    signal(ms, 8_000.0, 440.0)
}

fn run(origin: i64, parts: &[Vec<i16>]) -> Vec<Utterance> {
    let mut endpointer = Endpointer::new(origin);
    let mut out = Vec::new();
    for part in parts {
        out.extend(endpointer.push(part));
    }
    out.extend(endpointer.finish());
    out
}

#[test]
fn a_burst_between_silences_is_one_utterance() {
    let found = run(0, &[hiss(1_000, 60.0), speech(1_500), hiss(1_000, 60.0)]);
    assert_eq!(found.len(), 1);
    let u = &found[0];
    assert!(
        (880..=1_200).contains(&u.start_ms),
        "starts near 1 s, less the pre-roll: {}",
        u.start_ms
    );
    assert!(u.duration_ms() >= 1_500, "{}", u.duration_ms());
    assert_eq!(u.pcm.len() as i64, u.duration_ms() * 16);
}

#[test]
fn a_short_pause_does_not_split_an_utterance() {
    let found = run(
        0,
        &[
            hiss(500, 60.0),
            speech(800),
            hiss(300, 60.0),
            speech(800),
            hiss(900, 60.0),
        ],
    );
    assert_eq!(found.len(), 1);
}

#[test]
fn six_hundred_milliseconds_of_silence_ends_it() {
    let found = run(
        0,
        &[
            hiss(400, 60.0),
            speech(800),
            hiss(700, 60.0),
            speech(800),
            hiss(900, 60.0),
        ],
    );
    assert_eq!(found.len(), 2);
    assert!(found[1].start_ms > found[0].end_ms - 700);
}

#[test]
fn a_blip_under_four_hundred_milliseconds_is_dropped() {
    let found = run(0, &[hiss(500, 60.0), speech(200), hiss(1_000, 60.0)]);
    assert!(found.is_empty(), "{found:?}");
    let kept = run(0, &[hiss(500, 60.0), speech(500), hiss(1_000, 60.0)]);
    assert_eq!(kept.len(), 1);
}

#[test]
fn speech_past_fifteen_seconds_is_cut_and_continues() {
    let found = run(0, &[hiss(300, 60.0), speech(17_000), hiss(1_000, 60.0)]);
    assert!(found.len() >= 2, "{}", found.len());
    assert!(
        found
            .iter()
            .all(|u| u.duration_ms() <= MAX_UTTERANCE_MS + 20)
    );
    let total: i64 = found.iter().map(Utterance::duration_ms).sum();
    assert!(total >= 16_000, "little lost in the cut: {total}");
}

#[test]
fn a_room_that_gets_noisier_does_not_hide_the_speech_in_it() {
    // A step in the noise may be heard as an utterance for a while, which the transcriber then calls noise.
    let found = run(
        0,
        &[
            hiss(2_000, 60.0),
            hiss(1_000, 600.0),
            speech(1_000),
            hiss(2_000, 600.0),
        ],
    );
    let speech_at = 3_000;
    assert!(
        found
            .iter()
            .any(|u| u.start_ms <= speech_at + 200 && u.end_ms >= speech_at + 800),
        "the speech is inside an utterance: {found:?}"
    );
}

#[test]
fn quiet_hiss_alone_is_never_speech() {
    assert!(run(0, &[hiss(5_000, 100.0)]).is_empty());
}

#[test]
fn times_are_counted_from_the_origin() {
    let found = run(
        10_000,
        &[hiss(1_000, 60.0), speech(1_000), hiss(1_000, 60.0)],
    );
    assert!(found[0].start_ms >= 11_000 - 120, "{}", found[0].start_ms);
}

#[test]
fn samples_may_arrive_in_any_chunking() {
    let whole = [hiss(800, 60.0), speech(1_000), hiss(1_000, 60.0)].concat();
    let mut endpointer = Endpointer::new(0);
    let mut out = Vec::new();
    for chunk in whole.chunks(137) {
        out.extend(endpointer.push(chunk));
    }
    assert_eq!(out.len(), 1);
}

#[test]
fn finishing_ends_speech_in_progress() {
    let mut endpointer = Endpointer::new(0);
    assert!(endpointer.push(&hiss(500, 60.0)).is_empty());
    assert!(endpointer.push(&speech(900)).is_empty());
    assert!(endpointer.finish().is_some());
    assert!(endpointer.finish().is_none());
}
