// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wake-phrase measurement (docs/research/voice-command-phrase-2026-11-22.md):
//! each clip goes through the real endpointer and the base model, and the raw
//! text of every utterance is written out with how long the model took.
//!
//! Opt in with `LISTENER_TEST_MODEL` (the base model), `WAKE_CORPUS_DIR` (the
//! clips and their `manifest.json`) and `WAKE_OUT` (a JSON lines file to write).
#![cfg(feature = "whisper")]

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use slimm_listener::endpoint::{Endpointer, SAMPLE_RATE};
use slimm_listener::stt::{Transcriber, WhisperTranscriber};

/// Seconds of the clip's lead-in played first, so the endpointer's floor has settled.
const PRIME_SECONDS: usize = 120;

fn read_wav(path: &std::path::Path) -> Vec<i16> {
    let bytes = std::fs::read(path).unwrap();
    bytes[44..]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect()
}

#[test]
fn transcribe_the_wake_phrase_corpus() {
    let (Ok(model), Ok(dir), Ok(out)) = (
        std::env::var("LISTENER_TEST_MODEL"),
        std::env::var("WAKE_CORPUS_DIR"),
        std::env::var("WAKE_OUT"),
    ) else {
        eprintln!("skipped: LISTENER_TEST_MODEL, WAKE_CORPUS_DIR and WAKE_OUT are not all set");
        return;
    };
    let dir = PathBuf::from(dir);
    let manifest: Vec<serde_json::Value> =
        serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    let transcriber: Arc<dyn Transcriber> =
        Arc::new(WhisperTranscriber::load(&PathBuf::from(model)).unwrap());
    let mut out = std::fs::File::create(out).unwrap();
    for clip in manifest {
        let file = clip["file"].as_str().unwrap();
        let pcm = read_wav(&dir.join(file));
        let mut endpoint = Endpointer::new(0);
        // A call's noise floor is learnt long before anyone speaks; the clip's own lead-in stands in for it.
        let lead_in = &pcm[..SAMPLE_RATE / 2];
        for _ in 0..PRIME_SECONDS * 2 {
            for chunk in lead_in.chunks(SAMPLE_RATE / 50) {
                endpoint.push(chunk);
            }
        }
        let mut utterances = Vec::new();
        for chunk in pcm.chunks(SAMPLE_RATE / 50) {
            utterances.extend(endpoint.push(chunk));
        }
        utterances.extend(endpoint.finish());
        let mut heard = Vec::new();
        for utterance in utterances {
            let started = Instant::now();
            let text = transcriber.transcribe(&utterance.pcm, None).unwrap().text;
            heard.push(serde_json::json!({
                "text": text,
                "model_ms": started.elapsed().as_millis() as u64,
                "start_ms": utterance.start_ms,
                "voiced_end_ms": utterance.voiced_end_ms,
            }));
        }
        let row = serde_json::json!({ "file": file, "heard": heard });
        writeln!(out, "{row}").unwrap();
    }
}
