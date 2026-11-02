// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Speech to text on this machine's CPU. The engine is behind [`Transcriber`]
//! so tests need no model; [`WhisperTranscriber`] is whisper.cpp. A fixed pool
//! of worker threads runs one utterance at a time each, so a busy call queues
//! (see `backlog`) rather than spreading over every core of a home server.

use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc::UnboundedSender;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transcript {
    pub text: String,
    pub language: Option<String>,
}

pub trait Transcriber: Send + Sync + 'static {
    /// The text of 16 kHz mono `pcm`, detecting the language unless one is given.
    fn transcribe(&self, pcm: &[i16], language: Option<&str>) -> anyhow::Result<Transcript>;

    /// The model's file name, for `ready`.
    fn model(&self) -> String;
}

/// Who an utterance belongs to, carried through the pool untouched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Meta {
    pub session: String,
    pub identity: String,
    pub start_ms: i64,
    pub end_ms: i64,
}

pub struct Work {
    pub meta: Meta,
    pub pcm: Vec<i16>,
    pub language: Option<String>,
    pub reply: UnboundedSender<Done>,
}

pub struct Done {
    pub meta: Meta,
    pub result: anyhow::Result<Transcript>,
}

/// A fixed set of worker threads sharing one queue.
pub struct Pool {
    work: Sender<Work>,
    size: usize,
    model: String,
}

impl Pool {
    pub fn new(transcriber: Arc<dyn Transcriber>, threads: usize) -> Self {
        let (work, queue) = channel::<Work>();
        let queue: Arc<Mutex<Receiver<Work>>> = Arc::new(Mutex::new(queue));
        let size = threads.max(1);
        for n in 0..size {
            let (queue, transcriber) = (Arc::clone(&queue), Arc::clone(&transcriber));
            std::thread::Builder::new()
                .name(format!("stt-{n}"))
                .spawn(move || worker(&queue, transcriber.as_ref()))
                .expect("spawning a transcription worker");
        }
        Self {
            work,
            size,
            model: transcriber.model(),
        }
    }

    pub fn submit(&self, work: Work) {
        let _ = self.work.send(work);
    }

    /// How many utterances can be in flight at once.
    pub fn size(&self) -> usize {
        self.size
    }

    pub fn model(&self) -> &str {
        &self.model
    }
}

fn worker(queue: &Mutex<Receiver<Work>>, transcriber: &dyn Transcriber) {
    loop {
        let next = queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .recv();
        let Ok(work) = next else { return };
        let result = transcriber.transcribe(&work.pcm, work.language.as_deref());
        let _ = work.reply.send(Done {
            meta: work.meta,
            result,
        });
    }
}

/// Text whisper emits for silence or noise, which is not something anyone said.
pub fn is_noise_marker(text: &str) -> bool {
    let text = text.trim();
    text.is_empty()
        || (text.starts_with('[') && text.ends_with(']'))
        || (text.starts_with('(') && text.ends_with(')'))
}

#[cfg(feature = "whisper")]
pub use whisper::WhisperTranscriber;

#[cfg(feature = "whisper")]
mod whisper {
    use std::path::Path;

    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    use super::{Transcriber, Transcript};

    pub struct WhisperTranscriber {
        context: WhisperContext,
        model: String,
    }

    impl WhisperTranscriber {
        pub fn load(path: &Path) -> anyhow::Result<Self> {
            let name = path
                .file_name()
                .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
            let context =
                WhisperContext::new_with_params(path, WhisperContextParameters::default())
                    .map_err(|e| anyhow::anyhow!("loading the model {}: {e}", path.display()))?;
            Ok(Self {
                context,
                model: name,
            })
        }
    }

    impl Transcriber for WhisperTranscriber {
        fn transcribe(&self, pcm: &[i16], language: Option<&str>) -> anyhow::Result<Transcript> {
            let mut audio = vec![0.0_f32; pcm.len()];
            whisper_rs::convert_integer_to_float_audio(pcm, &mut audio)
                .map_err(|e| anyhow::anyhow!("converting audio: {e}"))?;
            let mut state = self.context.create_state()?;
            let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
            params.set_n_threads(1);
            params.set_language(Some(language.unwrap_or("auto")));
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            params.set_no_context(true);
            state.full(params, &audio)?;
            let mut text = String::new();
            for segment in state.as_iter() {
                text.push_str(&segment.to_str_lossy()?);
            }
            let detected =
                whisper_rs::get_lang_str(state.full_lang_id_from_state()).map(str::to_owned);
            Ok(Transcript {
                text: text.trim().to_owned(),
                language: language.map(str::to_owned).or(detected),
            })
        }

        fn model(&self) -> String {
            self.model.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    struct Echo;

    impl Transcriber for Echo {
        fn transcribe(&self, pcm: &[i16], language: Option<&str>) -> anyhow::Result<Transcript> {
            Ok(Transcript {
                text: format!("{} samples", pcm.len()),
                language: language.map(str::to_owned),
            })
        }

        fn model(&self) -> String {
            "echo".into()
        }
    }

    fn meta(identity: &str) -> Meta {
        Meta {
            session: "s".into(),
            identity: identity.into(),
            start_ms: 0,
            end_ms: 1,
        }
    }

    #[tokio::test]
    async fn the_pool_runs_work_and_replies_with_the_meta_it_was_given() {
        let pool = Pool::new(Arc::new(Echo), 2);
        let (reply, mut done) = tokio::sync::mpsc::unbounded_channel();
        for who in ["a", "b", "c"] {
            pool.submit(Work {
                meta: meta(who),
                pcm: vec![0; 160],
                language: Some("en".into()),
                reply: reply.clone(),
            });
        }
        let mut seen = Vec::new();
        for _ in 0..3 {
            let got = tokio::time::timeout(Duration::from_secs(5), done.recv())
                .await
                .unwrap()
                .unwrap();
            assert_eq!(got.result.unwrap().text, "160 samples");
            seen.push(got.meta.identity);
        }
        seen.sort();
        assert_eq!(seen, ["a", "b", "c"]);
        assert_eq!((pool.size(), pool.model()), (2, "echo"));
    }

    #[test]
    fn silence_markers_are_not_speech() {
        for marker in ["", "  ", "[BLANK_AUDIO]", "(music)", " [ Silence ] "] {
            assert!(is_noise_marker(marker), "{marker:?}");
        }
        assert!(!is_noise_marker("hello [there]"));
    }
}
