// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One call being listened to. The include set is the only authority on whose
//! audio is heard: tracks are subscribed for it and nothing else, speech is cut
//! only for it, and a result for someone who has since left it is thrown away.
//! The set the server last sent is whole, never a delta.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::time::Instant;

use crate::backlog::{Backlog, Queued, TIME_LIMIT_MS};
use crate::endpoint::{Endpointer, SAMPLE_RATE};
use crate::protocol::Report;
use crate::room::{RoomEvent, RoomSource, TrackRef};
use crate::stt::{Done, Meta, Pool, Work, is_noise_marker};

/// What the control connection can tell a running session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionCommand {
    /// The whole include set, replacing the last.
    Include(HashSet<String>),
    Stop,
}

/// Why a session ended, when it did not end by being told to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ending {
    Stopped,
    Overload,
    TimeLimit,
    RoomError,
}

impl Ending {
    pub fn wire(self) -> &'static str {
        match self {
            Self::Stopped => "stopped",
            Self::Overload => "overload",
            Self::TimeLimit => "time_limit",
            Self::RoomError => "room_error",
        }
    }
}

pub struct Params {
    pub id: String,
    pub include: HashSet<String>,
    pub language: Option<String>,
}

/// How often limits are checked.
const TICK: Duration = Duration::from_secs(1);

/// How long a session that was told to stop keeps transcribing what it already heard.
pub const DRAIN: Duration = Duration::from_secs(30);

/// Samples of one speaker between two "heard" log lines: ten seconds.
const HEARD_LOG_SAMPLES: u64 = 10 * SAMPLE_RATE as u64;

struct Session<R> {
    id: String,
    include: HashSet<String>,
    language: Option<String>,
    room: R,
    pool: Arc<Pool>,
    reports: UnboundedSender<Report>,
    started: Instant,
    tracks: HashMap<TrackRef, Track>,
    endpoints: HashMap<String, Endpointer>,
    backlog: Backlog,
    in_flight: usize,
    results: UnboundedSender<Done>,
    heard: HashMap<String, Heard>,
}

/// What one speaker's audio looked like, so a silent transcript can be told apart from a quiet one.
#[derive(Default)]
struct Heard {
    samples: u64,
    since_log: u64,
    peak: u16,
    utterances: u32,
}

struct Track {
    microphone: bool,
    subscribed: bool,
}

/// Runs the session until it ends, then leaves the room. Reports `ended` itself
/// unless it was told to stop.
pub async fn run<R: RoomSource>(
    params: Params,
    room: R,
    mut commands: UnboundedReceiver<SessionCommand>,
    pool: Arc<Pool>,
    reports: UnboundedSender<Report>,
) -> Ending {
    let (results, mut done) = unbounded_channel();
    let mut session = Session {
        id: params.id,
        include: params.include,
        language: params.language,
        room,
        pool,
        reports,
        started: Instant::now(),
        tracks: HashMap::new(),
        endpoints: HashMap::new(),
        backlog: Backlog::default(),
        in_flight: 0,
        results,
        heard: HashMap::new(),
    };
    tracing::info!(session = %session.id, included = session.include.len(), "listening to a call");
    let _ = session.reports.send(Report::Started {
        session: session.id.clone(),
    });
    let mut tick = tokio::time::interval(TICK);
    let ending = loop {
        tokio::select! {
            biased;
            command = commands.recv() => match command {
                Some(SessionCommand::Include(set)) => session.set_include(set),
                Some(SessionCommand::Stop) | None => break Ending::Stopped,
            },
            event = session.room.next_event() => match event {
                Some(RoomEvent::Closed) | None => break Ending::RoomError,
                Some(event) => session.on_event(event),
            },
            Some(finished) = done.recv() => session.on_done(finished),
            _ = tick.tick() => {
                if let Some(ending) = session.check_limits() {
                    break ending;
                }
            }
        }
    };
    session.room.leave().await;
    if ending != Ending::Overload {
        session.drain(&mut done).await;
    }
    session.log_heard();
    tracing::info!(session = %session.id, ending = ending.wire(), "stopped listening");
    if ending != Ending::Stopped {
        let _ = session.reports.send(Report::Ended {
            session: session.id.clone(),
            reason: ending.wire().into(),
        });
    }
    ending
}

impl<R: RoomSource> Session<R> {
    fn now_ms(&self) -> i64 {
        i64::try_from(self.started.elapsed().as_millis()).unwrap_or(i64::MAX)
    }

    fn check_limits(&self) -> Option<Ending> {
        let now = self.now_ms();
        if now >= TIME_LIMIT_MS {
            return Some(Ending::TimeLimit);
        }
        self.backlog.overloaded(now).then_some(Ending::Overload)
    }

    fn should_hear(&self, track: &TrackRef, info: &Track) -> bool {
        info.microphone && self.include.contains(&track.identity)
    }

    /// Subscribes to exactly the microphones of the include set, and to nothing else.
    fn reconcile(&mut self) {
        let wanted: Vec<(TrackRef, bool)> = self
            .tracks
            .iter()
            .map(|(track, info)| (track.clone(), self.should_hear(track, info)))
            .collect();
        for (track, on) in wanted {
            let Some(info) = self.tracks.get_mut(&track) else {
                continue;
            };
            if info.subscribed != on {
                info.subscribed = on;
                tracing::info!(session = %self.id, identity = %track.identity, on, "microphone subscription");
                self.room.subscribe(&track, on);
            }
        }
    }

    fn set_include(&mut self, set: HashSet<String>) {
        let now = self.now_ms();
        for gone in self.include.difference(&set).cloned().collect::<Vec<_>>() {
            self.endpoints.remove(&gone);
            self.backlog.forget(&gone, now);
        }
        self.include = set;
        self.reconcile();
    }

    fn on_event(&mut self, event: RoomEvent) {
        match event {
            RoomEvent::Published { track, microphone } => {
                self.tracks.insert(
                    track,
                    Track {
                        microphone,
                        subscribed: false,
                    },
                );
                self.reconcile();
            }
            RoomEvent::Unpublished { track } => {
                self.tracks.remove(&track);
            }
            RoomEvent::Audio { identity, samples } => self.on_audio(&identity, &samples),
            RoomEvent::Left { identity } => {
                self.tracks.retain(|track, _| track.identity != identity);
                if let Some(mut endpoint) = self.endpoints.remove(&identity)
                    && self.include.contains(&identity)
                {
                    self.queue_all(&identity, endpoint.finish().into_iter().collect());
                }
            }
            RoomEvent::Closed => {}
        }
    }

    fn on_audio(&mut self, identity: &str, samples: &[i16]) {
        if !self.include.contains(identity) {
            return;
        }
        let origin = self.now_ms();
        let endpoint = self
            .endpoints
            .entry(identity.to_owned())
            .or_insert_with(|| Endpointer::new(origin));
        let utterances = endpoint.push(samples);
        self.note_heard(identity, samples, utterances.len());
        self.queue_all(identity, utterances);
    }

    fn queue_all(&mut self, identity: &str, utterances: Vec<crate::endpoint::Utterance>) {
        let now = self.now_ms();
        for utterance in utterances {
            self.backlog.push(
                Queued {
                    identity: identity.to_owned(),
                    utterance,
                },
                now,
            );
        }
        self.dispatch();
    }

    fn dispatch(&mut self) {
        while self.in_flight < self.pool.size() {
            let now = self.now_ms();
            let Some(next) = self.backlog.pop(now) else {
                return;
            };
            self.in_flight += 1;
            self.pool.submit(Work {
                meta: Meta {
                    session: self.id.clone(),
                    identity: next.identity,
                    start_ms: next.utterance.start_ms,
                    end_ms: next.utterance.end_ms,
                },
                pcm: next.utterance.pcm,
                language: self.language.clone(),
                reply: self.results.clone(),
            });
        }
    }

    fn on_done(&mut self, finished: Done) {
        self.in_flight = self.in_flight.saturating_sub(1);
        self.dispatch();
        let Done { meta, result } = finished;
        let transcript = match result {
            Ok(transcript) => transcript,
            Err(err) => {
                tracing::warn!(%err, "an utterance could not be transcribed");
                return;
            }
        };
        // Consent can be withdrawn while an utterance is being transcribed.
        if !self.include.contains(&meta.identity) {
            return;
        }
        if is_noise_marker(&transcript.text) {
            tracing::info!(session = %self.id, identity = %meta.identity, "an utterance came back as no words");
            return;
        }
        let _ = self.reports.send(Report::Segment {
            session: self.id.clone(),
            identity: meta.identity,
            start_ms: meta.start_ms,
            end_ms: meta.end_ms,
            text: transcript.text,
            language: transcript.language,
        });
    }
}

impl<R: RoomSource> Session<R> {
    /// Cuts whatever each speaker was in the middle of and waits, up to [`DRAIN`], for every transcription to come back.
    async fn drain(&mut self, done: &mut UnboundedReceiver<Done>) {
        let speakers: Vec<String> = self.endpoints.keys().cloned().collect();
        for identity in speakers {
            let last = self
                .endpoints
                .get_mut(&identity)
                .and_then(Endpointer::finish);
            if let Some(utterance) = last {
                self.note_heard(&identity, &[], 1);
                self.queue_all(&identity, vec![utterance]);
            }
        }
        let deadline = tokio::time::sleep(DRAIN);
        tokio::pin!(deadline);
        while self.in_flight > 0 || !self.backlog.is_empty() {
            tokio::select! {
                Some(finished) = done.recv() => self.on_done(finished),
                () = &mut deadline => {
                    tracing::warn!(session = %self.id, in_flight = self.in_flight, "stopped before every utterance was transcribed");
                    return;
                }
            }
        }
    }

    fn note_heard(&mut self, identity: &str, samples: &[i16], utterances: usize) {
        let heard = self.heard.entry(identity.to_owned()).or_default();
        heard.samples += samples.len() as u64;
        heard.since_log += samples.len() as u64;
        heard.peak = samples
            .iter()
            .map(|s| s.unsigned_abs())
            .fold(heard.peak, u16::max);
        heard.utterances += u32::try_from(utterances).unwrap_or(u32::MAX);
        if heard.since_log >= HEARD_LOG_SAMPLES {
            heard.since_log = 0;
            tracing::info!(
                session = %self.id,
                identity,
                seconds = heard.samples / SAMPLE_RATE as u64,
                peak = heard.peak,
                utterances = heard.utterances,
                "heard a speaker"
            );
        }
    }

    fn log_heard(&self) {
        for (identity, heard) in &self.heard {
            tracing::info!(
                session = %self.id,
                identity = %identity,
                seconds = heard.samples / SAMPLE_RATE as u64,
                peak = heard.peak,
                utterances = heard.utterances,
                "heard in total"
            );
        }
    }
}

#[cfg(test)]
mod tests;
