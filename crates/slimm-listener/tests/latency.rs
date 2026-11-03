// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The acceptance measurement of decision 0105: with four people talking in
//! turn on the base model, the text arrives under 5 s after the speaker stops
//! (95th percentile), and the process stays under 1 GB resident.
//!
//! Opt in with `LISTENER_TEST_MODEL` (the base model) and
//! `LISTENER_LATENCY_WAV_DIR` (a directory of `s0.wav`..`s3.wav`, mono 16-bit
//! speech at any rate). It prints what it measured.
#![cfg(feature = "whisper")]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use slimm_listener::endpoint::{Endpointer, SAMPLE_RATE};
use slimm_listener::stt::{Meta, Pool, WhisperTranscriber, Work};
use tokio::sync::mpsc::unbounded_channel;

/// The silence the endpointer waits for before it calls an utterance done.
const END_SILENCE: Duration = Duration::from_millis(600);

fn read_wav(path: &std::path::Path) -> Vec<i16> {
    let bytes = std::fs::read(path).unwrap();
    let rate = u32::from_le_bytes(bytes[24..28].try_into().unwrap()) as f64;
    let pcm: Vec<i16> = bytes[44..]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    let step = rate / SAMPLE_RATE as f64;
    (0..((pcm.len() as f64 / step) as usize))
        .map(|n| pcm[(n as f64 * step) as usize])
        .collect()
}

fn peak_rss_mb() -> f64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let line = status.lines().find(|l| l.starts_with("VmHWM:")).unwrap();
    line.split_whitespace()
        .nth(1)
        .unwrap()
        .parse::<f64>()
        .unwrap()
        / 1024.0
}

#[tokio::test(flavor = "multi_thread")]
async fn four_people_in_turn_get_text_inside_five_seconds() {
    let (Ok(model), Ok(dir)) = (
        std::env::var("LISTENER_TEST_MODEL"),
        std::env::var("LISTENER_LATENCY_WAV_DIR"),
    ) else {
        eprintln!("skipped: LISTENER_TEST_MODEL and LISTENER_LATENCY_WAV_DIR are not both set");
        return;
    };
    let speeches: Vec<Vec<i16>> = (0..4)
        .map(|n| read_wav(&PathBuf::from(&dir).join(format!("s{n}.wav"))))
        .collect();
    let transcriber = WhisperTranscriber::load(&PathBuf::from(model)).unwrap();
    let pool = Arc::new(Pool::new(Arc::new(transcriber), 4));
    let (reply, mut done) = unbounded_channel();

    let mut latencies = Vec::new();
    for round in 0..3 {
        for (who, speech) in speeches.iter().enumerate() {
            let mut endpoint = Endpointer::new(0);
            let mut samples = vec![0_i16; SAMPLE_RATE / 2];
            samples.extend(speech);
            samples.extend(vec![0_i16; SAMPLE_RATE]);
            let mut utterances = Vec::new();
            for chunk in samples.chunks(SAMPLE_RATE / 50) {
                utterances.extend(endpoint.push(chunk));
            }
            assert_eq!(utterances.len(), 1, "one utterance per speech");
            let sent = Instant::now();
            for utterance in utterances {
                pool.submit(Work {
                    meta: Meta {
                        session: "latency".into(),
                        identity: format!("speaker{who}"),
                        start_ms: utterance.start_ms,
                        end_ms: utterance.end_ms,
                    },
                    pcm: utterance.pcm,
                    language: Some("en".into()),
                    reply: reply.clone(),
                });
            }
            let finished = done.recv().await.unwrap();
            let text = finished.result.unwrap().text;
            let took = sent.elapsed() + END_SILENCE;
            eprintln!(
                "round {round} speaker {who}: {:.2}s  {}",
                took.as_secs_f64(),
                text
            );
            assert!(
                text.split_whitespace().count() > 5,
                "it heard something: {text:?}"
            );
            if round > 0 {
                latencies.push(took.as_secs_f64());
            }
        }
    }
    latencies.sort_by(f64::total_cmp);
    let p95 = latencies[((latencies.len() as f64) * 0.95).ceil() as usize - 1];
    let rss = peak_rss_mb();
    eprintln!(
        "p95 latency {p95:.2}s over {} utterances, peak RSS {rss:.0} MB",
        latencies.len()
    );
    assert!(p95 < 5.0, "p95 {p95}");
    assert!(rss < 1024.0, "rss {rss}");
}
