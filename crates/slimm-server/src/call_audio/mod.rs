// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Call audio (decision 0105): a module hearing a voice call as text, only
//! while everyone in it agrees.
//!
//! [`CallAudio`] holds every session in memory and nothing else: no audio, no
//! text, no consent history, and a restart ends all of it. The rules live in
//! the pure [`session`] machine; this holds the map, the link to the listener,
//! the cooldowns and the checks on what the listener sends back. Carrying out
//! the effects of a transition (tokens, hub frames, module events) is
//! [`runtime`]'s job.

mod filter;
pub mod link;
pub mod protocol;
pub mod runtime;
pub mod session;
mod view;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::mpsc;
use uuid::Uuid;

use self::filter::SegmentRate;
use self::link::{Link, LinkEvent};
use self::protocol::ToListener;
use self::session::{Effect, EndReason, Refused, Session, Subject};
pub use self::view::CallAudioView;
use crate::config::ListenerSettings;
use crate::ids::{ChannelId, UserId};

/// How long after a decline, lapse or stop a channel waits before it may be asked again.
pub const COOLDOWN_MS: i64 = 60_000;

/// Why a request was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RequestError {
    Unavailable,
    /// The listener is at its `max_sessions`.
    Busy,
    AlreadyOn,
    /// Milliseconds left of the wait after a decline.
    Cooldown(i64),
    TooManyPeople,
}

/// What a transition left behind, copied out so effects run without the lock.
#[derive(Debug, Clone)]
pub struct Outcome {
    pub session_id: Uuid,
    pub channel: ChannelId,
    pub module_id: String,
    pub effects: Vec<Effect>,
    pub view: CallAudioView,
    pub include: Vec<UserId>,
    pub started_at_ms: Option<i64>,
    pub ids: EventIds,
}

/// Mints `call-audio:<session>:<n>` ids, once each.
#[derive(Debug, Clone)]
pub struct EventIds {
    session: Uuid,
    counter: Arc<AtomicU64>,
    sent: Arc<AtomicU64>,
}

impl PartialEq for EventIds {
    fn eq(&self, other: &Self) -> bool {
        self.session == other.session
    }
}

impl Eq for EventIds {}

impl EventIds {
    pub fn mint(&self) -> String {
        let n = self.counter.fetch_add(1, Ordering::Relaxed) + 1;
        format!("call-audio:{}:{n}", self.session)
    }

    /// Segments handed to the module so far.
    pub fn segments_sent(&self) -> u64 {
        self.sent.load(Ordering::Relaxed)
    }
}

/// A segment that passed every check, ready for the module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcceptedSegment {
    pub channel: ChannelId,
    pub module_id: String,
    pub session_id: Uuid,
    pub user_id: UserId,
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
    pub language: Option<String>,
    pub segment_id: String,
    pub ids: EventIds,
}

struct Live {
    session: Session,
    ids: EventIds,
    /// The include set last sent to the listener; a segment from anyone else is dropped.
    sent: HashSet<String>,
    rate: SegmentRate,
}

#[derive(Default)]
struct State {
    live: HashMap<ChannelId, Live>,
    cooldowns: HashMap<ChannelId, i64>,
    /// The listener's `max_sessions` once it said `ready`; `None` while it is away.
    ready: Option<u32>,
}

struct Inner {
    settings: ListenerSettings,
    link: Link,
    events: Mutex<Option<mpsc::UnboundedReceiver<LinkEvent>>>,
    state: Mutex<State>,
}

/// The call-audio service; cheap to clone.
#[derive(Clone, Default)]
pub struct CallAudio {
    inner: Option<Arc<Inner>>,
}

impl CallAudio {
    /// A deployment without a listener: no module can hear a call.
    pub fn disabled() -> Self {
        Self::default()
    }

    /// Dials the listener when one is configured. Needs a running tokio runtime.
    pub fn new(settings: Option<ListenerSettings>) -> Self {
        let Some(settings) = settings else {
            return Self::disabled();
        };
        let (link, events) = link::spawn(&settings);
        tracing::info!(url = %settings.url, "call audio enabled");
        Self {
            inner: Some(Arc::new(Inner {
                settings,
                link,
                events: Mutex::new(Some(events)),
                state: Mutex::default(),
            })),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// Whether the listener is connected and said `ready`.
    pub fn is_ready(&self) -> bool {
        self.inner
            .as_ref()
            .is_some_and(|inner| lock(&inner.state).ready.is_some())
    }

    /// The LiveKit address the listener dials, when the operator set one.
    pub fn livekit_url(&self) -> Option<String> {
        self.inner.as_ref()?.settings.livekit_url.clone()
    }

    pub(crate) fn take_events(&self) -> Option<mpsc::UnboundedReceiver<LinkEvent>> {
        lock(&self.inner.as_ref()?.events).take()
    }

    pub fn view(&self, channel: ChannelId) -> Option<CallAudioView> {
        let state = lock(&self.inner.as_ref()?.state);
        Some(CallAudioView::of(&state.live.get(&channel)?.session))
    }

    /// Channels with a session, of one module or of all.
    pub fn channels(&self, module_id: Option<&str>) -> Vec<ChannelId> {
        let Some(inner) = &self.inner else {
            return Vec::new();
        };
        lock(&inner.state)
            .live
            .iter()
            .filter(|(_, live)| module_id.is_none_or(|m| live.session.subject.module_id == m))
            .map(|(channel, _)| *channel)
            .collect()
    }

    /// Opens a session for `requester`, who is among `present`.
    pub fn begin(
        &self,
        (channel, subject): (ChannelId, Subject),
        requester: UserId,
        present: &[UserId],
        now: i64,
    ) -> Result<Outcome, RequestError> {
        let inner = self.inner.as_ref().ok_or(RequestError::Unavailable)?;
        let mut state = lock(&inner.state);
        let Some(max_sessions) = state.ready else {
            return Err(RequestError::Unavailable);
        };
        if state.live.contains_key(&channel) {
            return Err(RequestError::AlreadyOn);
        }
        if state.live.len() >= max_sessions as usize {
            return Err(RequestError::Busy);
        }
        if let Some(until) = state.cooldowns.get(&channel).filter(|until| **until > now) {
            return Err(RequestError::Cooldown(*until - now));
        }
        let id = Uuid::now_v7();
        let (session, effects) = Session::request((id, channel, subject), requester, present, now)
            .ok_or(RequestError::TooManyPeople)?;
        let ids = EventIds {
            session: id,
            counter: Arc::default(),
            sent: Arc::default(),
        };
        let live = Live {
            session,
            ids,
            sent: HashSet::new(),
            rate: SegmentRate::default(),
        };
        let outcome = outcome_of(&live, effects);
        state.live.insert(channel, live);
        Ok(outcome)
    }

    /// Runs `change` on the channel's session. `None` when there is none.
    pub fn update<E>(
        &self,
        channel: ChannelId,
        now: i64,
        change: impl FnOnce(&mut Session, i64) -> Result<Vec<Effect>, E>,
    ) -> Option<Result<Outcome, E>> {
        let inner = self.inner.as_ref()?;
        let mut state = lock(&inner.state);
        let live = state.live.get_mut(&channel)?;
        let effects = match change(&mut live.session, now) {
            Ok(effects) => effects,
            Err(err) => return Some(Err(err)),
        };
        let outcome = outcome_of(live, effects);
        let ended = outcome.effects.iter().find_map(|e| match e {
            Effect::Ended { reason, .. } => Some(*reason),
            _ => None,
        });
        if let Some(reason) = ended {
            state.live.remove(&channel);
            if reason.is_refusal() {
                state.cooldowns.insert(channel, now + COOLDOWN_MS);
            }
        }
        Some(Ok(outcome))
    }

    /// A person answers.
    pub fn consent(
        &self,
        channel: ChannelId,
        user: UserId,
        allow: bool,
        now: i64,
    ) -> Option<Result<Outcome, Refused>> {
        self.update(channel, now, |s, now| s.consent(user, allow, now))
    }

    pub fn stop(
        &self,
        channel: ChannelId,
        user: UserId,
        now: i64,
    ) -> Option<Result<Outcome, Refused>> {
        self.update(channel, now, |s, _| s.stop(user))
    }

    pub fn joined(&self, channel: ChannelId, user: UserId, now: i64) -> Option<Outcome> {
        self.update(channel, now, |s, _| Ok::<_, Refused>(s.join(user)))?
            .ok()
    }

    pub fn left(&self, channel: ChannelId, user: UserId, now: i64) -> Option<Outcome> {
        self.update(channel, now, |s, now| Ok::<_, Refused>(s.leave(user, now)))?
            .ok()
    }

    /// Ends the channel's session for a reason from outside it.
    pub fn end(&self, channel: ChannelId, reason: EndReason, now: i64) -> Option<Outcome> {
        self.update(channel, now, |s, _| Ok::<_, Refused>(s.force_end(reason)))?
            .ok()
    }

    /// Ends the session with this listener id, if any.
    pub fn end_by_id(&self, session: &str, reason: EndReason, now: i64) -> Option<Outcome> {
        let channel = self.channel_of(session)?;
        self.end(channel, reason, now)
    }

    /// Time passing for every session; also forgets cooldowns that have run out.
    pub fn tick(&self, now: i64) -> Vec<Outcome> {
        if let Some(inner) = &self.inner {
            lock(&inner.state).cooldowns.retain(|_, until| *until > now);
        }
        self.channels(None)
            .into_iter()
            .filter_map(|channel| {
                self.update(channel, now, |s, now| Ok::<_, Refused>(s.tick(now)))?
                    .ok()
            })
            .filter(|outcome| !outcome.effects.is_empty())
            .collect()
    }

    /// The listener went away: no session survives it.
    pub fn listener_lost(&self, now: i64) -> Vec<Outcome> {
        if let Some(inner) = &self.inner {
            lock(&inner.state).ready = None;
        }
        self.channels(None)
            .into_iter()
            .filter_map(|channel| self.end(channel, EndReason::ListenerUnavailable, now))
            .collect()
    }

    pub fn listener_ready(&self, max_sessions: u32) {
        if let Some(inner) = &self.inner {
            lock(&inner.state).ready = Some(max_sessions);
        }
    }

    fn channel_of(&self, session: &str) -> Option<ChannelId> {
        let inner = self.inner.as_ref()?;
        let id: Uuid = session.parse().ok()?;
        lock(&inner.state)
            .live
            .iter()
            .find(|(_, live)| live.ids.session == id)
            .map(|(channel, _)| *channel)
    }

    /// Sends `start` for the session, recording the set it carries.
    pub fn send_start(&self, channel: ChannelId, token: String, livekit_url: String) {
        self.send_set(channel, |session, include| ToListener::Start {
            session,
            livekit_url,
            token,
            include,
            language: None,
        });
    }

    /// Sends the whole include set as it stands now.
    pub fn send_include(&self, channel: ChannelId) {
        self.send_set(channel, |session, include| ToListener::Include {
            session,
            include,
        });
    }

    pub fn send_stop(&self, session: Uuid) {
        if let Some(inner) = &self.inner {
            inner.link.send(&ToListener::Stop {
                session: session.to_string(),
            });
        }
    }

    fn send_set(&self, channel: ChannelId, build: impl FnOnce(String, Vec<String>) -> ToListener) {
        let Some(inner) = &self.inner else { return };
        let mut state = lock(&inner.state);
        let Some(live) = state.live.get_mut(&channel) else {
            return;
        };
        let include: Vec<String> = live
            .session
            .include()
            .iter()
            .map(ToString::to_string)
            .collect();
        live.sent = include.iter().cloned().collect();
        inner
            .link
            .send(&build(live.ids.session.to_string(), include));
    }

    /// Checks one segment from the listener against the set last sent.
    pub fn accept_segment(
        &self,
        frame: &protocol::FromListener,
        now: i64,
    ) -> Option<AcceptedSegment> {
        let protocol::FromListener::Segment {
            session,
            identity,
            start_ms,
            end_ms,
            text,
            language,
        } = frame
        else {
            return None;
        };
        let channel = self.channel_of(session)?;
        let inner = self.inner.as_ref()?;
        let mut state = lock(&inner.state);
        let live = state.live.get_mut(&channel)?;
        let started = live.session.started_at_ms?;
        if !live.sent.contains(identity) {
            live.rate.count_drop();
            tracing::warn!(session, "dropped a segment from outside the include set");
            return None;
        }
        let text = filter::cut_text(text)?;
        if !live.rate.admit(now) {
            return None;
        }
        let user_id = UserId(identity.parse().ok()?);
        live.ids.sent.fetch_add(1, Ordering::Relaxed);
        let segment_id = live.ids.mint();
        Some(AcceptedSegment {
            channel,
            module_id: live.session.subject.module_id.clone(),
            session_id: live.ids.session,
            user_id,
            start_ms: started + start_ms,
            end_ms: started + end_ms,
            text,
            language: language.clone(),
            segment_id,
            ids: live.ids.clone(),
        })
    }

    #[cfg(test)]
    fn cooldown_count(&self) -> usize {
        lock(&self.inner.as_ref().expect("enabled").state)
            .cooldowns
            .len()
    }

    #[cfg(test)]
    fn dropped(&self, channel: ChannelId) -> u64 {
        let inner = self.inner.as_ref().expect("enabled");
        lock(&inner.state).live[&channel].rate.dropped()
    }
}

fn outcome_of(live: &Live, effects: Vec<Effect>) -> Outcome {
    Outcome {
        session_id: live.ids.session,
        channel: live.session.channel,
        module_id: live.session.subject.module_id.clone(),
        effects,
        view: CallAudioView::of(&live.session),
        include: live.session.include(),
        started_at_ms: live.session.started_at_ms,
        ids: live.ids.clone(),
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[cfg(test)]
mod tests;
