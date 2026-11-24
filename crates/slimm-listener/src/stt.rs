// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Speech to text on this machine's CPU. The engine is behind [`Transcriber`]
//! so tests need no model; [`WhisperTranscriber`] is whisper.cpp. A fixed pool
//! of worker threads runs one utterance at a time each, so a busy call queues
//! (see `backlog`) rather than spreading over every core of a home server.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, Ordering};
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

    /// Like [`Self::transcribe`], giving up early once `cancel` is set. An engine that cannot stop mid-run keeps the default.
    fn transcribe_until(
        &self,
        pcm: &[i16],
        language: Option<&str>,
        _cancel: &AtomicBool,
    ) -> anyhow::Result<Transcript> {
        self.transcribe(pcm, language)
    }

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
    /// The speaker's consent generation when this was dispatched; a result from an older one is stale.
    pub generation: u64,
}

pub struct Work {
    pub meta: Meta,
    pub pcm: Vec<i16>,
    pub language: Option<String>,
    pub reply: UnboundedSender<Done>,
    /// Set by whoever no longer wants the result, so the job is skipped or stops early.
    pub cancel: Option<Arc<AtomicBool>>,
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
        let result = run_job(transcriber, &work);
        let _ = work.reply.send(Done {
            meta: work.meta,
            result,
        });
    }
}

/// Runs one job, turning a panic in the engine into an error so the worker and its slot survive.
fn run_job(transcriber: &dyn Transcriber, work: &Work) -> anyhow::Result<Transcript> {
    let never = AtomicBool::new(false);
    let cancel = work.cancel.as_deref().unwrap_or(&never);
    if cancel.load(Ordering::Acquire) {
        anyhow::bail!("cancelled before it started");
    }
    catch_unwind(AssertUnwindSafe(|| {
        transcriber.transcribe_until(&work.pcm, work.language.as_deref(), cancel)
    }))
    .unwrap_or_else(|_| Err(anyhow::anyhow!("the transcription engine panicked")))
}

/// Text whisper emits for silence or noise, which is not something anyone said: nothing but
/// `[...]` and `(...)` markers.
pub fn is_noise_marker(text: &str) -> bool {
    let mut rest = text.trim();
    while let Some(first) = rest.chars().next() {
        let close = match first {
            '[' => ']',
            '(' => ')',
            _ => return false,
        };
        let Some(end) = rest.find(close) else {
            return false;
        };
        rest = rest[end + 1..].trim_start();
    }
    true
}

#[cfg(feature = "whisper")]
pub use whisper::WhisperTranscriber;

#[cfg(feature = "whisper")]
mod whisper {
    use std::collections::HashMap;
    use std::ffi::c_void;
    use std::path::Path;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, Ordering};

    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    use super::{Transcriber, Transcript};

    /// Decoder settings per language, built once: whisper-rs never frees the language string it is handed.
    #[derive(Default)]
    struct ParamsCache(Mutex<HashMap<Option<String>, FullParams<'static, 'static>>>);

    impl ParamsCache {
        /// A fresh copy of the settings for `language`; `None` and "auto" detect it.
        fn get(&self, language: Option<&str>) -> anyhow::Result<FullParams<'static, 'static>> {
            let language = language.filter(|l| !l.is_empty() && *l != "auto");
            if let Some(code) = language
                && (code.contains('\0') || whisper_rs::get_lang_id(code).is_none())
            {
                anyhow::bail!("unknown language {code:?}");
            }
            let mut built = self
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let key = language.map(str::to_owned);
            if let Some(found) = built.get(&key) {
                return Ok(found.clone());
            }
            let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
            params.set_n_threads(1);
            if let Some(code) = &key {
                params.set_language(Some(Box::leak(code.clone().into_boxed_str())));
            } else {
                params.set_language(None);
            }
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            params.set_no_context(true);
            built.insert(key, params.clone());
            Ok(params)
        }

        #[cfg(test)]
        fn len(&self) -> usize {
            self.0.lock().unwrap().len()
        }
    }

    unsafe extern "C" fn cancelled(flag: *mut c_void) -> bool {
        // SAFETY: `flag` is the `AtomicBool` that `transcribe_until` keeps alive for the whole `full` call.
        unsafe { &*flag.cast::<AtomicBool>() }.load(Ordering::Acquire)
    }

    pub struct WhisperTranscriber {
        context: WhisperContext,
        model: String,
        params: ParamsCache,
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
                params: ParamsCache::default(),
            })
        }
    }

    impl Transcriber for WhisperTranscriber {
        fn transcribe(&self, pcm: &[i16], language: Option<&str>) -> anyhow::Result<Transcript> {
            self.transcribe_until(pcm, language, &AtomicBool::new(false))
        }

        fn transcribe_until(
            &self,
            pcm: &[i16],
            language: Option<&str>,
            cancel: &AtomicBool,
        ) -> anyhow::Result<Transcript> {
            let mut params = self.params.get(language)?;
            let mut audio = vec![0.0_f32; pcm.len()];
            whisper_rs::convert_integer_to_float_audio(pcm, &mut audio)
                .map_err(|e| anyhow::anyhow!("converting audio: {e}"))?;
            let mut state = self.context.create_state()?;
            // SAFETY: `cancel` outlives `state.full`, the only place whisper calls back.
            unsafe {
                params.set_abort_callback(Some(cancelled));
                params.set_abort_callback_user_data(std::ptr::from_ref(cancel).cast_mut().cast());
            }
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

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn a_language_is_built_once_however_often_it_is_asked_for() {
            let cache = ParamsCache::default();
            for _ in 0..5 {
                cache.get(Some("en")).unwrap();
            }
            assert_eq!(cache.len(), 1);
        }

        #[test]
        fn auto_and_no_language_share_one_entry_that_allocates_nothing_per_call() {
            let cache = ParamsCache::default();
            for language in [None, Some("auto"), Some("")] {
                cache.get(language).unwrap();
            }
            assert_eq!(cache.len(), 1);
        }

        #[test]
        fn an_unknown_language_is_refused_and_never_cached() {
            let cache = ParamsCache::default();
            for code in ["xx-nope", "e\0n"] {
                assert!(cache.get(Some(code)).is_err(), "{code:?}");
            }
            assert_eq!(cache.len(), 0);
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
            generation: 0,
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
                cancel: None,
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

    /// Panics on the first utterance, then behaves.
    struct Flaky(AtomicBool);

    impl Transcriber for Flaky {
        fn transcribe(&self, pcm: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
            assert!(self.0.swap(true, Ordering::SeqCst), "the engine blew up");
            Ok(Transcript {
                text: format!("{} samples", pcm.len()),
                language: None,
            })
        }

        fn model(&self) -> String {
            "flaky".into()
        }
    }

    fn job(
        who: &str,
        cancel: Option<Arc<AtomicBool>>,
    ) -> (Work, tokio::sync::mpsc::UnboundedReceiver<Done>) {
        let (reply, done) = tokio::sync::mpsc::unbounded_channel();
        let work = Work {
            meta: meta(who),
            pcm: vec![0; 160],
            language: None,
            reply,
            cancel,
        };
        (work, done)
    }

    #[tokio::test]
    async fn a_panicking_engine_answers_with_an_error_and_keeps_its_worker() {
        let pool = Pool::new(Arc::new(Flaky(AtomicBool::new(false))), 1);
        for (who, ok) in [("first", false), ("second", true)] {
            let (work, mut done) = job(who, None);
            pool.submit(work);
            let got = tokio::time::timeout(Duration::from_secs(5), done.recv())
                .await
                .expect("the worker answered")
                .unwrap();
            assert_eq!(got.result.is_ok(), ok, "{who}");
        }
    }

    /// Runs until its cancel flag is set, then says so.
    struct UntilCancelled(Arc<AtomicBool>);

    impl Transcriber for UntilCancelled {
        fn transcribe(&self, _: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
            self.0.store(true, Ordering::SeqCst);
            anyhow::bail!("ran to the end")
        }

        fn transcribe_until(
            &self,
            _: &[i16],
            _: Option<&str>,
            cancel: &AtomicBool,
        ) -> anyhow::Result<Transcript> {
            while !cancel.load(Ordering::Acquire) {
                std::thread::sleep(Duration::from_millis(5));
            }
            anyhow::bail!("stopped early")
        }

        fn model(&self) -> String {
            "until".into()
        }
    }

    #[tokio::test]
    async fn a_cancelled_job_is_not_started_and_a_running_one_is_told_to_stop() {
        let ran = Arc::new(AtomicBool::new(false));
        let pool = Pool::new(Arc::new(UntilCancelled(Arc::clone(&ran))), 1);
        let cancelled = Arc::new(AtomicBool::new(true));
        let (work, mut done) = job("before", Some(cancelled));
        pool.submit(work);
        let got = done.recv().await.unwrap();
        assert!(got.result.unwrap_err().to_string().contains("cancelled"));
        assert!(!ran.load(Ordering::SeqCst), "the engine never started it");

        let flag = Arc::new(AtomicBool::new(false));
        let (work, mut done) = job("during", Some(Arc::clone(&flag)));
        pool.submit(work);
        tokio::time::sleep(Duration::from_millis(50)).await;
        flag.store(true, Ordering::Release);
        let got = tokio::time::timeout(Duration::from_secs(5), done.recv())
            .await
            .expect("the running job stopped")
            .unwrap();
        assert!(
            got.result
                .unwrap_err()
                .to_string()
                .contains("stopped early")
        );
    }

    #[test]
    fn silence_markers_are_not_speech() {
        for marker in [
            "",
            "  ",
            "[BLANK_AUDIO]",
            "(music)",
            " [ Silence ] ",
            "[Music] (applause)",
        ] {
            assert!(is_noise_marker(marker), "{marker:?}");
        }
        for speech in [
            "hello [there]",
            "[BLANK_AUDIO] hello [BLANK_AUDIO]",
            "[unclosed",
        ] {
            assert!(!is_noise_marker(speech), "{speech:?}");
        }
    }
}
