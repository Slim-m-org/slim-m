// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Text to speech into a call (decision 0142): the `/tts` command, server side.
//!
//! The server holds no audio. A line is queued per call and handed to the
//! listener, which synthesises it with Piper and plays it into the room as a
//! participant named "<name> (TTS)". [`TtsService`] is that queue; the
//! [`Speaker`] behind it is the listener's `/v1/speak` route, or a fake in tests.

mod listener;
mod queue;

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub use self::listener::ListenerSpeaker;
use self::queue::{Queues, Taken};
use crate::call_audio::CallAudio;
use crate::ids::{ChannelId, UserId};
use crate::voice::{Listing, VoiceService};

/// The longest line, in characters; the listener refuses the same.
pub const MAX_TEXT_CHARS: usize = 300;
/// Lines waiting or being spoken in one call.
pub const QUEUE_PER_CALL: usize = 5;
/// Lines waiting or being spoken for one person.
pub const QUEUE_PER_USER: usize = 2;
/// How long an answer to "is speech set up" is trusted.
const AVAILABLE_FOR: Duration = Duration::from_secs(30);

pub type SpeakFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What the listener is asked to play.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dispatch {
    pub livekit_url: String,
    pub token: String,
    pub text: String,
}

/// Why a line was not spoken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpeakError {
    /// No voice is set up, or the listener could not be reached.
    Unavailable,
    /// The listener refused the line itself (too long once spoken, or empty).
    Rejected,
    Failed,
}

/// The thing that turns a [`Dispatch`] into sound in a room.
pub trait Speaker: Send + Sync + 'static {
    /// Whether a voice is set up right now.
    fn available(&self) -> SpeakFuture<'_, bool>;
    fn speak(&self, dispatch: Dispatch) -> SpeakFuture<'_, Result<(), SpeakError>>;
}

/// One person's line in one call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub channel_id: ChannelId,
    pub user_id: UserId,
    pub name: String,
    pub text: String,
}

/// Why a line was not queued.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// This deployment has no listener.
    Disabled,
    /// The listener is there but has no voice, or is away.
    Unavailable,
    /// The call's queue or the person's share of it is full.
    Full,
}

struct Inner {
    speaker: Arc<dyn Speaker>,
    voice: VoiceService,
    livekit_url: Option<String>,
    queues: Mutex<Queues>,
    checked: Mutex<Option<(Instant, bool)>>,
}

/// The `/tts` queue; cheap to clone.
#[derive(Clone, Default)]
pub struct TtsService {
    inner: Option<Arc<Inner>>,
}

impl TtsService {
    pub fn disabled() -> Self {
        Self::default()
    }

    /// Speech through the listener when one is configured.
    pub fn of(call_audio: &CallAudio, voice: VoiceService) -> Self {
        match ListenerSpeaker::of(call_audio) {
            Some(speaker) => Self::new(Arc::new(speaker), voice, call_audio.livekit_url()),
            None => Self::disabled(),
        }
    }

    pub fn new(
        speaker: Arc<dyn Speaker>,
        voice: VoiceService,
        livekit_url: Option<String>,
    ) -> Self {
        Self {
            inner: Some(Arc::new(Inner {
                speaker,
                voice,
                livekit_url,
                queues: Mutex::default(),
                checked: Mutex::default(),
            })),
        }
    }

    /// Queues `line`, returning how many lines are ahead of it.
    pub async fn enqueue(&self, line: Line) -> Result<usize, Refusal> {
        let inner = self.inner.as_ref().ok_or(Refusal::Disabled)?;
        if !inner.is_available().await {
            return Err(Refusal::Unavailable);
        }
        let channel = line.channel_id;
        let (ahead, start) = lock(&inner.queues)
            .push(line, QUEUE_PER_CALL, QUEUE_PER_USER)
            .ok_or(Refusal::Full)?;
        if start {
            tokio::spawn(Arc::clone(inner).drain(channel));
        }
        Ok(ahead)
    }
}

impl Inner {
    async fn is_available(&self) -> bool {
        if let Some((at, answer)) = *lock(&self.checked)
            && at.elapsed() < AVAILABLE_FOR
        {
            return answer;
        }
        let answer = self.speaker.available().await;
        *lock(&self.checked) = Some((Instant::now(), answer));
        answer
    }

    async fn drain(self: Arc<Self>, channel: ChannelId) {
        loop {
            let taken = lock(&self.queues).take(channel);
            let Taken::Line(line) = taken else { return };
            self.speak(&line).await;
            lock(&self.queues).finish(channel);
        }
    }

    /// Speaks one line unless its speaker has left the call by their turn.
    async fn speak(&self, line: &Line) {
        let present = self.voice.in_call(line.channel_id, Listing::Fresh).await;
        if !present.contains(&line.user_id) {
            return;
        }
        let token = match self.voice.mint_speaker(
            line.channel_id,
            line.user_id,
            &line.name,
            self.livekit_url.as_deref(),
        ) {
            Ok(token) => token,
            Err(err) => {
                tracing::warn!(?err, "could not mint a speech token");
                return;
            }
        };
        let dispatch = Dispatch {
            livekit_url: token.url,
            token: token.token,
            text: line.text.clone(),
        };
        match self.speaker.speak(dispatch).await {
            Ok(()) => {}
            Err(SpeakError::Unavailable) => *lock(&self.checked) = None,
            Err(err) => tracing::warn!(?err, channel = %line.channel_id, "a line was not spoken"),
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}
